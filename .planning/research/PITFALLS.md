# Domain Pitfalls: LightRAG on AWS EC2

**Project:** lightrag-aws-deployment
**Domain:** FastAPI Docker application on AWS EC2 (t3.micro) with Terraform IaC
**Researched:** 2026-04-02
**Confidence:** MEDIUM-HIGH (portfolio-specific patterns from existing projects, LightRAG internals from upstream docs; WebSearch unavailable so some ecosystem findings are based on first-principles reasoning)

---

## Critical Pitfalls

Mistakes that cause data loss, deployment failures, or security exposure.

---

### Pitfall 1: t3.micro Memory Exhaustion (OOM Kills)

**What goes wrong:** Docker container gets OOM-killed by the Linux OOM killer. The FastAPI app starts but crashes within seconds of receiving a request. `docker compose ps` shows the container as "restarting" (restart policy `on-failure`).

**Why it happens:** A t3.micro has 1 GiB of RAM. Ubuntu 24.04 LTS running Docker Engine consumes ~200-300 MiB. The LightRAG FastAPI process alone (Python + LLM client library + embedding client) can consume 400-800 MiB depending on the corpus size and concurrent operations. The 2 GiB swap file absorbs some pressure but swap thrashing causes kernel OOM kills when the 1 GiB physical + 2 GiB swap ceiling is hit simultaneously.

**Consequences:**
- Container in restart loop: `docker compose up -d` succeeds but the container immediately crashes
- `docker logs lightrag` shows no Python traceback -- just process termination by signal 9 (SIGKILL)
- Rag storage is corrupted if the crash occurs mid-write to SQLite/HNSWLib
- S3 sync cron job may upload a corrupted or partial rag_storage state

