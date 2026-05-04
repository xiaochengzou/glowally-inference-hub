"""
Router BLS (Business Logic Scripting) model.

Request flow:
  1. Receive prompt from client (HTTP or gRPC — no decoupled policy required)
  2. Tokenize and call intent_classifier (DistilBERT ONNX, CPU, ~8ms)
  3. Map intent → LoRA adapter name
  4. Call vllm_engine with exec(decoupled=True) to collect streamed tokens server-side
  5. Return assembled response as a single reply
"""

import json

import numpy as np
import triton_python_backend_utils as pb_utils


# --------------------------------------------------------------------------- #
# Intent routing table
# --------------------------------------------------------------------------- #
INTENT_LABELS = ["GENERAL", "SQL", "FINANCIAL"]

_LORA_FOR_INTENT = {
    "SQL":       "sql-expert",
    "FINANCIAL": "financial",
    "GENERAL":   None,   # base model, no LoRA adapter
}

_DEFAULT_MAX_TOKENS  = 512
_DEFAULT_TEMPERATURE = 0.7
_CLASSIFIER_MAX_LEN  = 128


# --------------------------------------------------------------------------- #
# Triton Python model
# --------------------------------------------------------------------------- #
class TritonPythonModel:

    def initialize(self, args):
        self.model_config = json.loads(args["model_config"])

        from transformers import AutoTokenizer
        self.tokenizer = AutoTokenizer.from_pretrained(
            "distilbert-base-uncased",
            cache_dir="/data/tokenizer-cache",
        )
        pb_utils.Logger.log_info("router_bls: tokenizer ready")

    def execute(self, requests):
        responses = []
        for request in requests:
            responses.append(self._handle_request(request))
        return responses

    def finalize(self):
        pb_utils.Logger.log_info("router_bls: shutting down")

    # ---------------------------------------------------------------------- #
    # Internal helpers
    # ---------------------------------------------------------------------- #
    def _handle_request(self, request):
        try:
            prompt, max_tokens, temperature = self._parse_inputs(request)
            pb_utils.Logger.log_info(f"router_bls: classifying prompt={prompt[:80]}")
            intent = self._classify_intent(prompt)
            pb_utils.Logger.log_info(f"router_bls: intent={intent}")
            text = self._collect_from_vllm(prompt, intent, max_tokens, temperature)
            return pb_utils.InferenceResponse(output_tensors=[
                pb_utils.Tensor("response", np.array([text.encode()],   dtype=object)),
                pb_utils.Tensor("intent",   np.array([intent.encode()], dtype=object)),
            ])
        except Exception as exc:
            pb_utils.Logger.log_error(f"router_bls: {exc}")
            return pb_utils.InferenceResponse(
                output_tensors=[],
                error=pb_utils.TritonError(str(exc)),
            )

    def _parse_inputs(self, request):
        prompt = (
            pb_utils.get_input_tensor_by_name(request, "prompt")
            .as_numpy()[0]
            .decode("utf-8")
        )
        max_t = pb_utils.get_input_tensor_by_name(request, "max_tokens")
        max_tokens = int(max_t.as_numpy()[0]) if max_t is not None else _DEFAULT_MAX_TOKENS

        temp_t = pb_utils.get_input_tensor_by_name(request, "temperature")
        temperature = float(temp_t.as_numpy()[0]) if temp_t is not None else _DEFAULT_TEMPERATURE

        return prompt, max_tokens, temperature

    def _classify_intent(self, prompt: str) -> str:
        enc = self.tokenizer(
            prompt,
            max_length=_CLASSIFIER_MAX_LEN,
            truncation=True,
            padding="max_length",
            return_tensors="np",
        )
        resp = pb_utils.InferenceRequest(
            model_name="intent_classifier",
            requested_output_names=["logits"],
            inputs=[
                pb_utils.Tensor("input_ids",      enc["input_ids"].astype(np.int64)),
                pb_utils.Tensor("attention_mask", enc["attention_mask"].astype(np.int64)),
            ],
        ).exec(decoupled=False)

        if resp.has_error():
            raise RuntimeError(f"intent_classifier error: {resp.error().message()}")

        logits = pb_utils.get_output_tensor_by_name(resp, "logits").as_numpy()
        return INTENT_LABELS[int(np.argmax(logits[0]))]

    def _collect_from_vllm(self, prompt, intent, max_tokens, temperature):
        """Call vllm_engine and collect all streamed tokens into a single string."""
        params = {"max_tokens": max_tokens, "temperature": temperature}
        lora = _LORA_FOR_INTENT[intent]
        if lora:
            params["lora_name"] = lora
        sampling_params = json.dumps(params)
        vllm_req = pb_utils.InferenceRequest(
            model_name="vllm_engine",
            requested_output_names=["text_output"],
            inputs=[
                pb_utils.Tensor("text_input",          np.array([prompt],          dtype=object)),
                pb_utils.Tensor("stream",              np.array([True],             dtype=bool)),
                pb_utils.Tensor("sampling_parameters", np.array([sampling_params], dtype=object)),
            ],
        )
        chunks = []
        for vllm_resp in vllm_req.exec(decoupled=True):
            if vllm_resp.has_error():
                raise RuntimeError(f"vllm_engine error: {vllm_resp.error().message()}")
            token = pb_utils.get_output_tensor_by_name(vllm_resp, "text_output")
            if token is not None:
                raw = token.as_numpy().flat[0]
                text = raw.decode() if isinstance(raw, bytes) else str(raw)
                if text:
                    chunks.append(text)
        return "".join(chunks)
