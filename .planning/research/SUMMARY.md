# Project Research Summary

**Project:** lightrag-aws-deployment
**Domain:** FastAPI RAG server (LightRAG) deployment on AWS EC2 t3.micro with Terraform IaC
**Researched:** 2026-04-02
**Confidence:** HIGH (upstream LightRAG docs verified; portfolio patterns from existing projects confirmed)

## Executive Summary

This project deploys LightRAG -- a hybrid vector+knowledge-graph RAG engine -- on a single AWS EC2 t3.micro using Docker Compose, Terraform IaC, and GitHub Actions CI/CD. The approach is intentionally simple: one container, one instance, one S3 bucket for off-instance persistence. Experts build this stack by keeping the application layer as a black box (upstream `ghcr.io/hkuds/lightrag:latest`), delegating all persistence to S3, and using SSM Parameter Store to eliminate secrets from Terraform state and git. The t3.micro constraint forces API-hosted embeddings (OpenAI) instead of local Ollama to preserve the 1 GiB RAM budget.

The recommended path is three phases: (1) Terraform IaC foundation with a fully-bootstrapped EC2 instance, (2) CI/CD + smoke testing pipeline, and (3) operational hardening (S3 persistence, CloudWatch, documentation). The highest risk is t3.micro memory exhaustion causing Docker OOM kills -- mitigated by Docker memory limits in the compose override from day one. The S3 sync race condition (cron + shutdown hook firing simultaneously) is mitigated with `flock`-based locking. The architecture is simple enough that well-documented patterns apply throughout; no deep research phases are needed.

## Key Findings

### Recommended Stack

**Infrastructure:** Terraform >= 1.10 with AWS provider ~> 5.0. Single EC2 instance on Ubuntu 22.04 LTS, provisioned via Terraform IaC with S3 remote state (reusing `mythicc-lightrag-tfstate` bucket). Security groups expose port 22 (SSH, restricted to GitHub IP ranges), port 443 (placeholder), and port 9621 (LightRAG API/WebUI). IAM instance role follows least privilege: `s3:GetObject/PutObject/ListBucket/DeleteObject` scoped to the graph storage bucket only, and `ssm:GetParameter` scoped to `/lightrag/*` only.

**Compute and Runtime:** Docker Engine + Docker Compose v2 (space-separated `docker compose` command) running the upstream LightRAG image. A 2 GB swap file compensates for t3.micro's 1 GiB RAM. The `ghcr.io/hkuds/lightrag:latest` image is used as-is; no forking or local image builds.

**Secrets:** AWS SSM Parameter Store (Standard tier, free) holds three SecureString values: `/lightrag/ANTHROPIC_API_KEY`, `/lightrag/OPENAI_API_KEY`, `/lightrag/LIGHTRAG_API_KEY`. These are fetched via `aws ssm get-parameter` in the user_data bootstrap script and written to `/opt/lightrag/.env`. No secrets in git, Terraform state, or GitHub Secrets (except the EC2 SSH key).

**Persistence:** `rag_storage/` directory lives on the EC2 root EBS volume, bind-mounted into the Docker container. S3 sync provides off-instance durability: cron job every 15 minutes plus a systemd `ExecStopPost` hook that runs before instance shutdown. A `flock`-based lock prevents race conditions between the two sync paths.

**CI/CD:** GitHub Actions deploy workflow triggers on release tag. Uses OIDC (reusing the existing `mythicc123` IAM role) for AWS API access and `appleboy/ssh-action` for SSH deploy to EC2. `appleboy/ssh-action` SSH private key is stored as a GitHub Secret. Concurrency is serialized with `cancel-in-progress: true`. Smoke tests run Playwright Python after the deploy step confirms `/health` returns 200.

**LLM and Embeddings:** API-hosted only. Queries use Claude Sonnet 3.7 via `ANTHROPIC_API_KEY`. Indexing uses Claude Haiku 3.5 for cost efficiency. Embeddings use `text-embedding-3-large` via `OPENAI_API_KEY`. No local Ollama. This is intentional -- Ollama consumes 400-800 MiB RAM, which is incompatible with t3.micro.

### Expected Features

