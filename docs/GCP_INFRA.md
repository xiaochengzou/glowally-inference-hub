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
gcloud services enable container.googleapis.com iamcredentials.googleapis.com

# Create GKE Autopilot cluster
gcloud container clusters create-auto vllm-cluster \
    --region us-central1 \
    --project YOUR_GCP_PROJECT_ID
```
