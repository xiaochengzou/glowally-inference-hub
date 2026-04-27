# Glowally Inference Hub — Claude Code Context

## Project Overview
A production-ready AI inference platform on GKE Autopilot serving **Qwen2.5-7B-Instruct** with a **SQL LoRA adapter** (`sql-expert`) on a single **NVIDIA L4 GPU (24GB VRAM)**. Uses vLLM for serving, Google Cloud Monitoring for metrics, and Grafana for dashboards.

## Tech Stack
- **Inference engine**: vLLM with LoRA support
- **Cloud**: GCP — GKE Autopilot, Cloud Monitoring (Managed Prometheus)
- **GitOps**: GitHub Actions + Workload Identity Federation
- **Observability**: Google Cloud Monitoring + Grafana (stackdriver plugin)
- **Auto-scaling**: KEDA (installed, ScaledObject currently disabled)
- **Config management**: Kustomize

## Project Structure
```
k8s/
├── base/
│   ├── kustomization.yaml       # manages all resources + configMapGenerator
│   ├── deployment.yaml          # vLLM server + lora-downloader init container
│   ├── service.yaml             # LoadBalancer on port 80 → 8000
│   ├── monitoring.yaml          # PodMonitoring scrapes /metrics every 30s
│   ├── secret.env               # HF_TOKEN (never commit)
│   ├── secret.env.example       # template
│   ├── grafana/
│   │   ├── deployment.yaml      # Grafana pod (Recreate strategy, emptyDir)
│   │   ├── datasources.yaml     # stackdriver datasource, GCE auth
│   │   ├── dashboard-provider.yaml
│   │   └── dashboards/
│   │       ├── vllm.json        # vLLM application metrics dashboard
│   │       └── gpu-hardware.json # DCGM GPU hardware metrics dashboard
│   └── keda/
│       ├── scaled-object.yaml   # KEDA ScaledObject (commented out in kustomization)
│       └── install-keda.sh      # reference only — KEDA installed via CI/CD
└── overlays/
    └── gke/
        └── kustomization.yaml   # references ../../base
.github/
└── workflows/
    └── deploy.yml               # CI/CD pipeline
Makefile                         # task runner
test-inference.sh                # smoke tests + 5-min load test
docs/
└── GCP_INFRA.md                 # GCP setup checklist and commands
ROADMAP.md                       # feature roadmap for job portfolio
README.md                        # project documentation
```

## Key Design Decisions

### vLLM Deployment
- `strategy: Recreate` — GPU node can only run one pod at a time
- `--enforce-eager` — avoids CUDA Graph warmup crash on startup
- `--gpu-memory-utilization 0.7` — leaves headroom for LoRA adapters
- `--enable-lora --lora-modules sql-expert=/data/sql-lora` — serves LoRA adapter
- Init container `lora-downloader` runs `/bin/bash` (not `/bin/sh`) to download adapter from HuggingFace before vLLM starts

### Grafana
- Uses `emptyDir` (not PVC) — avoids zone binding issues on Autopilot
- Datasource type is `stackdriver` (internal plugin ID in Grafana 10.4.0, not `cloud-monitoring`)
- Dashboard JSON uses `queryType: timeSeriesList` format for stackdriver plugin
- Datasource UID: `P53B7819E0F26D6F4`
- DCGM metrics use full path: `prometheus.googleapis.com/DCGM_FI_DEV_*/gauge`
- vLLM metrics use full path: `prometheus.googleapis.com/vllm:*/gauge|counter|histogram`

### Metric aligners (important — wrong aligner causes 400 errors)
| Metric kind | Value type | Aligner |
|---|---|---|
| GAUGE | DOUBLE | `ALIGN_MEAN` |
| CUMULATIVE | DOUBLE (counter) | `ALIGN_RATE` |
| CUMULATIVE | DISTRIBUTION (histogram) | `ALIGN_DELTA` |

### KEDA Auto-scaling
- Installed via Helm in CI/CD pipeline (`helm upgrade --install` — idempotent)
- `ScaledObject` is commented out in `kustomization.yaml` — enable when ready
- `minReplicaCount: 1`, `maxReplicaCount: 2`
- Uses `gcp-stackdriver` scaler watching `vllm:num_requests_waiting/gauge`
- Scale-to-zero is NOT used — metric disappears when vLLM is down (chicken-and-egg)

### GKE Autopilot Specifics
- Workload Identity is enabled — pods authenticate via WI pool, NOT node compute SA
- Do NOT use `cloud.google.com/gke-accelerator` nodeSelector on non-GPU workloads
- DCGM metrics are auto-enabled on GKE 1.32.1+ clusters

## GCP Resources
- **Project**: `glowally-vllm`
- **Project number**: `612105008011`
- **Cluster**: `vllm-l4-cluster`, region `us-central1`
- **Node service account**: `612105008011-compute@developer.gserviceaccount.com`
- **GitHub Actions SA**: `github-actions@glowally-vllm.iam.gserviceaccount.com`
- **WI pool identity**: `principal://iam.googleapis.com/projects/612105008011/locations/global/workloadIdentityPools/glowally-vllm.svc.id.goog/subject/ns/default/sa/default`

## IAM Roles Required
| Principal | Role | Purpose |
|---|---|---|
| GitHub Actions SA | `roles/container.admin` | Install KEDA (ClusterRoles, webhooks) |
| WI pool identity (default/default) | `roles/monitoring.viewer` | Grafana reads Cloud Monitoring |
| WI pool identity (default/default) | `roles/browser` | Grafana lists GCP projects |
| Node SA | `roles/monitoring.viewer` | (reference only — WI takes precedence) |

## APIs Required
- `container.googleapis.com`
- `iam.googleapis.com`
- `sts.googleapis.com`
- `cloudresourcemanager.googleapis.com` — required for Grafana stackdriver plugin

## Common Commands
```bash
# Deploy
kubectl apply -k k8s/base/

# Validate before pushing
make check

# Scale up/down
make start
make stop

# View logs
make logs-vllm
make logs-grafana

# Access Grafana
kubectl port-forward svc/grafana 3000:80
# then open http://localhost:3000 (admin/admin)

# Check GPU memory
kubectl exec -it deployment/vllm-server -c vllm-engine -- /usr/local/nvidia/bin/nvidia-smi

# Run load test
./test-inference.sh

# Check KEDA
kubectl get scaledobject
kubectl get pods -n keda
```

## Known Issues & Gotchas
- `lora-downloader` init container must use `/bin/bash` not `/bin/sh` — substring syntax `${VAR:0:8}` fails in dash
- Grafana provisioned dashboards cannot be deleted via API — must delete pod to force re-provision
- KEDA `kubectl wait` times out on Autopilot — removed from CI/CD, KEDA starts in background
- vLLM rollout status skipped in CI/CD — GPU node provisioning takes 15-20 mins
- `roles/browser` must be granted to WI pool identity (not node SA) for Grafana project listing
- `cloudresourcemanager.googleapis.com` API must be enabled for Grafana stackdriver plugin

## Roadmap Status
- [x] Phase 1: CI/CD Pipeline (GitHub Actions + kubeconform + dry-run)
- [x] Phase 2: Auto-scaling (KEDA installed, ScaledObject disabled)
- [x] Phase 3: DCGM + GPU Dashboard
- [ ] Phase 4: Multi-LoRA adapter management
- [ ] Phase 5: Load testing + benchmark report
- [ ] Phase 6: Inference gateway
- [ ] Bonus: CUDA custom kernels
