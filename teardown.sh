#!/bin/bash
set -e

# --------------------------------------------------------------------------- #
# teardown.sh — delete all Kubernetes resources deployed by this repo.
#
# What gets deleted:
#   - llm-adaptive-router Deployment (Triton server + init container)
#   - grafana Deployment
#   - llm-adaptive-router-service LoadBalancer
#   - PodMonitoring
#   - All Kustomize-generated ConfigMaps (router_bls, intent_classifier,
#     model-setup-script, grafana dashboards/datasources)
#   - hf-token-secret Secret
#   - KEDA ScaledObject (vllm-scaler)
#   - KEDA system (Helm release + keda namespace)
#
# What is NOT touched:
#   - The GKE cluster itself
#   - Cloud Monitoring metric data
#   - Grafana dashboard data (none persisted — emptyDir)
# --------------------------------------------------------------------------- #

echo ""
echo "WARNING: This will delete ALL application resources from the cluster."
echo "The GKE cluster itself will NOT be deleted."
echo ""
read -p "Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "[1/4] Scaling down to release GPU before deletion..."
kubectl scale deployment llm-adaptive-router --replicas=0 2>/dev/null || true
kubectl scale deployment grafana              --replicas=0 2>/dev/null || true

echo ""
echo "[2/4] Deleting Triton overlay resources..."
kustomize build --load-restrictor=LoadRestrictionsNone k8s/overlays/triton \
    | kubectl delete -f - --ignore-not-found

echo ""
echo "[3/4] Deleting base resources (grafana, monitoring, secret)..."
kubectl delete -k k8s/base/ --ignore-not-found

echo ""
echo "[4/4] Deleting KEDA..."
kubectl delete scaledobject vllm-scaler --ignore-not-found
helm uninstall keda -n keda 2>/dev/null || true
kubectl delete namespace keda --ignore-not-found

echo ""
echo "Teardown complete. All application resources removed."
echo "Run 'kubectl get all' to verify."