**Must have (table stakes):**
- Terraform IaC provisioning all AWS resources (EC2, EIP, S3, IAM, SG) -- no manual console
- EC2 bootstrap via user_data: swap setup, Docker install, S3 rag_storage restore, SSM secret load, docker compose up
- API key authentication via `LIGHTRAG_API_KEY` (upstream built-in) -- loaded from SSM
- Health check endpoint at `/health` -- whitelisted (no auth required)
- Document ingestion via `POST /documents/text` and `POST /documents/upload`
- RAG query via `POST /query` (sync) and `POST /query/stream` (streaming)
- Knowledge graph API via `GET /graph/*`
- WebUI at `GET /webui/` (React-based Sigma.js graph visualization)
- Multi-mode query support (hybrid, local, global, naive, mix) -- upstream built-in
- CORS configuration for browser access from Elastic IP
- Swap file on t3.micro (2 GB) -- required for RAM extension
- Basic README with architecture diagram, SSM setup commands, cost breakdown, demo curl script

**Should have (competitive differentiators):**
- Systematic S3 persistence (cron 15-min + systemd shutdown hook) -- most tutorials skip this
- SSM Parameter Store for all secrets -- zero secrets in git/Terraform state
- GitHub Actions OIDC deploy (no long-lived credentials; reuses `mythicc123` role)
- Playwright E2E smoke tests: ingest -> poll track_id -> hybrid query -> assert entity
- Terraform remote state (S3 + DynamoDB locking)
- Least-privilege IAM scoping (graph bucket only, SSM path only)
- Instance type as Terraform variable (t3.micro default, upgrade path to t3.small)
- Cost breakdown in README -- transparent pricing with EIP warning
- Docker Compose override with memory limits (`deploy.resources.limits.memory: 750m`)
- Docker Compose health check (`healthcheck` in override)
- Model config validation at startup (detect embedding model changes)

**Defer to v1.x:**
- HTTPS via nginx reverse proxy + ACM certificate
- Custom domain via Route53 + ACM
- CloudWatch Logs and structured logging

**Defer to v2:**
- EKS deployment (Kubernetes pattern covered by `eks-cluster-from-scratch`)
- Multi-AZ ASG for high availability
- CloudFront CDN
- Managed storage backends (PostgreSQL/pgvector, Neo4j)
- Langfuse tracing and RAG quality evaluation
- Multi-user authentication with per-user JWT credentials

### Architecture Approach

The system is a single-container Docker Compose stack on one EC2 t3.micro. The LightRAG container runs the FastAPI server (port 9621), which serves both the REST API and the React WebUI. Storage is entirely file-based: NanoVectorDB (chunks, entities, relationships), NetworkX graph (pickle), and JsonKVStorage (documents, chunks, cache) all live in `rag_storage/`, which is bind-mounted from the host. The LightRAG container is a black box -- no AWS-specific code is patched into the upstream image. All AWS integration happens in the host-level user_data bootstrap, systemd units, cron jobs, and IAM role policies.

The strict build order is: (1) Terraform provisions infrastructure, (2) SSM parameters set manually post-apply, (3) EC2 user_data runs on first boot (swap, Docker, git clone, SSM load, S3 restore, compose up), (4) GitHub Actions deploy workflow on release tag (SSH deploy, health check, smoke test). The S3 persistence mechanism must be built in Phase 1 alongside user_data -- not deferred to v1.x, because losing the knowledge graph on instance termination destroys the demo narrative.

### Critical Pitfalls

1. **t3.micro Memory Exhaustion (OOM Kills)** -- Without Docker memory limits, the container consumes unlimited RAM and the Linux OOM killer SIGKILLs it. The container enters a restart loop. Fix: `deploy.resources.limits.memory: "750m"` in docker-compose override, `--workers 1` for Gunicorn, and `MAX_ASYNC=1` in `.env`.

2. **S3 Sync Race Condition** -- The cron job (every 15 min) and systemd shutdown hook can fire simultaneously on instance stop. Both run `aws s3 sync` without locking; the last to complete wins, potentially overwriting a good state with a partial sync. Fix: use `flock -n /var/lock/lightrag-s3-sync.lock` in both the cron wrapper and the systemd ExecStop script.

3. **user_data Non-Idempotency** -- Re-running bootstrap actions on instance restart can pull breaking upstream changes, restart healthy containers mid-operation, or re-run S3 sync redundantly. Fix: guard the bootstrap with a flag file (`/var/lib/lightrag/.bootstrapped`) so full bootstrap only runs once.

