# Glowally Inference Hub

## Overview

Glowally Inference Hub is a production-ready AI inference platform on **GKE Autopilot** that demonstrates **intelligent request routing** for LLM serving. The system classifies incoming prompts by intent and automatically routes each request to the most appropriate model — a SQL LoRA adapter, a creative writing LoRA adapter, or the base model — all on a single **NVIDIA L4 GPU (24GB VRAM)**.

The core innovation is the **server-side routing pipeline**: the client sends only a prompt, with no knowledge of which model or adapter handles it. A lightweight DistilBERT classifier (running on CPU) detects the intent and selects the adapter before the request reaches vLLM.

## Architecture

```
Client (HTTP or gRPC)
        │
        ▼
  router_bls (BLS)          ← Triton Python backend, synchronous
        │
        ├─ intent_classifier (DistilBERT ONNX, CPU)
        │       classifies prompt → SQL / CREATIVE / GENERAL
        │
        └─ vllm_engine (vLLM backend, GPU)
                routes to:
                  sql-expert LoRA    (vindows/qwen2.5-7b-text-to-sql)
                  creative LoRA      (miarick/Qwen2.5-7B-Instruct-cyberpunk-literary-lora)
                  base model         (Qwen/Qwen2.5-7B-Instruct)
```

### Intent Classifier

The DistilBERT classifier is a fine-tuned 3-class model trained to distinguish SQL, creative writing, and general prompts.

- **Training notebook**: [Google Colab](https://colab.research.google.com/drive/1TBD8sqfuCPqfo2kTNV9MP0veaiHUx9Qv)
- **Published model**: [xczou/distilbert-intent-sql-creative-general](https://huggingface.co/xczou/distilbert-intent-sql-creative-general) on HuggingFace
- Exported to ONNX at pod startup and served on CPU via `onnxruntime`, keeping the full GPU free for vLLM

### Serving Stack

| Component | Role |
|---|---|
| **NVIDIA Triton 24.09** | Inference server — hosts all three models |
| **vLLM 0.5.3** | LLM engine with multi-LoRA support |
| **Qwen2.5-7B-Instruct** | Base LLM |
| **DistilBERT (ONNX)** | Intent classifier — CPU only |
| **router_bls** | BLS orchestration layer — classifies then routes |

## Technical Stack

- **Inference Server**: NVIDIA Triton Inference Server 24.09 (vLLM backend)
- **LLM Engine**: vLLM with multi-LoRA adapter support
- **Cloud**: GCP — GKE Autopilot, Cloud Monitoring (Managed Prometheus)
- **Hardware**: NVIDIA L4 GPU (24GB VRAM)
- **Monitoring**: Google Cloud Monitoring + Grafana (Stackdriver datasource)
- **CI/CD**: GitHub Actions + Workload Identity Federation + Kustomize
- **Auto-scaling**: KEDA (installed, ScaledObject currently disabled due to GPU quota limiation)

## Project Structure

```
k8s/
├── base/                        # Shared resources (service, monitoring, grafana)
└── overlays/
    ├── gke/                     # vLLM-only deployment
    └── triton/                  # Triton + router_bls deployment (active)
        ├── kustomization.yaml
        └── deployment.yaml      # Patches base with Triton init container + server

triton/
├── models/
│   ├── router_bls/1/model.py   # BLS routing logic (intent → LoRA selection)
│   └── intent_classifier/1/model.py  # ONNX inference wrapper
└── scripts/
    └── model-setup.sh           # Init container: downloads LoRAs, exports ONNX,
                                 # writes Triton config files

test-router.py                   # End-to-end test — calls router_bls (no model specified)
```

## Deploying

### Prerequisites

- `kubectl` configured against a GKE Autopilot cluster
- `kustomize` CLI installed
- `k8s/base/secret.env` created from `secret.env.example` with your HuggingFace token

### Deploy Triton + router_bls

```bash
make triton-deploy
```

This validates manifests, applies them, and restarts the deployment. The init container runs on first pod start (~5–10 min) to download LoRA adapters and export the classifier to ONNX.

Monitor startup:
```bash
make triton-logs
```

### Scale up / down (cost control)

```bash
make triton-start    # scale to 1 replica
make triton-stop     # scale to 0 — stops GPU billing
```

## Testing

Please see the demo video here: https://youtu.be/8Wq1t6XmSsw

### End-to-end routing test

```bash
pip install "tritonclient[grpc]" numpy
python test-router.py           # gRPC (default)
python test-router.py --http    # HTTP
```

Sends three prompts (SQL, creative, general) to `router_bls`. The client specifies only the prompt — no model name, no adapter name. The server classifies the intent and selects the adapter automatically.

## Monitoring & Grafana

Grafana is deployed as a ClusterIP service. Access it locally:

```bash
kubectl port-forward svc/grafana 3000:80
# open http://localhost:3000  (admin / admin)
```

Dashboards include vLLM request metrics (queue depth, KV cache utilization, throughput, latency) and DCGM GPU hardware metrics.

Metrics are scraped from Triton's metrics port (8002) by PodMonitoring and stored in Google Cloud Monitoring.

## CI/CD

GitHub Actions runs on every push to `main`:
1. `kubeconform` schema validation
2. Server-side dry run against the live GKE cluster
3. `kubectl apply -k` deploy

Authentication uses Workload Identity Federation — no long-lived credentials stored in GitHub.
