# GCP Infrastructure Setup Checklist

This document tracks the required GCP resources and configurations needed for the Glowally Inference Hub deployment.

## 1. Google Cloud Project (GCP)
- [ ] **Project ID**: `YOUR_GCP_PROJECT_ID`
- [ ] **Billing**: Ensure billing is enabled for the project.
- [ ] **APIs Enabled**:
  - [ ] `container.googleapis.com` (GKE)
  - [ ] `iam.googleapis.com` (IAM)
  - [ ] `sts.googleapis.com` (Security Token Service)

## 2. GKE Autopilot Cluster
- [ ] **Cluster Name**: `vllm-cluster` (or your preference)
- [ ] **Region/Zone**: `us-central1` (L4 GPUs are common here)
- [ ] **Hardware**: NVIDIA L4 GPU (24GB VRAM)

## 3. Workload Identity Federation (WIF)
Used for passwordless authentication from GitHub Actions to GCP.
- [ ] **Pool Name**: `github-actions-pool`
- [ ] **Provider Name**: `github-actions-provider`
- [ ] **Service Account**: `github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com`
- [ ] **Roles Assigned**:
  - [ ] `roles/container.developer` (To deploy to GKE)
  - [ ] `roles/container.admin` (Required to install KEDA — creates ClusterRoles and ValidatingWebhookConfigurations)

## 4. GitHub Repository Secrets
Store these in GitHub (**Settings > Secrets and variables > Actions**):
- [ ] `HF_TOKEN`: Your Hugging Face read-access token.

## 5. Deployment Environment
- [ ] **GitHub Environment**: Create an environment named `production` if using environment-specific secrets.

---

### Reference Commands
For quick setup via `gcloud`:

```bash
# Enable APIs
- [ ] gcloud services enable container.googleapis.com iamcredentials.googleapis.com
- [ ] gcloud services enable cloudresourcemanager.googleapis.com --project=glowally-vllm (Required for Grafana stackdriver plugin to list GCP projects)

# Create GKE Autopilot cluster
gcloud container clusters create-auto vllm-cluster \
    --region us-central1 \
    --project YOUR_GCP_PROJECT_ID

# Grant container.admin role to GitHub Actions service account
# Required for KEDA installation — allows creating ClusterRoles,
# ClusterRoleBindings, and ValidatingWebhookConfigurations
gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
  --member="serviceAccount:github-actions@YOUR_GCP_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.admin"

# Find your project number first:
gcloud projects describe YOUR_GCP_PROJECT_ID --format="value(projectNumber)"

# ── Grafana IAM (Workload Identity) ──────────────────────────────────────────
# GKE Autopilot uses Workload Identity — pods authenticate via the Kubernetes
# default service account mapped to a GCP Workload Identity pool identity.
# The node compute service account is NOT used for pod-level API calls.
#
# Grant monitoring.viewer to Workload Identity
# Required for Grafana to read Google Cloud Monitoring metrics
gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
  --member="principal://iam.googleapis.com/projects/YOUR_PROJECT_NUMBER/locations/global/workloadIdentityPools/YOUR_GCP_PROJECT_ID.svc.id.goog/subject/ns/default/sa/default" \
  --role="roles/monitoring.viewer"

# Grant browser to Workload Identity
# Required for Grafana stackdriver plugin to list GCP projects
# (calls /resources/projects API which needs resourcemanager.projects.get)
gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
  --member="principal://iam.googleapis.com/projects/YOUR_PROJECT_NUMBER/locations/global/workloadIdentityPools/YOUR_GCP_PROJECT_ID.svc.id.goog/subject/ns/default/sa/default" \
  --role="roles/browser"

# Note: The following grants to the node compute service account are NOT
# effective when Workload Identity is enabled — kept here for reference only
# gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
#   --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
#   --role="roles/monitoring.viewer"
# gcloud projects add-iam-policy-binding YOUR_GCP_PROJECT_ID \
#   --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
#   --role="roles/browser"
```