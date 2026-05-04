#!/usr/bin/env python3
"""
End-to-end test for the router_bls pipeline.

router_bls is a standard synchronous model — callable over HTTP or gRPC.
Internally it classifies intent (DistilBERT) and routes to vllm_engine (LoRA).

Usage:
    pip install "tritonclient[grpc]" numpy
    python test-router.py [--http]        # default: gRPC port 8001
    python test-router.py --http          # HTTP port 80
"""

import subprocess
import sys

try:
    import numpy as np
    import tritonclient.grpc as grpcclient
except ImportError:
    print("ERROR: Run: pip install \"tritonclient[grpc]\" numpy")
    sys.exit(1)

SERVICE_NAME = "llm-adaptive-router-service"
MAX_TOKENS   = 150

PROMPTS = [
    ("SQL",       "Table 'users' has columns: id, name, email, created_at. Write a query to find all users created in the last 30 days."),
    ("FINANCIAL", "What is the price-to-earnings ratio and how should I use it to evaluate a stock?"),
    ("GENERAL",   "What is the difference between a process and a thread?"),
]


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def get_external_ip():
    for jsonpath in [
        "{.status.loadBalancer.ingress[0].ip}",
        "{.status.loadBalancer.ingress[0].hostname}",
    ]:
        ip = subprocess.check_output(
            ["kubectl", "get", "svc", SERVICE_NAME, "-o", f"jsonpath={jsonpath}"],
            text=True,
        ).strip()
        if ip:
            return ip
    print(f"ERROR: External IP not available. Run: kubectl get svc {SERVICE_NAME}")
    sys.exit(1)


def make_inputs(prompt, max_tokens, use_http):
    """Build InferInput list for the chosen transport.

    Unlike test-inference.sh which explicitly names a model and LoRA adapter
    in the client request, we only send a prompt here. router_bls classifies the
    intent server-side and selects the adapter automatically.
    """
    if use_http:
        import tritonclient.http as httpclient
        InferInput = httpclient.InferInput
    else:
        InferInput = grpcclient.InferInput

    prompt_in = InferInput("prompt",     [1], "BYTES")
    tokens_in = InferInput("max_tokens", [1], "INT32")

    prompt_in.set_data_from_numpy(np.array([prompt.encode()], dtype=object))
    tokens_in.set_data_from_numpy(np.array([max_tokens],      dtype=np.int32))

    return [prompt_in, tokens_in]


def infer(client, prompt, max_tokens, use_http, request_id="0"):
    inputs = make_inputs(prompt, max_tokens, use_http)
    result = client.infer("router_bls", inputs, request_id=request_id)
    intent   = result.as_numpy("intent")[0].decode()
    response = result.as_numpy("response")[0].decode()
    return intent, response


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main():
    use_http = "--http" in sys.argv

    # [1] Resolve LoadBalancer IP
    print("[1/5] Detecting LoadBalancer IP...")
    ip = get_external_ip()
    print(f"External IP: {ip}")

    # [2] Connect
    transport = "HTTP" if use_http else "gRPC"
    port      = 80 if use_http else 8001
    print(f"\n[2/5] Connecting via {transport} ({ip}:{port})...")
    if use_http:
        try:
            import tritonclient.http as httpclient
        except ImportError:
            print("ERROR: HTTP support not installed. Run: pip install \"tritonclient[http]\"")
            sys.exit(1)
        client = httpclient.InferenceServerClient(f"{ip}:{port}")
    else:
        client = grpcclient.InferenceServerClient(f"{ip}:{port}", verbose=False)

    # [3] Server health
    print("\n[3/5] Server health...")
    if not client.is_server_ready():
        print("ERROR: server NOT ready")
        sys.exit(1)
    print("  server READY")

    # [4] Model readiness
    print("\n[4/5] Model readiness...")
    for model in ("intent_classifier", "router_bls", "vllm_engine"):
        ready = client.is_model_ready(model)
        print(f"  {model}  {'READY' if ready else 'NOT READY'}")
        if not ready:
            sys.exit(1)

    # [5] End-to-end prompts through router_bls
    print("\n[5/5] Routing prompts through router_bls...\n")
    for i, (label, prompt) in enumerate(PROMPTS):
        print(f"  [{label}] {prompt[:80]}...")
        intent, response = infer(client, prompt, MAX_TOKENS, use_http, request_id=str(i + 1))
        print(f"  intent:   {intent}")
        print(f"  response: {response[:200].strip().replace(chr(10), ' ')}")
        print()

    print("Done.")


if __name__ == "__main__":
    main()
