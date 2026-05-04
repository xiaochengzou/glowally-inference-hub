#!/usr/bin/env python3
"""
Extended routing test — 20 prompts across SQL, FINANCIAL, and GENERAL categories.

Sends all prompts sequentially and prints a summary with intent classification
accuracy (expected vs actual) and a pass/fail result for each.
Internally it classifies intent (DistilBERT) and routes to vllm_engine (LoRA).

Usage:
    pip install "tritonclient[grpc]" numpy
    python test-router-load.py           # gRPC port 8001 (default)
    python test-router-load.py --http    # HTTP port 80
"""

import subprocess
import sys

try:
    import numpy as np
    import tritonclient.grpc as grpcclient
except ImportError:
    print('ERROR: Run: pip install "tritonclient[grpc]" numpy')
    sys.exit(1)

SERVICE_NAME = "llm-adaptive-router-service"
MAX_TOKENS   = 200

# (expected_intent, prompt)
PROMPTS = [
    # ── SQL (7) ──────────────────────────────────────────────────────────────
    ("SQL", "Table 'orders' has columns: id, customer_id, total, status, created_at. "
            "Write a query to find all pending orders placed in the last 7 days."),
    ("SQL", "Schema: employees(id, name, department, salary, manager_id). "
            "Find the top 3 highest-paid employees in each department."),
    ("SQL", "Table 'events' has columns: id, user_id, type, timestamp. "
            "Count how many times each user triggered a login event this month."),
    ("SQL", "Schema: products(id, name, price, stock), categories(id, name), "
            "product_categories(product_id, category_id). "
            "List all products in the 'Electronics' category with stock above 50."),
    ("SQL", "Write a SQL query using a window function to rank employees by salary "
            "within each department."),
    ("SQL", "Table 'sessions' has columns: id, user_id, started_at, ended_at. "
            "Find users whose average session duration exceeds 30 minutes."),
    ("SQL", "Schema: invoices(id, client_id, amount, paid, due_date). "
            "Find all overdue unpaid invoices and the total outstanding amount per client."),

    # ── FINANCIAL (7) ────────────────────────────────────────────────────────
    ("FINANCIAL", "What is the difference between a stock's intrinsic value and its market price, "
                  "and how does value investing exploit that gap?"),
    ("FINANCIAL", "Explain how the yield curve signals economic recession and what an inverted "
                  "yield curve means for bond investors."),
    ("FINANCIAL", "How do I calculate the weighted average cost of capital (WACC) and why is it "
                  "used as a discount rate in DCF analysis?"),
    ("FINANCIAL", "What is the difference between systematic risk and unsystematic risk, "
                  "and which one can be eliminated through diversification?"),
    ("FINANCIAL", "Explain how options pricing works using the Black-Scholes model and what "
                  "the Greeks (delta, gamma, theta) represent."),
    ("FINANCIAL", "How does quantitative easing by the Federal Reserve affect equity valuations "
                  "and inflation expectations?"),
    ("FINANCIAL", "What are the key differences between a growth stock and a value stock, "
                  "and how would you screen for each using financial ratios?"),

    # ── GENERAL (6) ──────────────────────────────────────────────────────────
    ("GENERAL", "Explain the difference between supervised, unsupervised, and reinforcement "
                "learning with a real-world example of each."),
    ("GENERAL", "What is the CAP theorem in distributed systems and how do databases like "
                "Cassandra and DynamoDB make trade-offs?"),
    ("GENERAL", "How does the transformer architecture work, and why did it replace RNNs "
                "for most NLP tasks?"),
    ("GENERAL", "What is the difference between a mutex and a semaphore, and when would you "
                "use each in concurrent programming?"),
    ("GENERAL", "Explain how HTTPS works end-to-end — from the TLS handshake to encrypted "
                "data transfer."),
    ("GENERAL", "What is eventual consistency in distributed databases and how does it differ "
                "from strong consistency?"),
]


# ── Helpers ───────────────────────────────────────────────────────────────────

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
    if use_http:
        import tritonclient.http as httpclient
        InferInput = httpclient.InferInput
    else:
        InferInput = grpcclient.InferInput
    # Client does not need to sepcify which model and adapter the requests are sent to.
    # The backend automatically identify it, and routes the requests to proper model and its adapter.
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


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    use_http = "--http" in sys.argv

    print("[1/4] Detecting LoadBalancer IP...")
    ip = get_external_ip()
    print(f"      External IP: {ip}")

    transport = "HTTP" if use_http else "gRPC"
    port      = 80 if use_http else 8001
    print(f"\n[2/4] Connecting via {transport} ({ip}:{port})...")
    if use_http:
        try:
            import tritonclient.http as httpclient
        except ImportError:
            print('ERROR: Run: pip install "tritonclient[http]"')
            sys.exit(1)
        client = httpclient.InferenceServerClient(f"{ip}:{port}")
    else:
        client = grpcclient.InferenceServerClient(f"{ip}:{port}", verbose=False)

    print("\n[3/4] Server health check...")
    if not client.is_server_ready():
        print("ERROR: server NOT ready")
        sys.exit(1)
    for model in ("intent_classifier", "router_bls", "vllm_engine"):
        ready = client.is_model_ready(model)
        print(f"      {model:20s}  {'READY' if ready else 'NOT READY'}")
        if not ready:
            sys.exit(1)

    print(f"\n[4/4] Running {len(PROMPTS)} prompts through router_bls...\n")
    print(f"  {'#':>2}  {'Expected':10}  {'Got':10}  {'OK':4}  {'Prompt (truncated)':50}  Response")
    print("  " + "-" * 130)

    passed = 0
    failed = 0
    by_category = {}

    for i, (expected, prompt) in enumerate(PROMPTS, 1):
        intent, response = infer(client, prompt, MAX_TOKENS, use_http, request_id=str(i))
        ok = intent == expected
        mark = "✓" if ok else "✗"
        if ok:
            passed += 1
        else:
            failed += 1

        cat = by_category.setdefault(expected, {"pass": 0, "fail": 0})
        if ok:
            cat["pass"] += 1
        else:
            cat["fail"] += 1

        prompt_short   = (prompt[:48] + "..") if len(prompt) > 50 else prompt
        response_short = response[:80].replace("\n", " ").strip()
        print(f"  {i:>2}  {expected:10}  {intent:10}  {mark:4}  {prompt_short:50}  {response_short}")

    # Summary
    total = passed + failed
    print("\n" + "=" * 60)
    print(f"  Results: {passed}/{total} passed  ({100*passed//total}%)")
    print()
    for cat, counts in by_category.items():
        n = counts["pass"] + counts["fail"]
        print(f"  {cat:10}  {counts['pass']}/{n}")
    print("=" * 60)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
