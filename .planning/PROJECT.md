# lightrag-aws-deployment

## What This Is

Deploy the HKUDS/LightRAG open-source RAG server to AWS EC2 as a production-ready, portfolio-grade infrastructure project. The upstream repo ships a complete FastAPI server, React WebUI, and Docker Compose setup — this project operationalises it on AWS with Terraform IaC, CI/CD via GitHub Actions, S3-based graph persistence, secrets via SSM Parameter Store, and end-to-end Playwright tests. Targets graduate DevOps/SRE engineering roles at Australian tech companies (CommBank, Macquarie, Optus).

## Core Value

A fully operational, production-ready LightRAG deployment on AWS that a hiring engineer can understand, deploy, and demo end-to-end in under 30 minutes.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Terraform provisions EC2 t3.micro, Elastic IP, S3 graph bucket, IAM instance role, and security group
- [ ] EC2 user_data script: 2GB swap setup, Docker install, S3 rag_storage restore, SSM secret load, docker compose up
- [ ] Cron job every 15 min uploads rag_storage/ to S3; systemd shutdown unit syncs before instance stop
- [ ] .env configured for Anthropic Claude (Sonnet queries, Haiku indexing) + OpenAI text-embedding-3-large embeddings
- [ ] GitHub Actions deploy workflow on release tag: SSH deploy, pull latest, restart compose, /health check
- [ ] Playwright E2E smoke tests: ingest text → poll until complete → hybrid query → assert entity in response
- [ ] README with architecture diagram (ASCII), SSM setup steps, cost breakdown, demo curl script

### Out of Scope

- HTTPS / ACM certificate / CloudFront — Elastic IP only for V1
- Auto Scaling Group or multi-instance — single EC2 is intentional for cost
- Neo4j or PostgreSQL storage backends — local file + S3 is sufficient
- Custom domain — use Elastic IP directly
- Kubernetes deployment — upstream k8s-deploy/ is out of scope
- Langfuse tracing or RAGAS evaluation — upstream feature, not needed for portfolio

## Context

- Fifth project in Mythicc123 DevOps portfolio (GitHub). Previous projects: ec2-static-site, blue-green-deployment, multi-container-service, eks-cluster-from-scratch.
- Existing AWS resources to reuse: OIDC provider + IAM role "mythicc123", key pair "ec2-static-site-key", state bucket "mythicc-lightrag-tfstate".
- Local SSH private key: ec2-static-site-key.pem
- AWS region: ap-southeast-2 (Sydney)
- Terraform remote state: bucket "mythicc-lightrag-tfstate", key "terraform.tfstate" — bucket already exists
- Upstream LightRAG repo: ghcr.io/hkuds/lightrag:latest — docker-compose.yml used as-is, no forking

## Constraints

- **Budget**: Cost must be minimal — t3.micro (~$7.50/month). Elastic IP costs ~$3.60/month if instance is stopped. README must warn about this.
- **No secrets in git**: All secrets via SSM Parameter Store (standard tier, free) or GitHub Secrets
- **Single EC2**: No ASG or multi-instance for V1
- **Tech stack locked**: Terraform HCL, AWS EC2, S3, IAM, SSM Parameter Store, Docker Compose, GitHub Actions, Playwright (Python)
- **API-hosted embeddings only**: OpenAI text-embedding-3-large via API (no Ollama/nomic-embed-text local)
- **LLM backend**: Anthropic Claude via ANTHROPIC_API_KEY from SSM

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| t3.micro with 2GB swap | $7.50/month target; 1GB RAM insufficient for LightRAG | — Pending |
| API-hosted embeddings (OpenAI) | Preserves t3.micro RAM headroom vs local Ollama | — Pending |
| S3 cron + systemd shutdown for persistence | Simple, zero-cost, reliable for demo corpus | — Pending |
| GitHub Actions OIDC (reuse mythicc123 role) | No long-lived credentials; aligns with existing portfolio | — Pending |
| SSM Parameter Store for secrets | Free, no secrets in git or terraform state | — Pending |
| No HTTPS for V1 | Reduces complexity; Elastic IP directly accessible | — Pending |
| Single EC2 (no ASG) | Cost-constrained portfolio demo | — Pending |

---

*Last updated: 2026-04-02 after initialization*

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state
