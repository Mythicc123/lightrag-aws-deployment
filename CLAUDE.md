<!-- GSD:project-start source:PROJECT.md -->
## Project

**lightrag-aws-deployment**

Deploy the HKUDS/LightRAG open-source RAG server to AWS EC2 as a production-ready, portfolio-grade infrastructure project. The upstream repo ships a complete FastAPI server, React WebUI, and Docker Compose setup — this project operationalises it on AWS with Terraform IaC, CI/CD via GitHub Actions, S3-based graph persistence, secrets via SSM Parameter Store, and end-to-end Playwright tests. Targets graduate DevOps/SRE engineering roles at Australian tech companies (CommBank, Macquarie, Optus).

**Core Value:** A fully operational, production-ready LightRAG deployment on AWS that a hiring engineer can understand, deploy, and demo end-to-end in under 30 minutes.

### Constraints

- **Budget**: Cost must be minimal — t3.micro (~$7.50/month). Elastic IP costs ~$3.60/month if instance is stopped. README must warn about this.
- **No secrets in git**: All secrets via SSM Parameter Store (standard tier, free) or GitHub Secrets
- **Single EC2**: No ASG or multi-instance for V1
- **Tech stack locked**: Terraform HCL, AWS EC2, S3, IAM, SSM Parameter Store, Docker Compose, GitHub Actions, Playwright (Python)
- **API-hosted embeddings only**: OpenAI text-embedding-3-large via API (no Ollama/nomic-embed-text local)
- **LLM backend**: Anthropic Claude via ANTHROPIC_API_KEY from SSM
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Infrastructure as Code (Terraform)
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| Terraform CLI | >= 1.10 | IaC runtime | Per existing portfolio conventions. multi-container-service uses 1.7.0 as floor. `hashicorp/setup-terraform@v3` in CI |
| AWS provider | ~> 5.0 | AWS API resources | Matches multi-container-service (existing portfolio). Note: terraform-aws-vpc v6.0 requires AWS provider ~6.0 -- since this project does not use terraform-aws-vpc (single EC2, default VPC via `data "aws_vpc" "default"`), ~5.0 is safe |
| Terraform S3 backend | N/A | Remote state | Reuse existing `mythicc-lightrag-tfstate` bucket. Key: `terraform.tfstate`. Region: `ap-southeast-2`. DynamoDB table not required (single-user, acceptable risk at portfolio scale) |
### Compute (EC2)
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| Ubuntu Server | 22.04 LTS (Jammy) | OS for EC2 | Default for existing portfolio projects. Ubuntu 24.04 LTS is available but 22.04 has broader community support and package availability |
| Docker | latest via apt | Container runtime | Installed via `apt-get install docker.io` in user_data (from multi-container-service pattern) |
| Docker Compose | v2 (standalone) | Container orchestration | Use `docker compose` (space, not hyphen). The upstream LightRAG `docker-compose.yml` uses Compose Specification format (no `version` key). `docker compose up -d` is the canonical command |
| Swap file | 2GB | RAM extension for t3.micro | Required per project spec. Created in user_data via `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |
### Secrets Management
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| AWS SSM Parameter Store | Standard tier | API keys and secrets at runtime | Locked by project spec. Free at standard tier. Values injected into .env via `aws ssm get-parameter --with-decryption` at instance boot. No secrets in Terraform state |
| IAM instance role | N/A | EC2 runtime access to SSM and S3 | Scoped permissions: `ssm:GetParameter` for `/lightrag/*`, `s3:GetObject` and `s3:PutObject` for graph storage bucket only |
- `/lightrag/ANTHROPIC_API_KEY` -- SecureString
- `/lightrag/OPENAI_API_KEY` -- SecureString
- `/lightrag/LIGHTRAG_API_KEY` -- SecureString
### Storage
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| S3 bucket | N/A | rag_storage/ persistence across instance lifecycle | Separate from TF state bucket. Locked by project spec. Two sync strategies: cron job (every 15 min, `aws s3 sync`) + systemd shutdown hook (`ExecStopPre` on a `docker-rag-sync.service` unit) |
| Local Docker volume | N/A | rag_storage/ and inputs/ directories | Mounted as `./data/rag_storage` and `./data/inputs` from the cloned LightRAG repo on the EC2 instance. The data dir lives on the root EBS volume |
- **Startup restore:** `aws s3 sync s3://<graph-bucket>/rag_storage/ /opt/lightrag/data/rag_storage/`
- **Periodic backup:** `*/15 * * * * aws s3 sync /opt/lightrag/data/rag_storage/ s3://<graph-bucket>/rag_storage/`
- **Shutdown sync:** systemd unit with `ExecStopPre=/usr/local/bin/sync-rag-storage.sh`
### CI/CD (GitHub Actions)
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| `actions/checkout` | v4 | Clone repo in CI | Standard, locked by existing portfolio patterns |
| `appleboy/ssh-action` | v1.2.5 | Remote SSH deploy to EC2 | Proven pattern from blue-green-deployment. Handles SSH key injection, script execution, and timeout. Preferred over `aws-actions/configure-aws-credentials` + raw SSH commands |
| `docker/login-action` | v3 | Docker Hub auth (if pushing custom image) | Not needed for LightRAG v1 -- uses upstream `ghcr.io/hkuds/lightrag:latest` image directly |
| `aws-actions/configure-aws-credentials` | v4 | OIDC-based AWS auth | Use for terraform plan/apply in CI. Reference existing `mythicc123` IAM role ARN per project spec |
| `hashicorp/setup-terraform` | v3 | Terraform in CI | Version locked to 1.7.0 per existing project convention |
### Testing
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|----------------|
| Playwright (Python) | latest via pip | E2E smoke tests | Locked by project spec. Python matches the existing portfolio tooling preference (vs Node.js Playwright) |
| `playwright` Python package | latest | Browser automation for smoke tests | `pip install playwright && playwright install chromium` in CI or local |
| Python | 3.11 | Test runtime | Matches multi-container-service CI pattern |
### Networking
| Technology | Purpose | Why Recommended |
|------------|---------|----------------|
| AWS Security Group | Firewall rules | Per project spec: 443 public, 9621 VPC-only, 22 deploy. 9621 is the LightRAG API/WebUI port |
| Elastic IP | Static public IP | Locked by project spec. Single EIP attached to EC2. Free while instance runs, ~$3.60/mo when stopped |
| Route53 | DNS (out of scope for V1) | Not in V1 scope. Use EIP directly for demo |
### Container Configuration
### LLM and Embedding Configuration
| Component | Provider | Config Key | Notes |
|-----------|----------|-----------|-------|
| LLM (queries) | Anthropic Claude Sonnet | `ANTHROPIC_API_KEY` | Per project spec |
| LLM (indexing) | Anthropic Claude Haiku | `ANTHROPIC_API_KEY` | Use `MODEL_LIST` env var to set per-task model |
| Embeddings | OpenAI text-embedding-3-large | `OPENAI_API_KEY` | API-hosted, preserves t3.micro RAM (vs local Ollama) |
| Auth | Built-in | `LIGHTRAG_API_KEY` | Per project spec |
## Installation
### Terraform (IaC)
# terraform/ directory
### EC2 user_data bootstrap (embedded in Terraform)
#!/bin/bash
# 1. System packages
# 2. Enable Docker
# 3. Create swap file (t3.micro has 1GB RAM)
# 4. Clone LightRAG repo
# 5. Restore rag_storage from S3 (if exists)
# 6. Load secrets from SSM into .env
# 7. Write .env
# 8. Start containers
### Systemd shutdown hook (S3 sync)
# /etc/systemd/system/docker-rag-sync.service
# /usr/local/bin/sync-rag-storage.sh
#!/bin/bash
### GitHub Actions (CI)
# .github/workflows/ci.yml
### GitHub Actions (Deploy)
# .github/workflows/deploy.yml
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| SSM Parameter Store | AWS Secrets Manager | Secrets Manager when you need secret rotation via Lambda, or when storing > 10,000 parameters. SSM Standard is free and sufficient for 3 API keys |
| OIDC (mythicc123 role) | GitHub Secrets with AWS access keys | OIDC avoids long-lived credentials. Reuse the existing `mythicc123` role ARN -- do not create new |
| `appleboy/ssh-action` | `aws-actions/configure-aws-credentials` + raw SSH | `ssh-action` is simpler for one-off SSH commands. Use raw SSH + AWS CLI when you need AWS API calls from the remote host (e.g., SSM Session Manager) |
| `ghcr.io/hkuds/lightrag:latest` | Self-built Docker image | Only if you need custom LightRAG patches or a specific embedding model that requires image customization. For portfolio, upstream image is correct |
| S3 sync cron + systemd | AWS DataSync | DataSync for TB-scale recurring syncs between EC2 and S3. Overkill for a t3.micro demo with a small rag_storage/ directory |
| `docker compose up -d --wait` | Polling loop after `docker compose up -d` | `--wait` waits for containers to start (not health checks). For LightRAG, add a 10-15s delay + explicit curl health check before declaring success |
| Local rag_storage + S3 backup | Neo4j or PostgreSQL backend | Out of scope for V1 per project spec. Local JSON + S3 is sufficient and simpler |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Terraform AWS provider ~> 4.0 | Deprecated. terraform-aws-vpc v6.0 requires ~> 6.0. Multi-container-service already uses ~> 5.0 | ~> 5.0 (matches existing portfolio) |
| Docker Compose v1 (`docker-compose`, hyphenated) | Deprecated. Removed from most distributions. LightRAG upstream uses Compose Specification (no version key) | Docker Compose v2 (`docker compose`, space) |
| `docker-compose up` without `-d` | No detached mode. CI runner would block | `docker compose up -d` |
| `docker-compose up -d` without health wait | Container may still be initializing. CI health check would fail | Add `--wait` or explicit `sleep 10` before health check |
| Local Ollama / nomic-embed-text embeddings | Consumes RAM on t3.micro. The spec explicitly avoids this | OpenAI text-embedding-3-large (API-hosted, zero RAM cost) |
| EBS volume for rag_storage | Adds cost and complexity. S3 sync + local storage is sufficient | Local root EBS + S3 backup |
| Kubernetes / EKS | Single EC2 is intentional per project spec for cost and simplicity | Docker Compose on EC2 |
| Ansible (from multi-container-service) | Overkill for LightRAG v1. Single service deployment with `docker compose up` is simpler than Ansible playbook | Direct SSH + `docker compose` commands in CI |
| Blue-green deployment | Complexity not justified for single-service portfolio demo. Simple rolling restart is sufficient | Single deployment slot, `docker compose up -d --wait` |
| Local Terraform state | Not tracked by version control. Multi-container-service uses S3 backend. Lock to existing `mythicc-lightrag-tfstate` bucket | S3 backend |
## Stack Patterns by Variant
- Use Elastic IP directly (output from Terraform)
- No Route53, no ACM certificate, no CloudFront
- HTTP on port 9621
- README documents the EIP URL
- Use cert-manager inside Docker Compose or an Nginx reverse proxy on the host
- Or: CloudFront with ACM certificate (adds ~$0.01/GB cost)
- Recommended path: Nginx on host (port 443) proxying to Docker port 9621
- Add a swap file (already planned)
- Offload embeddings to API-hosted model (already planned)
- If LLM inference becomes the bottleneck: switch Haiku/Sonnet to API-only, do not run local LLM
- If memory pressure persists: upgrade instance type (t3.small, t3.medium) -- exposed as Terraform variable per project spec
- Single EC2 is intentional for cost per project spec
- For multi-instance: would need a load balancer (AWS LB Controller or Nginx upstream), a task queue for ingestion (Celery + Redis), and shared storage (EFS instead of local S3 sync)
- Do not attempt without first migrating from local file storage to a shared database backend (PostgreSQL, Neo4j)
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Terraform >= 1.10 | AWS provider ~> 5.0, S3 backend | `terraform init` downloads providers. S3 backend requires bucket in ap-southeast-2 |
| Docker Compose v2 | Ubuntu 22.04, Docker 24+ | `docker compose` (space, no hyphen) is the only supported form |
| `appleboy/ssh-action` v1.2.5 | ubuntu-latest runner | Timeout in minutes. LightRAG docker compose up may need 5-10 min first boot |
| GitHub Actions OIDC | AWS IAM `mythicc123` role | Role ARN must be output from existing infrastructure. Do not recreate |
| `hashicorp/setup-terraform` v3 | Terraform 1.7.0+ | Installs Terraform on the runner. Use `terraform_version` input |
| Playwright (Python) | Python 3.11, Chromium | `pip install playwright && playwright install chromium` |
| `ghcr.io/hkuds/lightrag:latest` | Docker 24+, 2GB+ RAM | No health check in upstream image. Add in `docker-compose.override.yml` |
| AWS SSM Parameter Store | awscli on EC2 | Requires IAM instance role with `ssm:GetParameter` for `/lightrag/*` |
| S3 sync | awscli on EC2 | Requires IAM instance role with `s3:GetObject` and `s3:PutObject` for graph bucket |
## Sources
- Upstream LightRAG docker-compose.yml -- `ghcr.io/hkuds/lightrag:latest` with Compose Specification format -- CONFIDENCE: HIGH (official HKUDS repo)
- Upstream LightRAG env.example -- all configuration options for LLM, embedding, storage, and server settings -- CONFIDENCE: HIGH (official repo)
- multi-container-service Terraform layout -- `backend.tf`, `main.tf`, `variables.tf`, `outputs.tf` pattern -- CONFIDENCE: HIGH (existing portfolio project, verified)
- blue-green-deployment GitHub Actions workflow -- `appleboy/ssh-action` deployment pattern with lock file and health check -- CONFIDENCE: HIGH (existing portfolio project, verified)
- ec2-static-site Terraform + user_data pattern -- `aws_instance` with `user_data` bootstrap script -- CONFIDENCE: HIGH (existing portfolio project, verified)
- multi-container-service CI workflow -- `hashicorp/setup-terraform@v3` with Terraform 1.7.0 -- CONFIDENCE: HIGH (existing portfolio project, verified)
- AWS SSM Parameter Store pricing -- Standard tier is free for <= 10,000 parameters -- CONFIDENCE: HIGH (aws.amazon.com pricing)
- Docker Compose v2 -- `docker compose` (space-separated) is the standard command -- CONFIDENCE: HIGH (docs.docker.com/compose)
- appleboy/ssh-action -- GitHub Actions marketplace, v1.2.5 used in blue-green-deployment -- CONFIDENCE: HIGH (verified in existing workflow)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
