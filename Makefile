.PHONY: help validate dry-run deploy check start stop logs

# Default target — show help
help:
	@echo ""
	@echo "Glowally Inference Hub — Available Commands"
	@echo "============================================"
	@echo ""
	@echo "  Validation"
	@echo "    make validate   Validate K8s manifests with kubeconform"
	@echo "    make dry-run    Dry run against live GKE cluster"
	@echo "    make check      Run both validate and dry-run"
	@echo ""
	@echo "  Deployment"
	@echo "    make deploy     Apply manifests to GKE cluster"
	@echo ""
	@echo "  Cost Management"
	@echo "    make start      Scale up vLLM and Grafana"
	@echo "    make stop       Scale down vLLM and Grafana (stops GPU billing)"
	@echo ""
	@echo "  Debugging"
	@echo "    make logs-vllm  Stream vLLM server logs"
	@echo "    make logs-grafana Stream Grafana logs"
	@echo "    make status     Show all pod status"
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
	kubectl scale deployment vllm-server --replicas=1
	kubectl scale deployment grafana --replicas=1
	@echo "Waiting for Grafana to be ready..."
	kubectl wait --for=condition=ready pod -l app=grafana --timeout=60s
	@echo ""
	@echo "Services are up ✅"
	@echo "vLLM endpoint: http://$$(kubectl get svc vllm-lb-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/v1"
	@echo "Grafana:       run 'kubectl port-forward svc/grafana 3000:80' then open http://localhost:3000"

stop:
	@echo "Stopping Glowally Inference Hub..."
	kubectl scale deployment vllm-server --replicas=0
	kubectl scale deployment grafana --replicas=0
	@echo "All services scaled down ✅ GPU billing stopped"
	@echo "Run 'make start' to bring everything back up"

# ── Debugging ─────────────────────────────────────────────────────────────────

logs-vllm:
	kubectl logs -f -l app=vllm-server -c vllm-engine

logs-grafana:
	kubectl logs -f deployment/grafana

status:
	kubectl get pods