4. **SSM Parameter Not Available at Docker Startup** -- If `aws ssm get-parameter` fails silently (IAM role not yet propagated, network timeout), the `.env` file is empty or missing. Docker starts the container with no API keys; all LLM calls return 401. Fix: validate env vars exist before `docker compose up`, retry SSM up to 3 times with backoff.

5. **Missing Docker Health Check Enables False Positives** -- The upstream `docker-compose.yml` has no health check defined. Docker reports "healthy" as soon as the uvicorn process starts, not when the app is ready. CI/CD and startup scripts pass prematurely. Fix: add app-level health check in the compose override (`curl http://localhost:9621/health`), `start_period: 60s`, `retries: 3`.

6. **IAM Role Too Broad (Least Privilege Violation)** -- A catch-all `s3:*` on `*` grants the EC2 instance access to the entire account's S3 data. Fix: scope IAM policy to the graph storage bucket ARN only, and SSM to `/lightrag/*` path only.

## Implications for Roadmap

Based on research, the recommended phase structure follows the strict dependency chain in the architecture.

### Phase 1: IaC Foundation and EC2 Bootstrap
**Rationale:** All other work depends on a running EC2 instance. The user_data script is the most complex single deliverable -- it touches Docker, IAM, SSM, S3, and systemd. Getting this right from the start prevents cascading failures in later phases.

**Delivers:**
- Terraform: EC2 instance, Elastic IP, S3 graph bucket, IAM instance role (least-privilege scoped), security group, remote S3 backend
- user_data bootstrap script: swap, Docker, git clone, S3 restore, SSM secret load with validation, docker compose up
- docker-compose override: memory limits (750m), app-level health check, stop_grace_period: 30s
- Terraform outputs: public IP, SSH command, S3 bucket name
- SSM Parameter Store setup (documented manual step for README)

**Implements:** Pitfalls 1, 2, 3, 4, 5, 6, 10, 14, 15 (memory limits, flock locking, idempotent bootstrap, SSM validation, health check, least-privilege IAM, image digest pinning, graceful shutdown, provider version). Phase 1 is where most of the critical pitfalls are mitigated.

**Uses:** STACK.md technologies (Terraform, SSM, S3, Docker Compose v2, Ubuntu 22.04).

### Phase 2: CI/CD Pipeline and Smoke Testing
**Rationale:** Once EC2 is bootstrapped, automating the deploy validate loop is the next highest-value improvement. Playwright smoke tests provide a safety net that enables confident iteration.

**Delivers:**
- GitHub Actions deploy workflow: OIDC assume role, terraform apply, SSH deploy, health check polling
- GitHub Actions CI workflow: terraform validate, plan on PR
- Playwright E2E smoke test: ingest text, poll track_id, hybrid query, assert entity
- Concurrency control (`cancel-in-progress: true`)
- Docker image digest pinning or local tagging

**Implements:** Pitfalls 11 (concurrency control), 5 (health check polling in CI), 10 (image pinning).

**Uses:** STACK.md CI/CD technologies (appleboy/ssh-action v1.2.5, aws-actions/configure-aws-credentials v4, hashicorp/setup-terraform v3, OIDC reuse of mythicc123 role).

**Research flag:** Phase 2 has well-documented patterns from blue-green-deployment and multi-container-service. Skip deep research-phase.

### Phase 3: Operational Hardening and Documentation
**Rationale:** Core pipeline is now automated and tested. Phase 3 adds the operational quality and portfolio-visible documentation that differentiates a production-grade project from a working demo.

**Delivers:**
- S3 persistence: cron job (15-min sync), systemd shutdown unit with flock locking, startup restore
- CloudWatch Logs integration (container stdout/stderr streamed to CloudWatch)
- README: ASCII architecture diagram, SSM setup commands, cost breakdown table, demo curl script, EIP billing warning
- Model config hash validation at startup (detect embedding model mismatches)
- Terraform state lock table (DynamoDB) in backend config

**Implements:** Pitfalls 2 (flock in cron and shutdown), 7 (model config validation), 9 (EIP billing warning in README), 14 (graceful shutdown in systemd unit).

**Research flag:** S3 persistence details and CloudWatch integration are well-understood. No deep research needed.

### Phase Ordering Rationale

