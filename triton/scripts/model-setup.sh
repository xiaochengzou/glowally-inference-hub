#!/bin/bash
set -e

echo "=== [1/5] Install dependencies ==="
pip install huggingface_hub transformers optimum[onnxruntime] onnxruntime-gpu --quiet

echo "=== [2/5] Download LoRA adapters ==="
python -c "
import os
from huggingface_hub import snapshot_download
token = os.environ.get('HF_TOKEN')
for repo_id, local_dir in [
    ('vindows/qwen2.5-7b-text-to-sql', '/data/sql-lora'),
    ('miarick/Qwen2.5-7B-Instruct-cyberpunk-literary-lora', '/data/creative-lora'),
]:
    print(f'Downloading {repo_id} ...')
    snapshot_download(repo_id=repo_id, local_dir=local_dir, token=token)
    print(f'Done: {local_dir}')
"

echo "=== [2b/5] Remove tokenizer files from LoRA adapter directories ==="
# vLLM calls AutoTokenizer.from_pretrained(lora_path) for every LoRA request.
# The Qwen2.5 tokenizer.json in these adapters triggers a Rust parse error that
# crashes the async engine loop. Removing these files causes vLLM to fall back
# to the base model tokenizer via the OSError path in get_lora_tokenizer().
for dir in /data/sql-lora /data/creative-lora; do
    rm -f "$dir/tokenizer.json" "$dir/tokenizer_config.json" \
          "$dir/vocab.json" "$dir/merges.txt" \
          "$dir/special_tokens_map.json" "$dir/added_tokens.json"
    echo "  Cleaned tokenizer files from $dir"
done

echo "=== [3/5] Export DistilBERT intent classifier to ONNX ==="
python -c "
import os
from optimum.exporters.onnx import main_export
model_id = os.environ.get('INTENT_CLASSIFIER_MODEL', 'distilbert/distilbert-base-uncased')
print(f'Exporting {model_id} to ONNX ...')
main_export(
    model_name_or_path=model_id,
    output='/data/models/intent_classifier/1',
    task='text-classification',
    opset=17,
    cache_dir='/data/hf-cache',
)
# Triton expects the file named model.onnx
import glob, shutil
exported = glob.glob('/data/models/intent_classifier/1/*.onnx')
if exported and exported[0] != '/data/models/intent_classifier/1/model.onnx':
    shutil.move(exported[0], '/data/models/intent_classifier/1/model.onnx')
print('ONNX export done.')
"

echo "=== [4/5] Write model repository config files ==="

mkdir -p /data/models/intent_classifier/1
mkdir -p /data/models/vllm_engine/1
mkdir -p /data/models/router_bls/1
mkdir -p /data/tokenizer-cache

# intent_classifier/config.pbtxt
# Uses Python backend + onnxruntime pip package because the
# -vllm-python-py3 image does not ship the compiled onnxruntime C++ backend.
cat > /data/models/intent_classifier/config.pbtxt << 'PBTXT'
name: "intent_classifier"
backend: "python"
max_batch_size: 0
input [
  { name: "input_ids"      data_type: TYPE_INT64 dims: [ 1, -1 ] },
  { name: "attention_mask" data_type: TYPE_INT64 dims: [ 1, -1 ] }
]
output [
  { name: "logits" data_type: TYPE_FP32 dims: [ 1, 3 ] }
]
instance_group [ { kind: KIND_CPU count: 1 } ]
PBTXT

# vllm_engine/config.pbtxt
cat > /data/models/vllm_engine/config.pbtxt << 'PBTXT'
name: "vllm_engine"
backend: "vllm"
max_batch_size: 0
model_transaction_policy { decoupled: true }
input [
  { name: "text_input"          data_type: TYPE_STRING dims: [ 1 ] },
  { name: "stream"              data_type: TYPE_BOOL   dims: [ 1 ] },
  { name: "sampling_parameters" data_type: TYPE_STRING dims: [ 1 ] optional: true },
  { name: "exclude_input_in_output" data_type: TYPE_BOOL dims: [ 1 ] optional: true }
]
output [
  { name: "text_output" data_type: TYPE_STRING dims: [ -1 ] }
]
instance_group [ { kind: KIND_MODEL count: 1 } ]
PBTXT

# vllm_engine/1/model.json  (vLLM engine parameters)
cat > /data/models/vllm_engine/1/model.json << 'JSON'
{
  "model": "Qwen/Qwen2.5-7B-Instruct",
  "gpu_memory_utilization": 0.85,
  "max_model_len": 2048,
  "enforce_eager": "true",
  "enable_lora": "true",
  "max_loras": 2,
  "max_lora_rank": 16
}
JSON

# vllm_engine/1/multi_lora.json  (LoRA adapter registry for Triton vLLM backend)
cat > /data/models/vllm_engine/1/multi_lora.json << 'JSON'
{
  "sql-expert": "/data/sql-lora",
  "creative":   "/data/creative-lora"
}
JSON

# router_bls/config.pbtxt
# No decoupled policy — model collects vllm_engine tokens server-side and
# returns a single response, making it callable over both HTTP and gRPC.
cat > /data/models/router_bls/config.pbtxt << 'PBTXT'
name: "router_bls"
backend: "python"
max_batch_size: 0
input [
  { name: "prompt"      data_type: TYPE_STRING dims: [ 1 ] },
  { name: "max_tokens"  data_type: TYPE_INT32  dims: [ 1 ] optional: true },
  { name: "temperature" data_type: TYPE_FP32   dims: [ 1 ] optional: true }
]
output [
  { name: "response" data_type: TYPE_STRING dims: [ 1 ] },
  { name: "intent"   data_type: TYPE_STRING dims: [ 1 ] }
]
PBTXT

echo "=== [5/5] Copy model.py files from repo mounts ==="
cp /repo/triton/models/router_bls/1/model.py /data/models/router_bls/1/model.py
cp /repo/triton/models/intent_classifier/1/model.py /data/models/intent_classifier/1/model.py

echo "=== Setup complete. Model repository at /data/models/ ==="
ls -R /data/models/
