# Requirements: lightrag-aws-deployment

**Defined:** 2026-04-02
**Core Value:** A fully operational, production-ready LightRAG deployment on AWS that a hiring engineer can understand, deploy, and demo end-to-end in under 30 minutes.

## v1 Requirements

### Infrastructure (IaC)

- [ ] **IAC-01**: Terraform provisions EC2 t3.micro (Ubuntu 24.04) in ap-southeast-2 with remote state backend pointing to existing bucket "mythicc-lightrag-tfstate"
- [ ] **IAC-02**: Terraform provisions and associates an Elastic IP with the EC2 instance
- [ ] **IAC-03**: Terraform creates an S3 bucket (separate from state bucket) for rag_storage graph persistence with lifecycle policy
- [ ] **IAC-04**: Terraform creates an IAM instance role with least-privilege S3 permissions (scoped to graph bucket only) and SSM Parameter Store read permissions (scoped to /lightrag/* path)
- [ ] **IAC-05**: Terraform creates a security group allowing: 22 (SSH, deploy), 443 (HTTPS future), 9621 (LightRAG WebUI, VPC-only or limited CIDR)
- [ ] **IAC-06**: Terraform uses data source to reference existing key pair "ec2-static-site-key" (do not create new)
- [ ] **IAC-07**: Terraform exposes instance_type as a variable with default "t3.micro" (overrideable to t3.small or t3.medium)
- [ ] **IAC-08**: EC2 instance has an IAM instance profile attached so the instance role is available to processes on the host

### Bootstrap (user_data)

- [ ] **BOOT-01**: user_data script creates a 2GB swap file and enables it on first boot
- [ ] **BOOT-02**: user_data script installs Docker Engine and Docker Compose v2 on Ubuntu
- [ ] **BOOT-03**: user_data script pulls the LightRAG GitHub repo to /opt/lightrag
- [ ] **BOOT-04**: user_data script downloads rag_storage/ from S3 (if bucket is non-empty) before starting the container
- [ ] **BOOT-05**: user_data script reads ANTHROPIC_API_KEY, OPENAI_API_KEY, LIGHTRAG_API_KEY from SSM Parameter Store and writes to /opt/lightrag/.env
- [ ] **BOOT-06**: user_data script runs docker compose up -d with memory limits (750m) and health check
- [ ] **BOOT-07**: user_data script is idempotent: skips re-cloning if /opt/lightrag already exists

### Persistence

- [ ] **PERS-01**: Cron job runs every 15 minutes executing an S3 sync script that uploads rag_storage/ to the graph S3 bucket using flock locking to prevent race conditions
- [ ] **PERS-02**: systemd shutdown unit triggers S3 sync before the instance stops or reboots, ensuring graph data is persisted
- [ ] **PERS-03**: On first boot (empty S3 bucket), Docker Compose starts cleanly with no errors and WebUI is accessible on port 9621

### CI/CD

- [ ] **CICD-01**: GitHub Actions workflow triggers on release tags (e.g., v*)
- [ ] **CICD-02**: GitHub Actions workflow assumes existing OIDC IAM role "mythicc123" (do not create new) and uses appleboy/ssh-action to deploy
- [ ] **CICD-03**: Deploy steps: git pull latest, docker compose pull, docker compose up -d, curl health check against /health endpoint
- [ ] **CICD-04**: Workflow uses Docker digest-pinned image (SHA, not :latest tag) for reproducibility

### Testing

- [ ] **TEST-01**: Playwright E2E smoke tests ingest a sample text document via POST /documents/insert
- [ ] **TEST-02**: Playwright polls /documents/status endpoint until ingestion completes
- [ ] **TEST-03**: Playwright queries in hybrid mode via POST /query with appropriate payload
- [ ] **TEST-04**: Playwright asserts entity/relation presence in the hybrid query response
- [ ] **TEST-05**: Playwright tests run against the Elastic IP on port 9621

### Documentation

- [ ] **DOCS-01**: README includes architecture diagram (ASCII) showing EC2, S3, SSM, IAM, GitHub Actions components
- [ ] **DOCS-02**: README documents SSM Parameter Store setup steps with exact aws ssm put-parameter commands
- [ ] **DOCS-03**: README includes cost breakdown table (EC2, EIP, S3, SSM, API costs)
- [ ] **DOCS-04**: README warns about Elastic IP billing when instance is stopped
- [ ] **DOCS-05**: README includes demo curl script: ingest text → poll → query
- [ ] **DOCS-06**: .gitignore excludes .env, rag_storage/, terraform/.terraform/, *.tfstate, __pycache__/

## v2 Requirements

*(None identified — all requirements are v1 scope)*

## Out of Scope

| Feature | Reason |
|---------|--------|
| HTTPS / ACM certificate / CloudFront | Adds complexity; Elastic IP direct access is sufficient for V1 demo |
| Auto Scaling Group or multi-instance | Single EC2 is intentional for cost; t3.micro is a portfolio demo, not production |
| Neo4j or PostgreSQL storage backends | Upstream storage (NanoVectorDB + NetworkX + JSON) with S3 sync is sufficient |
| Custom domain (Route53) | Elastic IP is direct; Route53 adds cost and complexity for V1 |
| Kubernetes deployment | Separate k8s-deploy/ path in upstream; this project is EC2-only |
| Langfuse tracing or RAGAS evaluation | Upstream feature; not needed for portfolio demo |
| Ansible | Overkill for single-service deployment; direct SSH + docker compose is simpler |
| blue-green deployment | Not needed for single-service; adds complexity without benefit at this scale |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| IAC-01 | Phase 1 | Pending |
| IAC-02 | Phase 1 | Pending |
| IAC-03 | Phase 1 | Pending |
| IAC-04 | Phase 1 | Pending |
| IAC-05 | Phase 1 | Pending |
| IAC-06 | Phase 1 | Pending |
| IAC-07 | Phase 1 | Pending |
| IAC-08 | Phase 1 | Pending |
| BOOT-01 | Phase 1 | Pending |
| BOOT-02 | Phase 1 | Pending |
| BOOT-03 | Phase 1 | Pending |
| BOOT-04 | Phase 1 | Pending |
| BOOT-05 | Phase 1 | Pending |
| BOOT-06 | Phase 1 | Pending |
| BOOT-07 | Phase 1 | Pending |
| PERS-01 | Phase 1 | Pending |
| PERS-02 | Phase 1 | Pending |
| PERS-03 | Phase 1 | Pending |
| CICD-01 | Phase 2 | Pending |
| CICD-02 | Phase 2 | Pending |
| CICD-03 | Phase 2 | Pending |
| CICD-04 | Phase 2 | Pending |
| TEST-01 | Phase 2 | Pending |
| TEST-02 | Phase 2 | Pending |
| TEST-03 | Phase 2 | Pending |
| TEST-04 | Phase 2 | Pending |
| TEST-05 | Phase 2 | Pending |
| DOCS-01 | Phase 3 | Pending |
| DOCS-02 | Phase 3 | Pending |
| DOCS-03 | Phase 3 | Pending |
| DOCS-04 | Phase 3 | Pending |
| DOCS-05 | Phase 3 | Pending |
| DOCS-06 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 32 total
- Mapped to phases: 32
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-02*
*Roadmap created: 2026-04-02 — 3 phases, 32/32 requirements mapped*
*Last updated: 2026-04-02 after roadmap creation*
