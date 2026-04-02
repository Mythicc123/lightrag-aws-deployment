# Feature Research

**Domain:** RAG (Retrieval-Augmented Generation) server deployment on AWS EC2
**Researched:** 2026-04-02
**Confidence:** HIGH

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist for any production RAG deployment. Missing these = broken or incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| FastAPI server running on a public endpoint | LightRAG ships a FastAPI server; users expect it accessible at `http://<host>:9621` | LOW | Upstream provides this; deployment is the ops concern |
| Document ingestion via API | `POST /documents/text`, `POST /documents/upload`, `POST /documents/texts` endpoints are core to LightRAG | LOW | Upstream provides endpoints; ops must ensure they are reachable |
| RAG query endpoint | `POST /query` (sync) and `POST /query/stream` (streaming) are the primary user-facing endpoints | LOW | Upstream provides; must be accessible with API key auth |
| Knowledge graph API | `GET /graphs`, `GET /graph/entity/exists`, graph entity/relation CRUD are part of the WebUI experience | LOW | Upstream provides; WebUI visualises this |
| API key authentication | `LIGHTRAG_API_KEY` env var gates all non-whitelisted endpoints; `X-API-Key` header required | LOW | Upstream built-in; must be loaded from SSM Parameter Store |
| Health check endpoint | `/health` is whitelisted (no auth); GitHub Actions and operators need this for readiness checks | LOW | Upstream built-in; critical for CI/CD health checks |
| Secrets management (no hardcoding) | API keys must not appear in git, Terraform state, or code. SSM Parameter Store is the standard approach | MEDIUM | Project-spec requires this; SSM GetParameter in user_data with IAM policy |
| Graph persistence across restarts | `rag_storage/` contains the vector index, KG, and KV store. Must survive instance reboot | MEDIUM | Project-spec requires S3 sync (cron + systemd shutdown hook); most simple deployments neglect this |
| Infrastructure as Code | Terraform provisions all AWS resources; no manual console clicks | MEDIUM | Portfolio differentiator; terraform-aws-modules conventions align with existing Mythicc123 projects |
| CI/CD deploy pipeline | Release tag triggers SSH deploy, docker compose pull/restart, health check | MEDIUM | GitHub Actions OIDC (reuse mythicc123 role); prevents manual deploys |
| E2E smoke tests | Automated test: ingest text, poll for completion, query, assert entity in response | MEDIUM | Playwright Python; validates the full ingestion-to-query pipeline |
| Basic documentation | README with architecture diagram, setup steps, SSM parameter commands, cost breakdown | LOW | Portfolio audience (recruiters, hiring engineers) need to understand the architecture quickly |
| Swap file on t3.micro | LightRAG indexing requires memory; t3.micro has only 1GB RAM | LOW | 2GB swap file in user_data; compensating for constrained instance |
| CORS configuration | WebUI on browser must call API on same or whitelisted origin | LOW | `CORS_ORIGINS` env var; need to allow browser access from Elastic IP |

### Differentiators (Competitive Advantage)

