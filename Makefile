.PHONY: help validate dry-run deploy check start stop logs \
        triton-validate triton-dry-run triton-check triton-deploy triton-start triton-stop triton-logs triton-status \
        teardown

# Default target — show help
help:
	@echo ""
	@echo "Glowally Inference Hub — Available Commands"
	@echo "============================================"
	@echo ""
	@echo "  Validation"
	@echo "    make validate        Validate K8s manifests with kubeconform"
	@echo "    make dry-run         Dry run against live GKE cluster"
	@echo "    make check           Run both validate and dry-run"
	@echo ""
	@echo "  vLLM Deployment"
	@echo "    make deploy          Apply vLLM manifests to GKE cluster"
	@echo "    make start           Scale up vLLM and Grafana"
	@echo "    make stop            Scale down vLLM and Grafana (stops GPU billing)"
	@echo ""
	@echo "  Triton Deployment"
	@echo "    make triton-validate Validate Triton manifests with kubeconform"
	@echo "    make triton-dry-run  Dry run Triton manifests against live cluster"
	@echo "    make triton-check    Run both triton-validate and triton-dry-run"
	@echo "    make triton-deploy   Validate + apply Triton manifests to GKE cluster"
	@echo "    make triton-start    Scale up Triton server"
	@echo "    make triton-stop     Scale down Triton server (stops GPU billing)"
	@echo "    make triton-logs     Stream Triton server logs"
	@echo "    make triton-status   Show Triton pod status"
	@echo ""
	@echo "  Teardown"
	@echo "    make teardown        Delete ALL cluster resources (prompts for confirmation)"
	@echo ""
	@echo "  Debugging"
	@echo "    make logs-vllm       Stream vLLM server logs"
	@echo "    make logs-grafana    Stream Grafana logs"
	@echo "    make status          Show all pod status"
	@echo ""

# ── Validation ────────────────────────────────────────────────────────────────

validate:
	@echo "Validating K8s manifests with kubeconform..."
	kustomize build k8s/overlays/gke | kubeconform \
	  --strict \
	  --ignore-missing-schemas \
	  --kubernetes-version 1.33.0 \
	  --summary
	@echo "Validation passed ✅"

dry-run:
	@echo "Running server-side dry run against GKE cluster..."
	kubectl apply -k k8s/overlays/gke --dry-run=server
	@echo "Dry run passed ✅"

check: validate dry-run

# ── Deployment ────────────────────────────────────────────────────────────────

deploy: check
	@echo "Deploying to GKE..."
	kubectl apply -k k8s/overlays/gke
	@echo "Grafana rollout..."
	kubectl rollout status deployment/grafana --timeout=120s
	@echo "Deploy complete ✅"
	@echo "Note: vLLM GPU node provisioning may take 15-20 mins — run 'make status' to monitor"

# ── Cost Management ───────────────────────────────────────────────────────────

start:
	@echo "Starting Glowally Inference Hub..."
	kubectl scale deployment llm-adaptive-router --replicas=1
	kubectl scale deployment grafana --replicas=1
	@echo "Waiting for Grafana to be ready..."
	kubectl wait --for=condition=ready pod -l app=grafana --timeout=60s
	@echo ""
	@echo "Services are up ✅"
	@echo "vLLM endpoint: http://$$(kubectl get svc llm-adaptive-router-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/v1"
	@echo "Grafana:       run 'kubectl port-forward svc/grafana 3000:80' then open http://localhost:3000"

stop:
	@echo "Stopping Glowally Inference Hub..."
	kubectl scale deployment llm-adaptive-router --replicas=0
	kubectl scale deployment grafana --replicas=0
	@echo "All services scaled down ✅ GPU billing stopped"
	@echo "Run 'make start' to bring everything back up"

# ── Triton ────────────────────────────────────────────────────────────────────

triton-validate:
	@echo "Validating Triton manifests with kubeconform..."
	kustomize build --load-restrictor=LoadRestrictionsNone k8s/overlays/triton | kubeconform \
	  --strict \
	  --ignore-missing-schemas \
	  --kubernetes-version 1.33.0 \
	  --summary
	@echo "Validation passed ✅"

triton-dry-run:
	@echo "Running server-side dry run for Triton manifests..."
	kustomize build --load-restrictor=LoadRestrictionsNone k8s/overlays/triton | kubectl apply -f - --dry-run=server
	@echo "Dry run passed ✅"

triton-check: triton-validate triton-dry-run

triton-deploy: triton-check
	@echo "Deploying Triton Inference Server..."
	kustomize build --load-restrictor=LoadRestrictionsNone k8s/overlays/triton | kubectl apply -f -
	@echo "Restarting deployment to pick up ConfigMap changes..."
	kubectl rollout restart deployment/llm-adaptive-router
	@echo "Waiting for Grafana to be ready..."
	kubectl rollout status deployment/grafana --timeout=120s
	@echo "Triton deploy complete ✅"
	@echo "Note: init container downloads models + exports ONNX — allow 5-10 mins before Triton is ready"
	@echo "Run 'make triton-status' to monitor"

triton-start:
	@echo "Scaling up Triton server..."
	kubectl scale deployment llm-adaptive-router --replicas=1
	@echo "Triton server scaling up ✅"
	@echo "Run 'make triton-status' to monitor readiness"

triton-stop:
	@echo "Scaling down Triton server..."
	kubectl scale deployment llm-adaptive-router --replicas=0
	@echo "Triton server scaled down ✅ GPU billing stopped"
	@echo "Run 'make triton-start' to bring it back up"

triton-logs:
	kubectl logs -f -l app=llm-adaptive-router -c triton-server

triton-status:
	@echo "=== Pods ==="
	kubectl get pods -l app=llm-adaptive-router
	@echo ""
	@echo "=== Init container logs (model-setup) ==="
	kubectl logs -l app=llm-adaptive-router -c model-setup --tail=20 2>/dev/null || echo "(init container not running)"

# ── Debugging ─────────────────────────────────────────────────────────────────

logs-vllm:
	kubectl logs -f -l app=llm-adaptive-router -c vllm-engine

logs-grafana:
	kubectl logs -f deployment/grafana

status:
	kubectl get pods

# ── Teardown ──────────────────────────────────────────────────────────────────

teardown:
	@bash teardown.sh