The phases follow the architecture's strict dependency chain:
- Phase 1 must come first because all other work requires a bootstrapped EC2 instance
- Phase 2 must follow Phase 1 because CI/CD deploys to the infrastructure built in Phase 1
- Phase 3 is last because it adds operational polish on top of a working pipeline
- S3 persistence is placed in Phase 3 (not deferred to v1.x) because losing the knowledge graph destroys the demo narrative -- it is not optional even though it is "operational"
- Playwright tests are in Phase 2 because they provide the safety net for Phase 3 operational changes

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified: upstream LightRAG docs (docker-compose.yml, env.example), existing portfolio projects (ec2-static-site, multi-container-service, blue-green-deployment) |
| Features | HIGH | Verified: LightRAG API docs, project-spec.md, .planning/PROJECT.md |
| Architecture | HIGH | Verified: LightRAG storage layer (lightrag.py), Docker Compose patterns, S3 sync architecture, GitHub Actions flow |
| Pitfalls | MEDIUM-HIGH | Mostly first-principles reasoning with portfolio pattern cross-reference. Several gaps require validation during Phase 1 (see below) |

**Overall confidence:** HIGH -- well-supported by upstream docs and existing portfolio patterns. Medium-HIGH on pitfalls reflects first-principles reasoning for some scenarios (t3.micro memory math, S3 sync race) that should be validated during Phase 1.

### Gaps to Address

- **t3.micro memory consumption under indexing load:** First-principles estimate (~750 MiB container overhead, ~400-800 MiB FastAPI/embedding peak) needs validation. Test with `docker run --memory=750m` locally before finalizing compose override.
- **GHCR rate limits for unauthenticated pulls:** No confirmed docs available. Use image digest pinning or local tagging as the safe fallback.
- **Docker Compose `--wait` flag on Ubuntu 24.04 Docker package:** Verify availability; fallback to explicit `sleep 10` + curl health check.
- **`flock` availability on Ubuntu 24.04 base AMI:** Verify `util-linux` package is in the base AMI; fallback to `lockfile` or `set -C` (noclobber) if missing.
- **SSM Session Manager agent on Ubuntu 24.04:** Needed to eliminate port 22 entirely. Verify `amazon-ssm-agent` installation requirements.
- **Ubuntu 24.04 LTS AMI ID for ap-southeast-2:** Must be verified at apply time (use `data "aws_ami" "ubuntu"` or look up current AMI).

## Sources

### Primary (HIGH confidence)
- HKUDS/LightRAG GitHub repository (docker-compose.yml, env.example, API README, lightrag.py storage layer) -- https://github.com/HKUDS/LightRAG -- CONFIDENCE: HIGH
- project-spec.md, .planning/PROJECT.md -- V1 scope, constraints, cost reference -- CONFIDENCE: HIGH
- ec2-static-site Terraform + user_data pattern -- existing portfolio project -- CONFIDENCE: HIGH
- multi-container-service Terraform + Docker Compose pattern -- existing portfolio project -- CONFIDENCE: HIGH
- blue-green-deployment GitHub Actions workflow (appleboy/ssh-action, concurrency control) -- existing portfolio project -- CONFIDENCE: HIGH

### Secondary (MEDIUM confidence)
- t3.micro memory math (OOM killer behavior, Docker container memory overhead, FastAPI process RAM) -- first-principles reasoning, needs validation -- CONFIDENCE: MEDIUM
- S3 sync race condition analysis (cron + systemd simultaneous execution) -- first-principles reasoning, needs load test validation -- CONFIDENCE: MEDIUM
- SSM parameter availability window (IAM role propagation delay) -- first-principles reasoning -- CONFIDENCE: MEDIUM
- GHCR unauthenticated pull rate limits -- not confirmed with docs -- CONFIDENCE: MEDIUM

### Tertiary (LOW confidence)
- Exact memory consumption of LightRAG container under corpus indexing load -- varies by corpus size -- CONFIDENCE: LOW
- Ubuntu 24.04 LTS AMI ID for ap-southeast-2 -- must be verified at apply time -- CONFIDENCE: LOW
- `amazon-ssm-agent` availability on Ubuntu 24.04 -- needs verification -- CONFIDENCE: LOW

---
*Research completed: 2026-04-02*
*Ready for roadmap: yes*
