# Glowally Inference Hub

## Overview
Glowally Inference Hub is a cost-efficient, multi-tenant AI inference platform hosted on **GKE Autopilot**. It serves as a comprehensive demonstration of a production-ready infrastructure setup for **AI Inference Engineering**. The system utilizes **vLLM** to serve specialized **LoRA adapters** (starting with Text-to-SQL) alongside a base **Qwen 2.5 7B** model on a single **NVIDIA L4 GPU (24GB VRAM)**.

The primary goal is to showcase the integration of modern LLM serving engines with cloud-native orchestration, providing a blueprint for scalable and maintainable AI inference systems.

## Technical Stack
- **Serving Engine**: vLLM (v0.19.0+)
- **Cloud Infrastructure**: Google Cloud Platform (GCP)
- **Container Orchestration**: Google Kubernetes Engine (GKE) Autopilot
- **Hardware**: NVIDIA L4 GPU (24GB VRAM)
- **CI/CD & GitOps**: GitHub Actions + Workload Identity Federation (WIF) + Kustomize
- **Tooling & Services**: TypeScript, Vitest, kubeconform

## Architecture & Deployment
Detailed setup instructions can be found in [GCP Infrastructure Setup](./docs/GCP_INFRA.md).

### vLLM Configuration
To ensure stability on the 24GB L4 GPU, the following parameters are mandatory:
- `--enforce-eager`: Bypasses the 5+ minute CUDA Graph warmup crash.
- `--gpu-memory-utilization 0.7`: Provides a VRAM safety buffer.
- `--enable-lora`: Enabled for multi-tenant adapter support.
- `--max-loras 1`: Initial limit to prevent OOM.
- **Deployment Strategy**: Use `type: Recreate` to ensure the GPU is fully freed before rescheduling.

### Key Paths & Troubleshooting
- **GPU Driver**: Access `nvidia-smi` via `/usr/local/nvidia/bin/nvidia-smi`.
- **OOM Prevention**: If CUDA OOM occurs, verify Eager mode and VRAM utilization settings.

## Engineering Standards
- **GitOps**: Use Kustomize (`kubectl apply -k`) for deployments.
- **Validation**: Use `kubeconform` and `kubectl apply --server-dry-run` for pre-push testing.
- **Code Style**: Functional programming preferred; No default exports.
- **Documentation**: All public APIs must have TSDoc comments.
- **Testing**: Vitest for unit and integration tests.

## Maintenance Operations
- **Scale Up**: `kubectl scale deployment vllm-server --replicas=1`
- **Scale Down**: `kubectl scale deployment vllm-server --replicas=0` (Stops billing while preserving state).
- **Verify Models**: `curl http://[LB_IP]/v1/models | jq .`

## Contextual Guidance
- This project follows the Gemini CLI best practices for hierarchical context.
- Use `src/GEMINI.md` for implementation-specific rules.