Features that set a portfolio project apart. Not required for a working RAG server, but valuable for demonstrating production-grade thinking.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Systematic S3 persistence (cron + shutdown hook) | rag_storage survives instance stop/terminate; demo corpus is never lost. Most "deploy to EC2" tutorials skip this | MEDIUM | 15-min cron uploads rag_storage to S3; systemd unit syncs on shutdown. Covers both planned stops and accidental terminations |
| SSM Parameter Store for all secrets | Zero secrets in git or Terraform state. Demonstrates separation of secrets from infrastructure code | MEDIUM | Three SSM params: ANTHROPIC_API_KEY, OPENAI_API_KEY, LIGHTRAG_API_KEY. Instance role scoped to `/lightrag/*` path only |
| GitHub Actions OIDC deploy | No long-lived AWS credentials; uses existing mythicc123 role. Demonstrates modern CI/CD security patterns | MEDIUM | Release tag trigger; SSH deploy via private key stored in GitHub Secrets; health check validation |
| Multi-mode query support | Demonstrates LightRAG's hybrid retrieval (local + global + naive + mix modes) | LOW | Playwright tests exercise hybrid mode; WebUI exposes mode selector |
| Knowledge graph visualisation (WebUI) | Sigma.js graph in the React WebUI; demonstrates graph-based RAG vs naive vector search | LOW | Upstream provides; accessible at port 9621 |
| API-hosted embeddings (OpenAI text-embedding-3-large) | Preserves t3.micro RAM; zero embedding model footprint on the instance. Demonstrates cost-awareness | LOW | OpenAI API called at query/indexing time; avoids local Ollama/nomic-embed-text RAM cost |
| Claude Haiku for indexing, Sonnet for queries | Cost segmentation: cheap Haiku for LLM-heavy indexing, capable Sonnet for quality answers | LOW | Two model tiers via ANTHROPIC_API_KEY; configured in .env |
| Streaming query responses | `POST /query/stream` returns NDJSON chunks; better UX for long responses | LOW | Upstream provides; testable via curl or WebUI |
| Terraform remote state (S3 + DynamoDB) | State stored in existing mythicc-lightrag-tfstate bucket; demonstrates multi-environment state management | LOW | Follows existing portfolio project conventions |
| Resource scoping (least-privilege IAM) | Instance role has S3 read/write scoped to graph bucket only; SSM read scoped to /lightrag/* only | MEDIUM | Demonstrates security best practice beyond "AdministratorAccess" |
| Instance type as Terraform variable | `instance_type = t3.micro` exposed as variable; can override to t3.small/medium without code changes | LOW | Demonstrates infrastructure flexibility; future-proofs for cost/performance tuning |
| Cost breakdown in README | Transparent cost reference table; Elastic IP warning for stopped instances | LOW | Supports portfolio narrative: "I know what this costs to run" |
| Demo curl script | One-liner that exercises the full pipeline; hiring engineer can verify the demo in seconds | LOW | `curl` ingest, `curl` query, assert response; in README |
| WebUI accessible on port 9621 | Browser-accessible React interface for knowledge graph exploration and query | LOW | Upstream provides; demonstrates full-stack RAG product |
| SSL/TLS configuration support | Upstream supports `SSL_CERTFILE` + `SSL_KEYFILE` env vars for HTTPS | LOW | Available for v1.x when HTTPS is added |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems for this specific project.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Kubernetes / EKS deployment | "Production = Kubernetes"; perceived as more professional | EKS adds IAM, node groups, RBAC, Helm charts, networking complexity; t3.micro cannot run a meaningful k8s cluster anyway. The eks-cluster-from-scratch project already covers this | Docker Compose on EC2 is the correct abstraction for this project. LightRAG's k8s-deploy/ directory is out of scope by design |
| HTTPS / ACM certificate / CloudFront (in v1) | "Production needs HTTPS" | Adds CloudFront distribution, ACM certificate, DNS/R53 integration, and a reverse proxy layer. Creates significant complexity for a demo-scale project with an Elastic IP. Blocks getting a working demo live quickly | Defer to v1.x: add nginx + ACM cert behind a custom domain after basic deploy works |
| Auto Scaling Group / multi-instance | "Single instance is not production" | ASG adds launch templates, health checks, scaling policies, and cost. A portfolio project on t3.micro ASG would cost 3x more and add no meaningful demonstration value | Single EC2 is intentional per project-spec. Upgrade to t3.small if memory/CPU pressure appears |
| Neo4j or PostgreSQL storage backend | "Use a real database instead of local files" | Requires a managed database (RDS) or self-hosted DB container; adds cost (~$15-30/month for RDS vs free local files), connection management, and migrations. Local files + S3 is sufficient for demo corpus | Stick to `LIGHTRAG_KV_STORAGE=JsonKVStorage`, `LIGHTRAG_GRAPH_STORAGE=NetworkXStorage`, `LIGHTRAG_VECTOR_STORAGE=NanoVectorDBStorage` |
| Custom domain (in v1) | "Use a real domain instead of IP" | Requires Route53 hosted zone, ACM certificate, DNS TTL management, and CNAME/A-record updates. Adds friction for a demo project that needs to be live quickly | Elastic IP directly; custom domain in v1.x |
| Langfuse tracing / RAGAS evaluation | "Need observability for RAG quality" | Adds Langfuse deployment (self-hosted or cloud), RAGAS pipeline, and evaluation corpus. This is an upstream feature useful for RAG development, not for demonstrating infrastructure deployment | Out of scope per project-spec. LightRAG's built-in `/query/data` endpoint provides raw retrieval data for manual evaluation |
| Local Ollama / nomic-embed-text embedding | "Avoid API dependency for embeddings" | Ollama + embedding model requires ~4-8GB RAM. On t3.micro (1GB base + 2GB swap), this would cause OOM kills or extreme slowdown. API-hosted embeddings preserve RAM for the Python RAG process | OpenAI text-embedding-3-large via API; $0.13/1M tokens is negligible for demo |
| GPU instance (for vLLM reranker) | "Use GPU for better performance" | GPU instances (g4dn, p3) cost $0.526+/hour vs t3.micro's ~$0.0104/hour. Reranking via OpenAI API is fast enough for demo; GPU is not justifiable at portfolio scale | API-hosted reranking via OpenAI; vLLM reranker in docker-compose-full is out of scope |
| Real-time S3 sync (inotify/FUSE) | "15-minute cron is not real-time" | Adds complexity (S3fs, inotify-wait, watchdog), potential for sync storms, and increased API costs. 15-minute intervals are fine for a demo corpus that changes infrequently | Cron-based sync is the right trade-off; systemd shutdown hook covers the critical case |
| Managed Kubernetes service (EKS/GKE/AKS) | "Use cloud-native managed k8s" | Same argument as Kubernetes: adds too much infrastructure for a t3.micro portfolio demo. The existing eks-cluster-from-scratch project covers managed Kubernetes | Docker Compose on EC2 is the correct scope |

## Feature Dependencies

```
[Terraform IaC]
    └──prerequisites──> [SSM Parameter Store secrets exist] (manual step, documented in README)
    └──prerequisites──> [S3 graph bucket exists] (created by Terraform)
    └──enables──> [EC2 instance boots]

[EC2 Instance + user_data]
    └──starts──> [Docker Compose + LightRAG]
    └──restores──> [rag_storage from S3] (if backup exists)

[rag_storage on disk]
    └──fed by──> [Document ingestion] (POST /documents/text)
    └──queried by──> [RAG query] (POST /query)
    └──synced to──> [S3 bucket] (cron 15min + systemd shutdown)

[GitHub Actions deploy workflow]
    └──requires──> [Health check endpoint] (/health)
    └──validates──> [Playwright smoke tests]

[Playwright smoke tests]
    └──requires──> [LightRAG API accessible]
    └──tests──> [Document ingestion -> poll -> query -> assert]
```

### Dependency Notes

- **Terraform IaC requires SSM parameters to be set manually first:** Because secrets appear in Terraform state, the project-spec correctly mandates manual SSM setup as a post-apply step. The user_data script waits for these to exist.
- **EC2 user_data requires S3 bucket to exist:** Terraform creates the graph storage bucket (separate from the state bucket). The restore step fails gracefully if the bucket is empty (first deploy).
- **Docker Compose requires .env to be written by user_data:** user_data fetches SSM params and writes /app/.env before running `docker compose up`.
- **Playwright tests require LightRAG to be running:** Tests are gated behind the health check; they run after deploy workflow completes the docker compose restart.
- **S3 sync requires rag_storage to exist:** First run creates an empty directory; subsequent runs upload the actual index data.

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to demonstrate a working production-grade RAG deployment.

- [ ] Terraform: EC2 t3.micro, Elastic IP, S3 graph bucket, IAM instance role (scoped S3 + SSM), security group (22, 443, 9621) — core infrastructure
- [ ] EC2 user_data: 2GB swap setup, Docker install, S3 rag_storage restore, SSM secret load, docker compose up — automated instance bootstrapping
- [ ] S3 persistence: cron job (15-min sync to S3) + systemd shutdown unit (sync before stop) — graph survival across restarts
- [ ] .env configured: Anthropic Claude (Sonnet for queries, Haiku for indexing) + OpenAI text-embedding-3-large for embeddings — API-hosted, RAM-preserving
- [ ] GitHub Actions deploy workflow: release tag trigger, SSH deploy, docker compose pull/restart, /health check — automated deployment
- [ ] Playwright E2E smoke tests: ingest text, poll track_id, hybrid query, assert entity in response — validates full pipeline
- [ ] README: ASCII architecture diagram, SSM setup commands, cost breakdown, demo curl script — portfolio audience can understand it in <2 min

### Add After Validation (v1.x)

Features to add once the core deploy pipeline works reliably.

- [ ] CloudWatch Logs + structured logging — observability into container stdout/stderr, searchable log queries
- [ ] HTTPS via nginx reverse proxy + ACM certificate — secure browser access without CloudFront complexity
- [ ] Custom domain via Route53 + ACM — replace Elastic IP with memorable domain name
- [ ] Upgrade to t3.small — if OOM or CPU pressure appears on t3.micro under demo load
- [ ] Health check script with retry logic — prevent GitHub Actions from succeeding on a degraded startup

### Future Consideration (v2)

Features to defer until product-market fit for the portfolio is established.

- [ ] EKS deployment — Kubernetes pattern for the DevOps portfolio; demonstrates terraform-aws-modules/eks, Karpenter, Helm charts, Ingress/NLB, HPA, ESO
- [ ] Multi-AZ deployment with ASG — high availability for a production RAG service
- [ ] CloudFront CDN — static asset caching, DDoS protection, TLS at edge
- [ ] Managed storage backends (PostgreSQL/pgvector or Neo4j) — replace local file storage with proper managed databases
- [ ] Langfuse tracing integration — RAG observability and quality evaluation
- [ ] Multi-user authentication with JWT accounts — replace single API key with per-user credentials

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Terraform IaC (EC2, EIP, S3, IAM, SG) | HIGH | MEDIUM | P1 |
| EC2 user_data (swap, Docker, restore, secrets, compose) | HIGH | MEDIUM | P1 |
| S3 persistence (cron + systemd shutdown hook) | HIGH | MEDIUM | P1 |
| SSM Parameter Store for secrets | HIGH | LOW | P1 |
| GitHub Actions OIDC deploy workflow | HIGH | MEDIUM | P1 |
| Playwright smoke tests | MEDIUM | MEDIUM | P1 |
| API key authentication (LIGHTRAG_API_KEY) | HIGH | LOW | P1 |
| Health check endpoint (/health) | HIGH | LOW | P1 |
| README with architecture, setup, cost, demo | MEDIUM | LOW | P1 |
| Multi-mode query (hybrid, local, global, naive, mix) | MEDIUM | LOW | P1 |
| WebUI knowledge graph visualisation | MEDIUM | LOW | P1 |
| Streaming query responses | MEDIUM | LOW | P1 |
| CORS configuration for browser access | MEDIUM | LOW | P1 |
| CloudWatch observability (logs, metrics) | MEDIUM | MEDIUM | P2 |
| HTTPS via nginx + ACM | MEDIUM | MEDIUM | P2 |
| Custom domain (Route53 + ACM) | LOW | MEDIUM | P2 |
| t3.small upgrade path (Terraform variable) | MEDIUM | LOW | P2 |
| EKS deployment (v2) | HIGH | HIGH | P3 |
| Multi-AZ ASG (v2) | MEDIUM | HIGH | P3 |
| Managed storage backends (v2) | MEDIUM | HIGH | P3 |

**Priority key:**
- P1: Must have for launch (core deploy pipeline)
- P2: Should have, add when possible (operational quality)
- P3: Nice to have, future consideration (portfolio extensions)

## Competitor Feature Analysis

| Feature | Typical "Deploy RAG to EC2" Tutorial | This Project | Our Advantage |
|---------|--------------------------------------|--------------|---------------|
| Infrastructure | Manual console clicks or copy-paste script | Terraform IaC with module conventions | Reproducible, version-controlled, portfolio-grade |
| Secrets | Hardcoded in .env or .env.local in git | SSM Parameter Store with scoped IAM | Zero secrets in source; production pattern |
| Persistence | Nothing (data lost on restart) or manual S3 copy | Cron 15-min sync + systemd shutdown hook | Automatic, systematic, covers planned and accidental stops |
| CI/CD | Manual SSH after git push | GitHub Actions OIDC on release tag | Automated, credential-free, production pattern |
| Testing | Manual curl or browser testing | Playwright E2E smoke tests | Validated deploys, not "looks like it worked" |
| Documentation | One README with minimal setup | Architecture diagram, SSM steps, cost breakdown, demo script | Recruiter/hiring engineer can understand in <2 min |
| Auth | No auth or poorly configured | API key via LIGHTRAG_API_KEY from SSM | Production-grade access control |
| RAM management | Local Ollama embedding models (OOM on t3.micro) | API-hosted OpenAI embeddings | t3.micro viable; no model serving overhead |
| HTTPS | Not covered or complex (CloudFront setup) | Out of scope v1, nginx-ready v1.x | Correctly deferred; not blocking demo |
| Observability | None | CloudWatch-ready (v1.x) | Logs streamed to CloudWatch; searchable, alertable |

## Sources

- HKUDS/LightRAG GitHub repository — https://github.com/HKUDS/LightRAG — HIGH confidence
  - env.example: All environment variables with purposes and defaults
  - docker-compose.yml: Port 9621, volume mounts, restart policy
  - docker-compose-full.yml: Full infrastructure stack (GPU-dependent services out of scope)
  - lightrag/api/README.md: API endpoints, authentication, operational features
  - lightrag/api/routers/document_routes.py: POST /documents/scan, /documents/upload, /documents/text, /documents/texts, DELETE /documents, GET /track_status/{track_id}
  - lightrag/api/routers/query_routes.py: POST /query, /query/stream, /query/data with all query modes
  - lightrag/api/routers/graph_routes.py: Graph entity/relation CRUD, label search, subgraph retrieval
  - NEWS section: Feature history (2024-2026) including citation, reranker, MongoDB, PostgreSQL, OpenSearch, Langfuse, RAGAS, multimodal
- project-spec.md: V1 scope, constraints, manual SSM setup, cost reference — HIGH confidence
- .planning/PROJECT.md: Requirements, out of scope, key decisions — HIGH confidence

---
*Feature research for: RAG server deployment on AWS EC2*
*Researched: 2026-04-02*
