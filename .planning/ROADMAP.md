# Roadmap: lightrag-aws-deployment

**Project:** A fully operational, production-ready LightRAG deployment on AWS that a hiring engineer can understand, deploy, and demo end-to-end in under 30 minutes.
**Granularity:** coarse
**Created:** 2026-04-02

---

## Phases

- [ ] **Phase 1: IaC Foundation and EC2 Bootstrap** - Terraform provisions EC2, EIP, S3, IAM, SG. user_data bootstraps Docker, SSM secrets, S3 restore, and compose up with persistence scripts.
- [ ] **Phase 2: CI/CD Pipeline and Smoke Testing** - GitHub Actions deploy workflow on release tags with OIDC, SSH deploy, health check, and Playwright E2E smoke tests.
- [ ] **Phase 3: Documentation and Hardening** - README with architecture diagram, SSM setup commands, cost breakdown, demo curl script, and EIP billing warning.

---

## Phase Details

### Phase 1: IaC Foundation and EC2 Bootstrap

**Goal:** A running EC2 instance with LightRAG deployed and accessible on port 9621, with S3-based persistence configured and all AWS resources managed by Terraform.

**Depends on:** Nothing (first phase)

**Requirements:** IAC-01, IAC-02, IAC-03, IAC-04, IAC-05, IAC-06, IAC-07, IAC-08, BOOT-01, BOOT-02, BOOT-03, BOOT-04, BOOT-05, BOOT-06, BOOT-07, PERS-01, PERS-02, PERS-03

**Success Criteria** (what must be TRUE):

1. `terraform apply` succeeds with zero errors and outputs the Elastic IP address.
2. The EC2 instance boots, runs user_data, and LightRAG WebUI is accessible on port 9621 within 10 minutes.
3. `curl http://<elastic-ip>:9621/health` returns HTTP 200 with a healthy status.
4. `aws s3 ls s3://<graph-bucket>/` shows rag_storage/ content after a 15-minute cron cycle.
5. Docker container restarts gracefully after instance stop/start without data loss (S3 restore works).
6. API keys are loaded from SSM Parameter Store and present in /opt/lightrag/.env without being stored in Terraform state.
7. The S3 sync cron job and systemd shutdown unit both use flock locking to prevent race conditions.
8. Docker Compose runs with memory limit of 750m and a working health check.

**Plans:** 1 plan

Plans:
- [ ] 01-01-PLAN.md -- Terraform IaC (EC2, EIP, S3, IAM, SG) + user_data bootstrap (Docker, SSM, S3 restore, compose up) + persistence scripts (cron, systemd) + Docker Compose override + .env.example + .gitignore

---

### Phase 2: CI/CD Pipeline and Smoke Testing

**Goal:** Automated deployment pipeline that triggers on release tags, deploys via SSH to EC2, and validates the deployment with Playwright E2E smoke tests.

**Depends on:** Phase 1

**Requirements:** CICD-01, CICD-02, CICD-03, CICD-04, TEST-01, TEST-02, TEST-03, TEST-04, TEST-05

**Success Criteria** (what must be TRUE):

1. Creating a GitHub release tag (e.g., `v0.1.0`) triggers the deploy workflow automatically.
2. The workflow assumes the existing OIDC IAM role "mythicc123" and SSH deploys to the EC2 instance without storing long-lived AWS credentials.
3. `curl http://<elastic-ip>:9621/health` returns 200 after a deploy completes.
4. Playwright smoke tests run headlessly against the Elastic IP on port 9621 and ingest a document, poll status, query in hybrid mode, and assert an entity in the response.
5. Docker image is referenced by SHA digest, not `:latest`, ensuring reproducible deployments.

**Plans:** TBD

---

### Phase 3: Documentation and Hardening

**Goal:** A portfolio-ready README and hardened operational setup that enables a hiring engineer to understand and reproduce the entire deployment in under 30 minutes.

**Depends on:** Phase 2

**Requirements:** DOCS-01, DOCS-02, DOCS-03, DOCS-04, DOCS-05, DOCS-06

**Success Criteria** (what must be TRUE):

1. README contains an ASCII architecture diagram showing EC2, S3, SSM, IAM, and GitHub Actions components.
2. README documents exact `aws ssm put-parameter` commands for setting up ANTHROPIC_API_KEY, OPENAI_API_KEY, and LIGHTRAG_API_KEY in SSM Parameter Store.
3. README contains a cost breakdown table covering EC2, Elastic IP, S3, SSM, and API costs, with a warning that the Elastic IP incurs billing charges when the instance is stopped.
4. README includes a demo curl script that demonstrates the full workflow: ingest text, poll until complete, then query in hybrid mode.
5. .gitignore correctly excludes .env, rag_storage/, terraform/.terraform/, *.tfstate, and __pycache__/.
6. Project is immediately understandable and reproducible by a DevOps engineer with no additional context.

**Plans:** TBD

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. IaC Foundation and EC2 Bootstrap | 1/1 | Not started | - |
| 2. CI/CD Pipeline and Smoke Testing | 0/1 | Not started | - |
| 3. Documentation and Hardening | 0/1 | Not started | - |

---

## Coverage Map

| Requirement | Phase |
|-------------|-------|
| IAC-01 | Phase 1 |
| IAC-02 | Phase 1 |
| IAC-03 | Phase 1 |
| IAC-04 | Phase 1 |
| IAC-05 | Phase 1 |
| IAC-06 | Phase 1 |
| IAC-07 | Phase 1 |
| IAC-08 | Phase 1 |
| BOOT-01 | Phase 1 |
| BOOT-02 | Phase 1 |
| BOOT-03 | Phase 1 |
| BOOT-04 | Phase 1 |
| BOOT-05 | Phase 1 |
| BOOT-06 | Phase 1 |
| BOOT-07 | Phase 1 |
| PERS-01 | Phase 1 |
| PERS-02 | Phase 1 |
| PERS-03 | Phase 1 |
| CICD-01 | Phase 2 |
| CICD-02 | Phase 2 |
| CICD-03 | Phase 2 |
| CICD-04 | Phase 2 |
| TEST-01 | Phase 2 |
| TEST-02 | Phase 2 |
| TEST-03 | Phase 2 |
| TEST-04 | Phase 2 |
| TEST-05 | Phase 2 |
| DOCS-01 | Phase 3 |
| DOCS-02 | Phase 3 |
| DOCS-03 | Phase 3 |
| DOCS-04 | Phase 3 |
| DOCS-05 | Phase 3 |
| DOCS-06 | Phase 3 |

**Total:** 32/32 requirements mapped.
