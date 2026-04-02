# Architecture Research

**Domain:** RAG (Retrieval-Augmented Generation) server on single EC2 instance
**Researched:** 2026-04-02
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
+------------------------------------------------------------------------------+
|                          AWS EC2 t3.micro (Ubuntu 24.04)                      |
|                                                                               |
|  +-----------------------------------------------------------------------+    |
|  |                     Docker Compose (single container)                   |    |
|  |                                                                        |    |
|  |  +-------------+  +-------------------+  +------------------------+  |    |
|  |  |   FastAPI   |  |  LightRAG Engine  |  |   React WebUI          |  |    |
|  |  |   Server    |--+--->   (core)       |  |   (served at /webui/) |  |    |
|  |  |   :9621     |  |                   |  |                        |  |    |
|  |  +-------------+  +-------------------+  +------------------------+  |    |
|  |       ^                   ^                                              |    |
|  |       |                   |                                              |    |
|  |  +----v-------------------v--------------------------------------------+ |    |
|  |  |                   Storage Layer (rag_storage/)                     | |    |
|  |  +----------------+---------------------+---------------------------+ |    |
|  |  |  Vector DB     |   Graph DB (NetworkX)  |   KV Store (JSON files) | |    |
|  |  |  chunks_vdb/  |   chunk_entity_relation|   full_docs/            | |    |
|  |  |  entities_vdb/ |   _graph.gpickle       |   text_chunks/          | |    |
|  |  |  relationships_│                        |   llm_response_cache/   | |    |
|  |  |  vdb/         |                        |   doc_status/           | |    |
|  |  +----------------+---------------------+---------------------------+ |    |
|  +-----------------------------------------------------------------------+    |
|                           |                                                        |
|  +------------------------v------------------------------------------------+    |
|  |           Persistent Volumes (bind-mounted from host)                    |    |
|  |   /app/data/rag_storage <--+--> /opt/lightrag/rag_storage (host path)   |    |
|  |   /app/data/inputs        <--+--> /opt/lightrag/inputs                   |    |
|  |   /app/.env               <--+--> /opt/lightrag/.env                    |    |
|  +-------------------------------------------------------------------------+    |
|                                                                               |
|  +-------------------------------------------------------------------------+    |
|  |              System Services (user_data bootstrap)                        |    |
|  |  +------------+  +---------------+  +----------------+  +-----------+  |    |
|  |  | Docker CE  |  | 2GB Swap File  |  | Cron (15 min)  |  | systemd   |  |    |
|  |  |            |  | (t3.micro RAM) |  | S3 sync up     |  | shutdown |  |    |
|  |  |            |  |                |  |                |  | hook     |  |    |
|  |  +------------+  +---------------+  +----------------+  +-----------+  |    |
|  +-------------------------------------------------------------------------+    |
+------------------------------------------------------------------------------+
        |                         |                        |
        v                         v                        v
  +------------+          +------------+           +------------+
  |   Users    |          |     S3      |           |    SSM      |
  | (browser/ |          | (graph      |           | Parameter   |
  |   API     |          |  persistence)|           | Store       |
  +------------+          +------------+           | (secrets)  |
        |                         ^                        |
        v                         |                        v
  [Elastic IP:9621]    cron /opt/lightrag/rag_storage  aws ssm get-parameter
                          --> s3://mythicc-lightrag-rag/   /lightrag/*
                          (every 15 min)
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation | Persistence |
|-----------|----------------|------------------------|-------------|
| **FastAPI Server** | HTTP API layer — exposes document and query endpoints, serves WebUI, handles auth (API key, JWT) | `ghcr.io/hkuds/lightrag:latest` via `lightrag-server` command | Stateless, restarts with container |
| **LightRAG Engine** | Core RAG logic — orchestrates chunking, embedding, entity extraction, LLM calls, retrieval, and response synthesis | Python async library (`lightrag.operate`) | Reads/writes to `rag_storage/` |
| **Vector DB** (NanoVectorDB) | Stores embeddings for chunks, entities, and relationships. Used for similarity search during retrieval | SQLite-backed, files in `rag_storage/` | Survives container restart via host bind mount |
| **Graph DB** (NetworkX) | Stores entity-relation graph as pickle files. Enables KG traversal, local/global queries | NetworkX `MultiDiGraph`, serialized to `.gpickle` | Survives container restart via host bind mount |
| **KV Store** (JsonKVStorage) | Stores raw documents, chunked text, LLM response cache, document status | JSON files per collection in `rag_storage/` | Survives container restart via host bind mount |
| **Docker Compose** | Orchestrates the single LightRAG container, bind-mounts host directories, sets env vars | `docker compose up -d` | Compose config is idempotent |
| **S3 Sync (Cron)** | Uploads `rag_storage/` to S3 every 15 minutes for off-instance durability | `aws s3 sync` via cron job | S3 is the source of truth for graph persistence |
| **Systemd Shutdown Hook** | Syncs `rag_storage/` to S3 before instance stop/reboot | systemd service + `ExecStopPost` | Ensures no data loss on controlled shutdown |
| **SSM Parameter Store** | Stores API keys (ANTHROPIC_API_KEY, OPENAI_API_KEY, LIGHTRAG_API_KEY) as SecureString | Read at instance boot via `aws ssm get-parameter` | IAM instance role must allow `ssm:GetParameter` on `/lightrag/*` |
| **user_data Bootstrap** | Sets up swap, installs Docker, clones LightRAG repo, restores from S3, loads SSM secrets, starts Docker Compose | Shell script run once by cloud-init on first boot | Idempotent; Docker Compose is already running on subsequent boots |

### LightRAG API Endpoint Groups

| Group | Endpoints | Purpose |
|-------|-----------|---------|
| **Documents** | `POST /documents/text`, `POST /documents/texts`, `POST /documents/upload`, `POST /documents/scan` | Ingest documents into the RAG system |
| **Query** | `POST /query`, `POST /query/stream`, `POST /local`, `POST /global`, `POST /hybrid`, `POST /mix`, etc. | Retrieve and generate responses |
| **Graph** | `GET /graph/*` | Explore the entity-relation knowledge graph |
| **System** | `GET /health`, `GET /docs` (Swagger), `GET /redoc` | Health checks and API documentation |
| **WebUI** | `GET /webui/` | React-based WebUI served by the FastAPI server |
| **Tracking** | `GET /track_status/{track_id}` | Monitor async document processing progress |

## Recommended Project Structure

```
lightrag-aws-deployment/
├── .env.example                        # Template for .env (all LIGHTRAG_*, API keys)
├── .env                                # Actual secrets (gitignored, created on instance)
├── docker-compose.yml                  # Upstream compose, bind-mounts host paths
├── docker-compose.override.yml         # Dev overrides (volumes, ports) — gitignored
├── .github/
│   └── workflows/
│       ├── deploy.yml                  # Release tag trigger: SSH deploy + health check
│       └── test.yml                    # Playwright smoke tests on release tag
├── terraform/
│   ├── backend.tf                      # S3 remote state (bucket: mythicc-lightrag-tfstate)
│   ├── provider.tf                     # AWS provider + region
│   ├── main.tf                         # EC2 instance + IAM role + security group
│   ├── outputs.tf                      # Elastic IP, SSH command, endpoint URL
│   ├── variables.tf                    # instance_type, ami_id, project_name
│   └── user_data.sh                    # Bootstrap script (swap, Docker, S3 restore, SSM, compose up)
├── scripts/
│   ├── s3-sync-cron.sh                 # Cron script: aws s3 sync rag_storage/ to S3
│   └── systemd-shutdown.service        # systemd unit: sync before shutdown
├── tests/
│   └── smoke_test.py                  # Playwright E2E: ingest -> poll -> query -> assert
├── terraform.tfvars.example            # Template for terraform.tfvars (gitignored)
├── README.md                           # Architecture diagram, SSM setup, cost, demo curl
└── .gitignore
```

### Structure Rationale

- **`.env.example` / `.env`:** Separating template from actual secrets is critical. The `env.example` is committed and documents all available configuration variables. The `.env` file with real secrets is created on the EC2 instance and never leaves it.
- **`docker-compose.yml` as-is:** The upstream compose file is used without modification. Any environment-specific overrides (local dev ports, different volume paths) go into `docker-compose.override.yml` which is gitignored. This avoids forking the upstream.
- **`terraform/` flat layout:** Consistent with `ec2-static-site` and `multi-container-service` portfolio projects. Single-instance means no module subdirectory complexity is warranted.
- **`terraform/user_data.sh`:** Bootstrap script is kept inside `terraform/` to keep the root directory clean. This matches the pattern of `ec2-static-site/scripts/setup.sh`.
- **`scripts/s3-sync-cron.sh` + `scripts/systemd-shutdown.service`:** Persistence-related scripts are in a dedicated `scripts/` directory, keeping them visible and testable independently.
- **`tests/smoke_test.py`:** Playwright smoke tests live at the repo root alongside `docker-compose.yml`, making it clear they run against the deployed application.
- **`.github/workflows/deploy.yml` + `.github/workflows/test.yml`:** Deploy and test are separate workflows. Deploy runs on release tag. Tests run on release tag or on-demand. This mirrors the separation between deploy and smoke test in `blue-green-deployment`.

## Architectural Patterns

### Pattern 1: Single-Container Docker Compose

**What:** One Docker Compose service runs the entire LightRAG stack (FastAPI + WebUI). No sidecar containers.

**When to use:** When the application is self-contained (as LightRAG is) and no additional services (reverse proxy, database, cache) are needed. The upstream `docker-compose.yml` defines exactly this pattern.

**Trade-offs:**
- Pros: Simplest possible deployment. One `docker compose up -d`. Fast startup. No networking complexity between containers.
- Cons: All resources (Python process, Gunicorn workers, LightRAG async loop) compete for t3.micro RAM. Swap mitigates but does not eliminate this constraint.

### Pattern 2: Host-Bind-Mounted Persistence

**What:** The `rag_storage/` directory is stored on the EC2 host filesystem and bind-mounted into the container at `/app/data/rag_storage`. The host directory is periodically synced to S3.

**When to use:** When the storage is file-based (as LightRAG's default NanoVectorDB, NetworkX, and JsonKVStorage all are) and you want persistence without running a separate database container.

**Trade-offs:**
- Pros: Simple. `docker compose` does not manage persistence -- the host filesystem does. Works with any container restart. S3 sync provides off-instance durability.
- Cons: Two copies of data exist (host + S3). Sync lag means up to 15 minutes of data loss on unexpected instance termination. No concurrent access control (two instances would corrupt data).

```bash
# In docker-compose.yml:
volumes:
  - /opt/lightrag/rag_storage:/app/data/rag_storage   # Host path : Container path
  - /opt/lightrag/.env:/app/.env                     # Secrets on host, not baked into image
```

### Pattern 3: S3 Sync with Shutdown Hook

**What:** A cron job syncs `rag_storage/` to S3 every 15 minutes. A systemd `ExecStopPost` hook syncs immediately before the instance stops.

**When to use:** When using file-based storage on a single EC2 and you need off-instance durability without running a managed database (RDS, DynamoDB, etc.).

**Trade-offs:**
- Pros: Zero additional infrastructure. `$0` cost for a small demo corpus (<100MB). No external service dependency at runtime.
- Cons: Up to 15 minutes of data loss on unexpected termination (no crash-consistent S3 sync). S3 is eventually consistent, so there is a brief window where the most recent sync may not reflect all writes.

```bash
# Cron: /etc/cron.d/lightrag-s3-sync
*/15 * * * * root aws s3 sync /opt/lightrag/rag_storage/ s3://mythicc-lightrag-rag/rag_storage/ --delete

# Systemd: /etc/systemd/system/lightrag-shutdown.service
[Service]
Type=oneshot
ExecStopPost=/opt/lightrag/scripts/s3-sync.sh
```

### Pattern 4: SSM Parameter Store for Secrets Injection

**What:** API keys are stored in SSM Parameter Store (SecureString) and read at instance boot via `aws ssm get-parameter --with-decryption`. The decrypted values are written to `/opt/lightrag/.env`, then Docker Compose reads them.

**When to use:** When deploying to EC2 without a secrets management service (AWS Secrets Manager, HashiCorp Vault) and when you do not want secrets in Terraform state or GitHub Secrets.

**Trade-offs:**
- Pros: Free (SSM Standard tier). No secrets in Terraform state. No secrets in git. IAM-based access control.
- Cons: Manual one-time setup required after `terraform apply` (documented in README). The `.env` file is written to disk unencrypted on the host (protected by EC2 disk encryption at rest, but not by additional encryption).

### Pattern 5: GitHub Actions OIDC Deploy (Reuse Existing Role)

**What:** The GitHub Actions workflow assumes an existing IAM OIDC role (`mythicc123`) to get temporary AWS credentials for reading the Terraform state bucket and triggering the deploy. The actual deployment is done via SSH into the EC2 instance.

**When to use:** When you have an existing OIDC provider and IAM role already configured in AWS (as this portfolio project does).

**Trade-offs:**
- Pros: No long-lived AWS credentials stored in GitHub Secrets. The `mythicc123` role is reused across portfolio projects, reducing AWS IAM complexity.
- Cons: The workflow still needs the SSH private key as a GitHub Secret for the `appleboy/ssh-action` step. The OIDC role provides AWS API access; SSH provides the actual deployment.

```yaml
# Simplified deploy flow:
- uses: aws-actions/configure-aws-credentials@v4  # OIDC role
  with:
    role-to-assume: arn:aws:iam::ACCOUNT:role/mythicc123
    aws-region: ap-southeast-2
- uses: appleboy/ssh-action@v1.2.5               # SSH for actual deployment
  with:
    host: ${{ secrets.EC2_HOST }}
    key: ${{ secrets.EC2_SSH_KEY }}
    script: |
      cd /opt/lightrag
      git pull
      docker compose pull
      docker compose up -d
      curl -f http://localhost:9621/health
```

## Data Flow

### Query Flow (User Request to Response)

```
[User / API Client]
      |
      v (HTTP POST /query with JSON body)
[Elastic IP] ---> [AWS Security Group] ---> [EC2 Instance]
      |                :22 (SSH)                |
      |                :9621 (HTTP)             |
      v                                        v
[GitHub Actions]                        [Docker Container]
(monitoring health)                     lightrag:latest :9621
                                              |
                                    +---------v----------+
                                    |    FastAPI Server   |
                                    |  (lightrag-server) |
                                    +---------v----------+
                                              |
                                    +---------v----------+
                                    |  LightRAG Engine   |
                                    |  (rag.query)       |
                                    +-+-------+----+-----+
                                      |       |    |
                  +-------------------+       |    +-------------------+
                  |                           |                        |
         +--------v--------+        +---------v--------+      +---------v--------+
         | Vector Search  |        |  Graph Traversal|      |  KV Store Lookup |
         | (chunks_vdb)   |        |  (NetworkX KG)   |      |  (full_docs,     |
         | "find similar  |        |  "find entities  |      |   text_chunks)   |
         |  chunks"       |        |  and relations"   |      |                  |
         +--------+--------+        +---------+--------+      +---------v--------+
                  |                          |                           |
                  +----------+---------------+---------------------------+
                              v
                   +----------v----------+
                   |  Result Merger      |
                   |  (hybrid/mix mode   |
                   |   combines all 3)   |
                   +----------v----------+
                              |
                   +----------v----------+
                   |  LLM Synthesis       |
                   |  (Anthropic Sonnet   |
                   |   via API call)      |
                   +----------v----------+
                              |
                   +----------v----------+
                   |  JSON Response       |
                   |  {response,          |
                   |   references}       |
                   +----------v----------+
                              |
[User / API Client] <------- (HTTP response)
```

### Document Ingestion Flow

```
[User POST /documents/text or /documents/upload]
      |
      v
[FastAPI Server] ---> [LightRAG Engine.insert()]
      |                        |
      |              +---------v----------+
      |              |  Async Pipeline    |
      |              |  1. Validate & dedupe (full_docs)
      |              |  2. Chunk text (CHUNK_SIZE, CHUNK_OVERLAP_SIZE)
      |              +---------v----------+
      |              |  3. Embed chunks (OpenAI text-embedding-3-large)
      |              |     -> Vector DB (chunks_vdb)
      |              |     -> KV Store (text_chunks)
      |              +---------v----------+
      |              |  4. Entity extraction (Anthropic Haiku)
      |              |     -> Entities (entities_vdb)
      |              |     -> Relations (relationships_vdb)
      |              |     -> Graph (chunk_entity_relation_graph.gpickle)
      |              +---------v----------+
      |              |  5. Write doc status (doc_status)
      +--------------v--------------+
      |  Return track_id           |
      |  POST /track_status/{id}   |
      +----------------------------+
```

### Persistence Flow

```
[rag_storage/ on host] <---- cron (15 min) ----> [S3: mythicc-lightrag-rag/rag_storage/]
     ^                                                    |
     | (on instance boot / restart)                       |
     +----------------- aws s3 sync (restore) ------------+
```

```
On instance boot (user_data):
1. Mount volumes (if not already)
2. aws ssm get-parameter /lightrag/* -> /opt/lightrag/.env
3. aws s3 sync s3://mythicc-lightrag-rag/rag_storage/ /opt/lightrag/rag_storage/
4. docker compose -f /opt/lightrag/docker-compose.yml up -d
5. LightRAG loads existing rag_storage/ (graphs, vectors, KV data intact)
```

```
On controlled instance stop (systemd shutdown hook):
1. ExecStopPost triggers /opt/lightrag/scripts/s3-sync.sh
2. aws s3 sync /opt/lightrag/rag_storage/ s3://mythicc-lightrag-rag/rag_storage/ --delete
3. Only then does the instance actually stop
```

### CI/CD Deployment Flow

```
[Developer] --git tag v1.x.x--> [GitHub]
                                     |
                        +------------v-------------+
                        | GitHub Actions          |
                        | on: push tags matching   |
                        | v*.*.*                   |
                        +------------+------------+
                                     |
                        +------------v-------------+
                        | 1. Assume OIDC role      |
                        |    (mythicc123)           |
                        +------------+-------------+
                                     |
                        +------------v-------------+
                        | 2. SSH to EC2 via        |
                        |    appleboy/ssh-action   |
                        +------------+-------------+
                                     |
                        +------------v-------------+
                        | 3. On EC2:               |
                        |    cd /opt/lightrag      |
                        |    git pull origin main  |
                        |    docker compose pull   |
                        |    docker compose up -d  |
                        +------------+-------------+
                                     |
                        +------------v-------------+
                        | 4. Health check          |
                        |    curl :9621/health     |
                        +------------+-------------+
                                     |
                        +------------v-------------+
                        | 5. Trigger test workflow |
                        +--------------------------+
```

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|-------------------------|
| 0-100 users (V1 target) | Single t3.micro, API-hosted embeddings, S3 sync every 15 min. This is the sweet spot. No changes needed. |
| 100-1,000 users | Upgrade EC2 to t3.small or t3.medium. Increase swap to 4GB. Consider increasing S3 sync frequency to every 5 min. Embedding API costs scale linearly with query volume. |
| 1,000-10,000 users | Offload embeddings to a dedicated service (e.g., a separate lightweight embedding server). Consider migrating to RDS PostgreSQL (pgvector) for the vector store. Move LLM calls to a queue (Redis + worker) to prevent timeout under load. |
| 10,000+ users | Single EC2 is no longer viable. Migrate to EKS (existing `eks-cluster-from-scratch` project provides the foundation). Use Karpenter for node autoscaling. Split into microservices: API server, indexing worker, query worker, vector DB cluster. |

### Scaling Priorities

1. **First bottleneck: RAM on t3.micro.** LightRAG + Gunicorn + Python async loop + Docker daemon + OS comfortably exceed 1GB. The 2GB swap is a mitigation, not a solution. If the corpus grows or concurrent queries spike, expect OOM kills. **Fix: Upgrade to t3.small or t3.medium.**
2. **Second bottleneck: Embedding API latency.** Every document ingestion triggers synchronous OpenAI API calls. If the corpus grows large, indexing time grows linearly. **Fix: Batch embeddings, add async concurrency control.**
3. **Third bottleneck: S3 sync lag.** 15-minute sync interval means up to 15 minutes of data loss on crash. For a portfolio demo this is acceptable. **Fix: S3 sync every 5 minutes + systemd shutdown hook already covers the critical path.**

## Anti-Patterns

### Anti-Pattern 1: Committing Secrets to Git

**What people do:** Adding `.env` to git, or hardcoding API keys in `user_data.sh`, or putting them in Terraform variable defaults.

**Why it's wrong:** API keys appear in GitHub history, Terraform state, and CI logs. They are immediately compromised.

**Do this instead:** Store secrets in SSM Parameter Store. Read them at instance boot. Keep `.env` in the gitignore. Document the one-time SSM setup step in the README.

### Anti-Pattern 2: Using Local Embeddings (Ollama) on t3.micro

**What people do:** Installing Ollama + `nomic-embed-text` on the EC2 instance to avoid OpenAI API costs.

**Why it's wrong:** Ollama runs a full LLM inference server in RAM. `nomic-embed-text` alone consumes 300-500MB RAM. Combined with LightRAG's Python process and Docker overhead, this guarantees OOM kills on t3.micro.

**Do this instead:** Use OpenAI `text-embedding-3-large` via API. At demo scale (<10K chunks), embedding costs are ~$0.001. The RAM headroom is worth more than the micro-cost.

### Anti-Pattern 3: Local State Without S3 Sync

**What people do:** Relying on the bind-mounted `rag_storage/` directory alone, without S3 sync, assuming the instance will never be terminated.

**Why it's wrong:** AWS can terminate EC2 instances (Spot interruption, AZ failure). A portfolio demo that loses its knowledge graph on instance termination destroys the demo narrative.

**Do this instead:** S3 sync every 15 minutes via cron. Systemd shutdown hook on stop. S3 restore on boot. This pattern is documented in the project spec and should not be skipped for "simplicity."

### Anti-Pattern 4: Forking the Upstream LightRAG Repo

**What people do:** Cloning the LightRAG repo and modifying it to add AWS-specific code, custom endpoints, or changed storage backends.

**Why it's wrong:** Fork maintenance is a perpetual burden. Upstream updates (bug fixes, new features, security patches) require manual merging. It conflates infrastructure work with application development.

**Do this instead:** Use `ghcr.io/hkuds/lightrag:latest` as a black box. All AWS-specific logic lives in Terraform `user_data.sh`, the `.env` configuration, the `docker-compose.yml` overrides, and the CI/CD workflow. The upstream is never modified.

### Anti-Pattern 5: No Health Check Before Nginx / Load Balancer Switch

**What people do:** Immediately switching traffic to a new deployment without polling the `/health` endpoint.

**Why it's wrong:** LightRAG takes 30-60 seconds to initialize storages on first boot. A health check that passes may be stale. The container may be running but the FastAPI server may not yet be accepting requests.

**Do this instead:** Poll `http://localhost:9621/health` in a loop with a 60-second timeout before declaring the deployment successful. This is already part of the CI/CD workflow design.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| **Anthropic API** | HTTP API calls from LightRAG container (via `ANTHROPIC_API_KEY` in `.env`) | Haiku for indexing (cheaper, faster), Sonnet for query synthesis (higher quality). Key read from SSM at boot. |
| **OpenAI API** | HTTP API calls from LightRAG container (via `OPENAI_API_KEY` in `.env`) | `text-embedding-3-large` for embeddings. API-hosted, not local. Key read from SSM at boot. |
| **AWS S3** | `aws s3 sync` from EC2 instance via IAM instance role | Instance role scoped to `mythicc-lightrag-rag` bucket only. Used for rag_storage persistence. |
| **AWS SSM Parameter Store** | `aws ssm get-parameter` from user_data.sh at boot | IAM instance role scoped to `/lightrag/*` path. Writes to `/opt/lightrag/.env`. |
| **AWS STS (OIDC)** | GitHub Actions assumes `mythicc123` role via OIDC | Provides temporary credentials for AWS API access in CI. No long-lived credentials needed. |
| **GitHub Actions** | `appleboy/ssh-action` for SSH deploy to EC2 | SSH private key stored as GitHub Secret. OIDC role provides AWS API access. |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| **GitHub Actions runner -> EC2** | SSH (TCP 22) | Deploy key is `ec2-static-site-key.pem`. EC2 host from GitHub Secret `EC2_HOST`. |
| **EC2 host -> Docker daemon** | Unix socket (`/var/run/docker.sock`) | Docker CLI is installed on the host. `docker compose` commands run from the host, not inside the container. |
| **Docker container -> host** | `host.docker.internal` (mapped to host gateway) | Enables container to reach host services if needed. Rarely used for LightRAG. |
| **Docker container -> External APIs** | Outbound HTTPS (TCP 443) | LightRAG container calls Anthropic and OpenAI APIs directly. No proxy needed. |
| **Docker container -> rag_storage/** | Bind mount from host | Container writes to `/app/data/rag_storage/` which maps to `/opt/lightrag/rag_storage/` on host. |
| **EC2 host -> S3** | AWS SDK (CLI) | IAM instance role with S3 permissions. `aws s3 sync` runs from cron or systemd on host. |
| **EC2 host -> SSM** | AWS CLI | IAM instance role with SSM permissions. `aws ssm get-parameter` runs in user_data.sh before Docker starts. |

## Build Order Implications

The architecture has a strict dependency chain. Components must be built in this order:

```
1. Terraform IaC (infrastructure foundation)
   |
   +-> Creates: VPC/networking, EC2 instance, Elastic IP, IAM role, Security Group
   |
   2. SSM Parameter Store (manual, post-terraform)
   |   Note: Cannot be automated (values would appear in Terraform state)
   |
   +-> Values needed by: user_data.sh
   |
   3. EC2 user_data bootstrap (runs automatically on first boot)
   |
   +-> Installs: Docker, swap, restores from S3, loads SSM secrets, starts container
   |
   4. Docker Compose up (started by user_data, also by CI/CD on redeploy)
   |
   +-> Starts: LightRAG FastAPI container
   |
   5. Health check verification (GitHub Actions or manual)
   |
   +-> Confirms: :9621/health returns 200
   |
   6. Document ingestion (optional, manual or via Playwright test)
   |
   +-> Builds: Knowledge graph and vector index from sample corpus
   |
   7. Playwright smoke tests (run in CI/CD on release)
   |
   +-> Validates: Full query flow end-to-end
```

**Critical path for V1:**
- Terraform provisions infrastructure (Phase 1)
- SSM parameters set manually (Phase 1, manual step)
- EC2 boots and starts LightRAG (Phase 1, automated)
- CI/CD deploy workflow works (Phase 1)
- S3 persistence survives reboot (Phase 2 or V1 enhancement)

**Non-critical but important:**
- Playwright smoke tests can be added after basic deployment works
- README with architecture diagram comes last, once everything is validated

## Sources

- HKUDS/LightRAG README -- https://github.com/HKUDS/LightRAG -- HIGH confidence
- LightRAG API documentation -- https://github.com/HKUDS/LightRAG/blob/main/lightrag/api/README.md -- HIGH confidence
- LightRAG docker-compose.yml -- https://github.com/HKUDS/LightRAG/blob/main/docker-compose.yml -- HIGH confidence
- LightRAG env.example configuration reference -- https://github.com/HKUDS/LightRAG/blob/main/env.example -- HIGH confidence
- LightRAG lightrag.py storage layer analysis -- https://github.com/HKUDS/LightRAG/blob/main/lightrag/lightrag.py -- HIGH confidence
- ec2-static-site Terraform patterns -- `C:\Users\fiefi\ec2-static-site/terraform/` -- HIGH confidence (existing portfolio project)
- multi-container-service Terraform + Docker Compose patterns -- `C:\Users\fiefi\multi-container-service/` -- HIGH confidence (existing portfolio project)
- blue-green-deployment CI/CD patterns -- `C:\Users\fiefi\blue-green-deployment/.github/workflows/deploy.yml` -- HIGH confidence (existing portfolio project)

---
*Architecture research for: LightRAG on single AWS EC2*
*Researched: 2026-04-02*