**Prevention:**
1. **Set Docker memory limits** in the docker-compose.yml override. Add `deploy.resources.limits.memory: "750m"` to constrain the container. This is the single most important change -- without it, Docker uses unlimited memory.
2. **Configure Python memory environment variables:** Set `PYTHONMALLOCSTATS=1` (for debugging) and `MALLOC_TRIM_THRESHOLD_=0` (reduces memory fragmentation). Set `PYTHON_GIL=0` if using uvloop (not applicable for LightRAG's sync FastAPI but useful context).
3. **Limit Gunicorn workers:** The upstream `lightrag-gunicorn --workers N` command. For t3.micro with 750 MiB limit, use `--workers 1`. More workers = more Python processes = more RAM.
4. **Set `MAX_ASYNC=1`** in the LightRAG `.env` file. This limits concurrent async operations that could spike memory during indexing.
5. **Set `EMBEDDING_BATCH_NUM=10`** (lower batch size, more frequent GC-friendly batches).
6. **Test memory pressure explicitly:** Run `docker compose up` locally on a machine with `docker run --memory=750m` to simulate t3.micro constraints before deploying.

**Detection:**
```bash
# Check dmesg for OOM kills
ssh ubuntu@<eip> "sudo dmesg | grep -i 'oom\|killed process' | tail -20"

# Check container exit codes
ssh ubuntu@<eip> "docker ps -a --filter 'status=restarting'"

# Live memory pressure
ssh ubuntu@<eip> "free -m && docker stats --no-stream"
```

**Phase:** This is a Phase 1 (IaC foundation) concern. The Docker Compose override with memory limits must be part of the initial user_data script, not added later.

---

### Pitfall 2: user_data Non-Idempotency -- Restarts Break Docker Compose

**What goes wrong:** After the first boot, `user_data` re-runs on every instance restart (cloud-init tags it as "running once per instance" but cloud-init modules can be re-triggered). The script re-runs `docker compose up -d` on top of an already-running deployment, potentially pulling a new `:latest` image and restarting services mid-operation.

**Why it happens:** The user_data script from `ec2-static-site` only installs Nginx (idempotent). LightRAG's user_data must `git pull`, `docker compose up -d`, and `aws s3 sync`. Re-running `git pull` could pull breaking changes mid-demo. Re-running `docker compose up -d` without `--no-recreate` flags can restart healthy containers.

**Consequences:**
- Git pull on restart could pull a breaking upstream change
- Docker Compose restart during active indexing corrupts rag_storage
- S3 sync runs redundantly on every restart, wasting bandwidth and S3 PUT costs

**Prevention:**
```bash
# Guard the bootstrap actions with a flag file
BOOTSTRAP_DONE="/var/lib/lightrag/.bootstrapped"
if [[ -f "$BOOTSTRAP_DONE" ]]; then
    echo "[$(date)] Bootstrap already done, skipping. Starting services only."
    cd /opt/lightrag
    docker compose up -d
else
    # Full bootstrap: swap, Docker, git clone, SSM, restore, compose up
    touch "$BOOTSTRAP_DONE"
fi
```

This pattern makes the script safe to re-run. The S3 restore logic belongs inside the bootstrap block (only restore if this is a fresh instance or rag_storage is empty). The S3 sync cron job should always run independently.

**Phase:** Phase 1 -- the user_data script is the first deliverable.

---

### Pitfall 3: SSM Parameter Not Available at Docker Startup

**What goes wrong:** Docker Compose starts before SSM parameters are loaded into `.env`. The LightRAG container starts with missing API keys, logs show authentication errors, and the service returns 401 on every request.

**Why it happens:** The user_data script runs sequentially: (1) install Docker, (2) create swap, (3) git clone, (4) load SSM params, (5) docker compose up. If step 4 fails silently (e.g., IAM instance role not yet propagated, network timeout to SSM), step 5 proceeds with an empty `.env` file.

**Consequences:**
- LightRAG starts but all LLM/embedding calls fail with auth errors
- The `/documents` and `/query` endpoints return 500 or empty responses
- No error at Docker level -- the container stays running, making it look "healthy"

**Prevention:**
1. **Add a SSM load validation step** in user_data after the `aws ssm get-parameter` calls:
   ```bash
   if [[ -z "$ANTHROPIC_API_KEY" ]]; then
       echo "ERROR: ANTHROPIC_API_KEY not loaded from SSM. Aborting startup." >&2
       exit 1
   fi
   ```
2. **Use a startup wrapper script** instead of calling `docker compose up -d` directly. The wrapper checks for required env vars and retries SSM loading up to 3 times with backoff before starting Docker.
3. **Add a Docker health check** to the compose override that calls the `/health` endpoint. If the app returns unhealthy (due to auth failure), Docker restarts the container.
4. **Create the IAM instance role before the EC2 instance** in Terraform. The instance must boot with the role already attached -- not attached afterwards. Use `aws_iam_instance_profile` and reference it in `aws_instance`.

**Detection:**
```bash
ssh ubuntu@<eip> "docker logs lightrag 2>&1 | grep -i 'api.key\|auth\|401\|403' | head -20"
ssh ubuntu@<eip> "cat /opt/lightrag/.env | grep API_KEY"
```

**Phase:** Phase 1 -- the user_data script and IAM role design.

---

### Pitfall 4: S3 Sync Race Condition (Cron + Shutdown Hook)

**What goes wrong:** During instance stop/termination, the systemd shutdown unit and the cron job both trigger simultaneously. The S3 sync runs twice: one partial (interrupted), one full. The partial upload overwrites the good state in S3. On next boot, rag_storage is restored from the corrupted S3 state.

**Why it happens:** The cron job runs every 15 minutes. If the instance stops at minute 14 of a cycle, the cron job fires at the same time as the systemd shutdown unit. Both run `aws s3 sync /opt/lightrag/rag_storage s3://<bucket>/rag_storage/`. Without locking, whichever completes last wins. If the shutdown unit wins after the cron job partially uploaded, the result is an inconsistent state.

**Consequences:**
- Data loss: graph nodes/relationships are missing from the restored rag_storage on next boot
- Corrupted vector store: embedding index is out of sync with the graph store
- "Embedding model changed" errors if the model config in the index differs from `.env`

**Prevention:**
```bash
# In the systemd shutdown unit ExecStop
ExecStop=/bin/bash -c 'flock -n /var/lock/lightrag-s3-sync.lock aws s3 sync ...'

# In the cron job wrapper
flock -n /var/lock/lightrag-s3-sync.lock /opt/lightrag/scripts/sync-to-s3.sh
```

Use `flock` (available on Ubuntu 24.04 by default) for atomic lock acquisition. The `-n` flag makes it non-blocking -- if the lock is held, the cron job skips this cycle. This is simpler and more reliable than `lockfile` or `mkdir` polling.

**Phase:** Phase 1 -- the S3 sync mechanism is part of the initial user_data deliverable.

---

### Pitfall 5: Missing Docker Health Check Enables False Positives

**What goes wrong:** The upstream docker-compose.yml has no `healthcheck` defined. Docker reports the container as "healthy" immediately after the process starts, even if the FastAPI app is still initializing, loading models, or failing authentication. CI/CD health checks and the startup wrapper both pass prematurely. The WebUI loads but all API calls fail.

**Why it happens:** Docker's default health check is only process-level (is the container running?). FastAPI's `uvicorn` starts listening on port 9621 before the LLM client is initialized. A TCP port check (`nc -z localhost 9621`) passes as soon as uvicorn binds, not when the app is ready to serve requests.

**Consequences:**
- CI/CD health check (`curl http://localhost:9621/health`) passes but the `/query` endpoint returns 500
- Docker Compose reports `Up` status but the service is unusable
- The `restart: on-failure` policy masks the problem -- the container never restarts because Docker thinks it's healthy

**Prevention:**
```yaml
# Add to docker-compose override
services:
  lightrag:
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:9621/health', timeout=5)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

Also use `docker compose up -d --wait` in the CI/CD deploy script, which waits for health checks to pass (up to the service's `start_period`).

**Phase:** Phase 1 -- the docker-compose override is part of the initial setup.

---

### Pitfall 6: Terraform Local State Instead of Remote Backend

**What goes wrong:** Terraform state is stored locally in the repo directory. `terraform apply` works locally but CI/CD pipelines fail because the runner has no local state. Merged state causes resource drift -- Terraform wants to recreate the Elastic IP, security group, or instance because the remote view differs from local.

**Why it happens:** The `ec2-static-site` project uses local state with a commented-out S3 backend example. This project specifies remote state as a hard constraint ("Do NOT use local state") but the infrastructure module is not yet built, so the pattern has not been applied.

**Consequences:**
- GitHub Actions CI/CD cannot run `terraform plan/apply` -- state file is not on the runner
- Developer runs `terraform apply` from their machine; state drifts from what CI/CD expects
- Sensitive data (EIP IDs, instance IDs) may end up in local `.tfstate` files that get committed

**Prevention:**
```hcl
terraform {
  backend "s3" {
    bucket = "mythicc-lightrag-tfstate"   # Already exists -- do NOT create
    key    = "lightrag/terraform.tfstate"
    region = "ap-southeast-2"
    dynamodb_table = "mythicc-terraform-locks"  # Use existing lock table or create
  }
}
```

The spec already defines the bucket. Ensure the Terraform lock table (DynamoDB) exists or is created in the same module. Add `lifecycle { prevent_destroy = true }` to the S3 graph bucket to avoid accidental deletion.

**Phase:** Phase 1 -- Terraform setup is the first deliverable. Remote state must be configured from day one.

---

## Moderate Pitfalls

Mistakes that cause degraded functionality, unexpected costs, or operational friction.

---

### Pitfall 7: LightRAG Embedding Model Inconsistency

**What goes wrong:** The vector store returns empty results or all queries return irrelevant content. The `/query` endpoint works but returns generic responses instead of corpus-specific content.

**Why it happens:** LightRAG stores embeddings in the rag_storage directory. If the `OPENAI_API_KEY` changes, `OPENAI_EMBEDDING_MODEL` changes, or the embedding dimension (`EMBEDDING_DIM`) changes, the stored vectors are incompatible with the new model. The symptom is silent -- queries succeed but return wrong results. From the LightRAG CLAUDE.md: "Embedding models must remain consistent between indexing and querying; changing requires clearing vector storage."

**Consequences:**
- Queries return irrelevant results, making the demo look broken
- No error in logs -- just poor quality responses
- Requires clearing rag_storage and re-indexing (wastes API credits)

**Prevention:**
1. Document `OPENAI_EMBEDDING_MODEL` and `EMBEDDING_DIM` as immutable for a given rag_storage
2. Add validation in the startup script: compare current env values against a hash stored in rag_storage/.model_config and warn if mismatch
3. Default to `text-embedding-3-large` with `EMBEDDING_DIM=3072` (standard for this model) -- do not expose these as variables
4. In the Playwright smoke tests, verify the model config matches expected values

**Phase:** Phase 2 -- CI/CD and testing. The model config validation belongs in the startup script.

---

### Pitfall 8: Security Group -- SSH Open to 0.0.0.0/0

**What goes wrong:** Port 22 is open to the entire internet. Automated SSH brute-force attacks hit the instance within hours of launch. Log files fill up with authentication failures. In a portfolio project, this signals a security skills gap to hiring engineers.

**Why it happens:** The `ec2-static-site` project opens SSH to `0.0.0.0/0` with a comment "restrict to your IP in production." This was acceptable for a dev site but inappropriate for a production portfolio project.

**Consequences:**
- Brute-force SSH attacks (visible in `/var/log/auth.log`)
- If a weak password or leaked key existed, compromise risk
- Poor security signal for a DevOps portfolio

**Prevention:**
1. **For manual SSH access:** Use AWS Systems Manager Session Manager (SSM) instead of direct SSH. The IAM instance role already needed for SSM can be extended with `amazon-ssm-agent`. This eliminates the need for port 22 entirely.
2. **If SSH is required** (e.g., for the GitHub Actions deploy via `appleboy/ssh-action`): Restrict to GitHub Actions IP ranges using an AWS Prefix List for GitHub. This is dynamic but documented at [ip-ranges.amazonaws.com](https://ip-ranges.amazonaws.com/ip-ranges.json) and updated weekly.
3. **Terraform variable for SSH source CIDR** with a safe default:
   ```hcl
   variable "ssh_allowed_cidr" {
     description = "CIDR block allowed to SSH. Use 'self' or a specific IP."
     default    = "0.0.0.0/0"  # Override in terraform.tfvars
   }
   ```

The deploy workflow uses `appleboy/ssh-action` which authenticates via SSH key stored in GitHub Secrets. Port 22 is required for GitHub Actions deploy. The best mitigation is to use the GitHub Actions IP allowlist or, preferably, use SSM Session Manager for all access and restrict port 22 entirely.

**Phase:** Phase 1 -- Terraform security group configuration.

---

### Pitfall 9: Elastic IP Billing Trap

**What goes wrong:** The instance is stopped (for cost savings or after a demo). The Elastic IP continues to accrue charges at ~$3.60/month because it is associated but the instance is stopped. After 1-2 months of stopped time, the Elastic IP charge exceeds the cost of just leaving the instance running.

**Why it happens:** AWS charges for Elastic IPs when they are not associated with a running instance (or associated with a stopped instance). The project spec documents this but there is no automated prevention -- a developer who stops the instance to save money gets a bill surprise.

**Consequences:**
- Unexpected AWS charges ($3.60/month for a stopped instance)
- If the instance is terminated (not stopped), the EIP becomes orphaned and eventually released
- The README warning is easily forgotten

**Prevention:**
1. **Use an EIP allocation ID output** and document the disassociation step: `aws ec2 disassociate-address --allocation-id <id>` before stopping
2. **Terraform lifecycle hook:** Use `lifecycle { prevent_destroy = false }` on the EIP but add a README warning with the exact CLI command to run
3. **Consider NOT using an EIP** for V1 if cost is critical. Instead, use a Route53 A record with the instance's public IP (which changes on restart). Add a startup script that updates the Route53 record on boot. This avoids EIP billing entirely but adds complexity.
4. **Reminder in README:** Include the exact `terraform destroy` command as the preferred "stop billing" option for demo periods

**Phase:** Phase 1 -- Terraform EIP resource and README documentation.

---

### Pitfall 10: Docker Image Pull Failures on Restart

**What goes wrong:** After `docker compose up -d`, the container fails to start with "image not found" or a 403 Forbidden from the GHCR registry. The service is down.

**Why it happens:** GHCR (GitHub Container Registry) requires authentication to pull private images. `ghcr.io/hkuds/lightrag:latest` is a public image but GitHub rate-limits unauthenticated pulls (5,000 requests/hour per IP for public packages). On a t3.micro that restarts frequently or pulls frequently, rate limiting can occur. Additionally, GHCR images may be garbage-collected or retagged if the upstream project updates.

**Consequences:**
- Service fails to start after restart
- CI/CD deploy fails
- The WebUI is unreachable

**Prevention:**
1. **Use a pinned digest instead of `:latest`:** `docker pull ghcr.io/hkuds/lightrag:latest && docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/hkuds/lightrag:latest` to get the SHA256 digest. Use `ghcr.io/hkuds/lightrag@sha256:<digest>` in the compose override. This is reproducible and immune to re-tagging.
2. **Pull and tag locally in user_data:**
   ```bash
   docker pull ghcr.io/hkuds/lightrag:latest
   docker tag ghcr.io/hkuds/lightrag:latest lightrag:local
   # In docker-compose override, reference lightrag:local
   ```
3. **Authenticate to GHCR in user_data** using a GitHub PAT stored in SSM. This avoids rate limiting and ensures access to the registry.

**Phase:** Phase 1 -- user_data Docker setup.

---

### Pitfall 11: CI/CD -- Missing Concurrency Control

**What goes wrong:** A second release tag is pushed while the first CI/CD pipeline is still running. Two deploy jobs run concurrently, both SSH into the same instance, and race on `docker compose up -d`. Containers are pulled, started, and killed mid-deployment. The end state is a mixed version with unpredictable behavior.

**Why it happens:** Unlike `ec2-static-site` (no concurrency control) and `blue-green-deployment` (has `concurrency: cancel-in-progress: true`), this project may omit concurrency control if the pattern is not carried forward.

**Consequences:**
- Mixed version running (some containers from v1, some from v2)
- S3 sync may run during deployment, uploading inconsistent state
- CI/CD logs are confusing -- two runs interleaving

**Prevention:**
```yaml
# In .github/workflows/deploy.yml
concurrency:
  group: ${{ github.repository }}-lightrag
  cancel-in-progress: true
```

Use a separate concurrency group name from other projects (`-lightrag` suffix) to allow parallel runs of different projects while serializing runs within this project.

**Phase:** Phase 2 -- CI/CD workflow.

---

### Pitfall 12: IAM Role Too Broad (Least Privilege Violation)

**What goes wrong:** The EC2 instance IAM role grants `s3:*` on all buckets. If the instance is compromised (container escape, misconfigured app), the attacker can read/write any S3 bucket in the account, including the Terraform state bucket and other projects' data.

**Why it happens:** The easiest IAM policy is `s3:*` on `*` for rapid development. The spec says "S3 read/write scoped to graph bucket only" but this specificity must be implemented in Terraform.

**Consequences:**
- Security posture violation: least privilege not followed
- If the instance is in a portfolio demo, this signals IAM skills gap
- Blast radius is the entire account's S3 data

**Prevention:**
```hcl
data "aws_iam_policy_document" "ec2_s3" {
  statement {
    sid    = "GraphStorageBucketOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:DeleteObject",
    ]
    resources = [
      aws_s3_bucket.graph_storage.arn,
      "${aws_s3_bucket.graph_storage.arn}/*",
    ]
  }
  # SSM read-only for /lightrag/* path
  statement {
    sid    = "SSMParameters"
    effect = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:ap-southeast-2:${data.aws_caller_identity.current.account_id}:parameter/lightrag/*"]
  }
}
```

**Phase:** Phase 1 -- Terraform IAM policy.

---

## Minor Pitfalls

Issues that cause friction, confusion, or suboptimal patterns.

---

### Pitfall 13: No Terraform Output for Critical Values

**What goes wrong:** After `terraform apply`, the developer has to manually find the Elastic IP from the AWS console, the instance ID from EC2, and the S3 bucket name. This is friction and error-prone for a portfolio project that should demonstrate IaC best practices.

**Prevention:** Add Terraform outputs for:
- `elastic_ip` -- the public IP address (for the demo curl script)
- `instance_id` -- for SSM Session Manager access
- `s3_bucket_name` -- for manual S3 verification
- `ssh_command` -- the full SSH command with key path and IP

**Phase:** Phase 1 -- Terraform outputs.

---

### Pitfall 14: Rag Storage Corruption on Power Loss

**What goes wrong:** The t3.micro is stopped abruptly (AWS maintenance event, instance failure). The rag_storage directory is in the middle of a write transaction (SQLite, HNSWLib index). On next boot, the storage is partially written and the app fails to initialize.

**Why it happens:** LightRAG uses SQLite (via a KV store) and HNSWLib for the vector index. Both require graceful shutdown to flush writes. Docker Compose restart or abrupt instance stop does not guarantee `docker compose down` runs first.

**Consequences:**
- App fails to start with SQLite `database is locked` or `database is corrupted` errors
- Requires manual S3 restore and re-indexing
- Demo fails

**Prevention:**
1. **Configure Docker Compose `stop_grace_period`:** Add `stop_grace_period: 30s` to the service. This gives the FastAPI app time to flush writes before Docker sends SIGKILL.
2. **Systemd shutdown unit (already planned):** Ensure the shutdown unit runs `docker compose down` (not just `docker compose stop`) to allow graceful SIGTERM to flush writes.
3. **SQLite WAL mode:** LightRAG likely uses WAL mode by default (resilient to crashes), but verify this in the upstream source.
4. **Startup restore check:** If rag_storage fails to initialize (app crash on startup), the startup script should offer to restore from S3 and restart.

**Phase:** Phase 1 -- Docker Compose override and systemd unit.

---

### Pitfall 15: Terraform Provider Version Mismatch

**What goes wrong:** `terraform init` fails with "provider version constraint unsatisfied" because the existing projects use `~> 5.0` (AWS provider v5) but the spec requires v6+ (for terraform-aws-modules/eks compatibility). The portfolio mix of v5 and v6 projects could cause `terraform init` failures if the lock file isn't managed per-project.

**Why it happens:** `ec2-static-site` uses `~> 5.0`. `blue-green-deployment` and `multi-container-service` use `~> 5.0`. The `eks-cluster-from-scratch` project uses v6 (per the CLAUDE.md). Mixing providers in the same working directory can cause lock file conflicts if `required_providers` versions differ.

**Consequences:**
- `terraform init` fails on a fresh clone
- Provider version upgrade requires `terraform init -upgrade` which may change lock files
- State format differences between v5 and v6

**Prevention:**
- Use `terraform {
    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }
  }` consistently within this project (LightRAG uses EC2, not EKS Auto Mode or new EKS features)
- Document that this project stays on AWS provider v5 for consistency with the existing portfolio (EC2-only project does not need v6 features)
- The EKS cluster project can stay on v6 independently

**Phase:** Phase 1 -- Terraform provider configuration.

---

## Phase-Specific Warnings

| Phase | Critical Pitfall | Mitigation |
|-------|-----------------|------------|
| Phase 1 (IaC) | Memory exhaustion (Pitfall 1) | Docker memory limits in compose override from day 1 |
| Phase 1 (IaC) | IAM over-permission (Pitfall 12) | Least-privilege S3 policy scoped to graph bucket only |
| Phase 1 (IaC) | Remote state not configured (Pitfall 6) | S3 backend from the first Terraform file |
| Phase 1 (IaC) | EIP billing trap (Pitfall 9) | README warning with exact CLI commands |
| Phase 1 (user_data) | SSM not available at startup (Pitfall 3) | Validation script before docker compose up |
| Phase 1 (user_data) | Non-idempotent user_data (Pitfall 2) | Bootstrap flag file pattern |
| Phase 1 (user_data) | S3 sync race condition (Pitfall 4) | flock-based locking in cron and shutdown hook |
| Phase 1 (user_data) | Docker image pull failure (Pitfall 10) | Digest-pinned image or local tag |
| Phase 2 (CI/CD) | Missing concurrency control (Pitfall 11) | `concurrency: cancel-in-progress: true` |
| Phase 2 (CI/CD) | Health check false positive (Pitfall 5) | App-level health check with start_period |
| Phase 2 (Tests) | Embedding model inconsistency (Pitfall 7) | Model config hash validation in startup |
| Any phase | SSH open to world (Pitfall 8) | Prefer SSM Session Manager; restrict port 22 |
| Any phase | Rag storage corruption (Pitfall 14) | stop_grace_period, graceful shutdown in systemd unit |

---

## Cross-Reference: Gaps Requiring Deeper Research

| Topic | Why Unresolved | Phase to Investigate |
|-------|---------------|---------------------|
| GHCR rate limits for unauthenticated pulls | WebSearch unavailable; no confirmed GHCR policy docs | Phase 1 (user_data) |
| Docker Compose `--wait` flag availability on Ubuntu 24.04 Docker package | Need to verify Docker Engine version in Ubuntu 24.04 LTS AMIs | Phase 1 (user_data) |
| flock availability on Ubuntu 24.04 minimal | Need to verify util-linux package is in base AMI | Phase 1 (user_data) |
| AWS EBS vs instance store for rag_storage persistence | Project uses S3-based persistence; EBS CSI not needed but EBS volume could be alternative | Phase 1 (IaC) |
| SSM Session Manager agent on Ubuntu 24.04 | Needed to eliminate port 22 (Pitfall 8 mitigation) | Phase 1 (IaC) |
| LightRAG default SQLite WAL mode | Determines crash-resilience of rag_storage (Pitfall 14) | Phase 2 (testing) |

---

## Sources

**LightRAG upstream (HIGH confidence):**
- Docker Compose config: `ghcr.io/hkuds/lightrag` upstream repo -- no memory limits, no health check defined
- CLAUDE.md: embedding model consistency requirement, initialization requirement, Ollama context window warning
- env.example: all configurable environment variables

**Portfolio patterns (HIGH confidence):**
- `ec2-static-site/terraform/` -- Terraform module structure, user_data pattern, security group (SSH open to 0.0.0.0/0)
- `blue-green-deployment/.github/workflows/deploy.yml` -- concurrency control (`cancel-in-progress`), blue-green locking pattern
- `multi-container-service/docker-compose.yml` -- `depends_on` with health check, `restart: unless-stopped`
- `multi-container-service/.github/workflows/deploy.yml` -- OIDC vs long-lived AWS credentials pattern

**First-principles reasoning (MEDIUM confidence -- flag for validation):**
- t3.micro memory math (1 GiB RAM + 2 GiB swap, ~750 MiB Docker overhead, ~400-800 MiB FastAPI/embedding peak)
- S3 sync race condition (cron + shutdown hook simultaneous execution)
- SSM parameter availability window (IAM role propagation delay)
- GHCR unauthenticated pull rate limits
- Elastic IP billing for stopped instances

**Things I could not verify (LOW confidence -- recommend validation during Phase 1):**
- Exact memory consumption of LightRAG container under indexing load (varies with corpus size)
- Ubuntu 24.04 LTS AMI ID for ap-southeast-2 (must be verified at apply time)
- Whether `amazon-ssm-agent` is pre-installed on Ubuntu AMIs
- Whether the `flock` command is available in the base Ubuntu 24.04 AMI
