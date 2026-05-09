# LightRAG on AWS

A production-ready deployment of [HKUDS/LightRAG](https://github.com/HKUDS/LightRAG) on AWS EC2 using Terraform infrastructure-as-code, S3-based graph persistence, AWS SSM Parameter Store for secrets management, GitHub Actions CI/CD via OIDC, and end-to-end Playwright smoke tests.

This project deploys a production-ready LightRAG RAG pipeline on AWS EC2, with Terraform IaC, GitHub Actions CI/CD, and end-to-end smoke tests.

🎬 **Demo available on request** — spins up in ~5 minutes via [GitHub Actions](https://github.com/Mythicc123/lightrag-aws-deployment/actions/workflows/portfolio.yml). Not kept running 24/7 to minimise AWS costs (~$0.01/month at rest).

## Architecture

```
+----------------------------------------------------------------------+
|                          AWS Cloud (ap-southeast-2)                   |
|                                                                      |
|  +-----------------------------+                                    |
|  |         GitHub Repository    |                                    |
|  |  mythicc123/lightrag-aws-   |                                    |
|  |  deployment                 |                                    |
|  |                             |                                    |
|  |  +----------------------+   |    OIDC Web Identity               |
|  |  |   GitHub Actions     +---+----------------------------------+|
|  |  |   .github/workflows/  |   |                                  ||
|  |  |      deploy.yml       |   |                                  ||
|  |  +----------------------+   |                                  ||
|  +-----------------------------+    |                                  ||
|                                      |    sts:AssumeRoleWithWebIdentity |
|                                      v                                  |
|                              +----------------+                         |
|                              |  IAM Role       |                         |
|                              |  mythicc123     |                         |
|                              |  (GitHub OIDC)  |                         |
|                              +----------------+                         |
|                                      |                                  |
|                                      | SSH (appleboy/ssh-action)        |
|                                      v                                  |
|  +----------------------------------------------------------+         |
|  |                    EC2 Instance (t3.micro, Ubuntu 24.04)  |         |
|  |                                                         |         |
|  |   Port 22 (SSH)    Port 443 (HTTPS)    Port 9621       |         |
|  |   deploy only      future TLS           API + WebUI     |         |
|  |                                                         |         |
|  |   +----------------------------------------------+     |         |
|  |   |              Docker Container                 |     |         |
|  |   |   ghcr.io/hkuds/lightrag  (750m memory)    |     |         |
|  |   |                                               |     |         |
|  |   |   /opt/lightrag/data/rag_storage/  <->      |     |         |
|  |   |   /opt/lightrag/data/inputs/                |     |         |
|  |   +----------------------------------------------+     |         |
|  |                                                         |         |
|  |   +----------+  +------------+  +------------------+   |         |
|  |   |  SSM     |  |  cron job  |  |  systemd        |   |         |
|  |   | Parameter|  |  */15 * * *|  |  shutdown hook  |   |         |
|  |   | Store    |  +------------+  +------------------+   |         |
|  |   | /lightrag|                                             |         |
|  |   +----------+                                             |         |
|  +-----------------------------------------------------------+         |
|        |                                                            |
|        | (IAM Instance Profile: ec2:GetParameter, s3:Get/PutObject)  |
|        v                                                            |
|  +----------------+              +-----------------------------+   |
|  |  SSM Parameter  |              |  S3 Bucket (Graph)          |   |
|  |  Store          |              |  lightrag-graph-            |   |
|  |                 |              |  storage-<ACCT_ID>         |   |
|  |  /lightrag/    |              |                             |   |
|  |  ANTHROPIC_API_|              |  rag_storage/               |   |
|  |  OPENAI_API_KEY|              +-----------------------------+   |
|  |  LIGHTRAG_API_ |                                                  |
|  |  KEY           |                                                  |
|  +----------------+                                                  |
|                                                                      |
|  Elastic IP: 54.253.108.90  (static, survives stop/start)            |
+----------------------------------------------------------------------+
```

## Prerequisites

Before deploying, ensure you have:

- **AWS account** with sufficient IAM permissions (EC2, IAM, S3, SSM Parameter Store, VPC)
- **Terraform >= 1.10** installed. [Install guide](https://developer.hashicorp.com/terraform/install)
- **Docker and Docker Compose v2** installed locally for local testing. [Install guide](https://docs.docker.com/compose/install/)
- **AWS CLI v2** configured with credentials. Run `aws configure` or set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables
- **SSH key pair** named `ec2-static-site-key` created in AWS EC2 (in the `ap-southeast-2` region). Create via AWS Console or CLI:
  ```bash
  aws ec2 create-key-pair --key-name ec2-static-site-key --query 'KeyMaterial' --output text > ~/.ssh/ec2-static-site-key.pem
  chmod 400 ~/.ssh/ec2-static-site-key.pem
  ```
- **GitHub repository** with OIDC IAM role `mythicc123` already provisioned (details in `infrastructure/oidc.tf`). The role ARN is `arn:aws:iam::255445075474:role/mythicc123`
- **SSM Parameter Store secrets** configured before deployment (see below)

## SSM Parameter Store Setup

Set up your API keys in AWS SSM Parameter Store before deploying the infrastructure. These parameters use the **Standard (free) tier**. The EC2 instance IAM role has `ssm:GetParameter` permissions scoped to `/lightrag/*` only.

```bash
# Anthropic API key for LightRAG LLM queries (claude-sonnet-3-7)
aws ssm put-parameter \
  --name "/lightrag/ANTHROPIC_API_KEY" \
  --value "sk-ant-..." \
  --type SecureString \
  --region ap-southeast-2 \
  --description "Anthropic API key for LightRAG LLM queries (claude-sonnet-3-7)"

# OpenAI API key for text-embedding-3-large embeddings
aws ssm put-parameter \
  --name "/lightrag/OPENAI_API_KEY" \
  --value "sk-..." \
  --type SecureString \
  --region ap-southeast-2 \
  --description "OpenAI API key for text-embedding-3-large embeddings"

# LightRAG API key for authenticating requests to the WebUI and REST API
aws ssm put-parameter \
  --name "/lightrag/LIGHTRAG_API_KEY" \
  --value "your-lightrag-api-key" \
  --type SecureString \
  --region ap-southeast-2 \
  --description "LightRAG API key for authenticating requests to the WebUI and REST API"
```

> **Note:** These parameters use the Standard (free) tier. The EC2 instance IAM role has `ssm:GetParameter` permissions scoped to `/lightrag/*` only.

To verify the parameters were created:

```bash
aws ssm describe-parameters --parameter-filters "Key=Path,Values=/lightrag" --region ap-southeast-2
```

## Terraform Deployment

Deploy the infrastructure from the `infrastructure/` directory. Terraform uses a remote S3 backend (bucket `mythicc-lightrag-tfstate`, key `terraform.tfstate`).

```bash
cd infrastructure

# Initialize Terraform (downloads providers, connects to S3 backend)
terraform init

# Preview the infrastructure changes
terraform plan

# Deploy the infrastructure (~5 minutes)
terraform apply

# Note the outputs: elastic_ip, endpoint_url, ssh_command, s3_bucket_name
```

### Terraform Outputs

After `terraform apply` completes, Terraform will output:

| Output | Description |
|--------|-------------|
| `elastic_ip` | Static public IP of the EC2 instance (54.253.108.90) |
| `endpoint_url` | LightRAG API/WebUI endpoint (http://54.253.108.90:9621) |
| `ssh_command` | Pre-formatted SSH command to connect to the instance |
| `s3_bucket_name` | S3 bucket name for rag_storage persistence |
| `iam_instance_profile` | IAM instance profile attached to the EC2 instance |

### Terraform Variables

Key variables (override in `infrastructure/terraform.tfvars` or with `-var` flags):

| Variable | Default | Description |
|----------|---------|-------------|
| `ssh_allowed_cidr` | `"0.0.0.0/0"` | CIDR block allowed to access SSH (port 22) and LightRAG (port 9621). Restrict to your IP in production. |
| `instance_type` | `"t3.micro"` | EC2 instance type. t3.micro is the default for cost efficiency. |
| `project_name` | `"lightrag"` | Project name used for resource naming and tagging. |

## Post-Deployment Verification

After Terraform completes, verify the deployment:

**1. Health check:**

```bash
curl http://54.253.108.90:9621/health
```

Expected response: `{"status": "ok"}` or similar HTTP 200.

**2. LightRAG WebUI:**

Open http://54.253.108.90:9621 in your browser. You should see the LightRAG WebUI. Authenticate with the `LIGHTRAG_API_KEY` you set in SSM.

**3. Check Docker container status:**

```bash
ssh -i ~/.ssh/ec2-static-site-key.pem ubuntu@54.253.108.90 "docker compose ps"
```

Expected: `lightrag` container showing status `running` and healthy.

**4. Verify SSM secrets loaded:**

```bash
ssh -i ~/.ssh/ec2-static-site-key.pem ubuntu@54.253.108.90 "cat /opt/lightrag/.env | grep -v KEY"
```

Expected: Should show `ANTHROPIC_API_KEY=`, `OPENAI_API_KEY=`, and `LIGHTRAG_API_KEY=` with values populated (not empty).

**5. Check S3 sync status:**

```bash
ssh -i ~/.ssh/ec2-static-site-key.pem ubuntu@54.253.108.90 "cat /var/log/lightrag-bootstrap.log | tail -20"
```

## Cost Breakdown

| Resource | Configuration | Monthly Cost (Approx.) |
|----------|---------------|------------------------|
| EC2 t3.micro | 750 hours, 20GB root EBS (gp3) | ~$7.50 USD |
| Elastic IP | Attached to running instance | Free (~$3.60 if stopped) |
| S3 Graph Storage | ~1GB/month (light usage) | ~$0.025 USD |
| SSM Parameter Store | 3 parameters, Standard tier | Free |
| Data Transfer | Minimal for portfolio demo | ~$0-$1.00 USD |
| **Total (running)** | | **~$7.50-10/month** |
| **Total (at rest — destroyed)** | | **~$0.01/month (S3 tfstate only)** |

### Elastic IP Billing Warning

> **Warning:** Elastic IPs are free while the associated EC2 instance is running. However, if you stop or terminate the instance while the Elastic IP is allocated, AWS charges approximately **$3.60 USD/month**. To avoid unexpected charges: either keep the instance running, or release the Elastic IP when the instance is stopped (`aws ec2 release-address --allocation-id eipalloc-xxx`).

## CI/CD Workflow

The GitHub Actions deploy workflow (`.github/workflows/deploy.yml`) automates deployments on every git tag push.

### How it works

1. **Trigger:** Workflow runs on git tags matching `v*` (e.g., `git tag v0.1.0 && git push --tags`)
2. **Authentication:** Uses OpenID Connect (OIDC) to assume the `mythicc123` IAM role. No long-lived AWS credentials are stored in GitHub Secrets.
3. **Image digest:** Fetches the current image digest from GHCR (`ghcr.io/hkuds/lightrag`) for reproducible, immutable deployments
4. **SSH deploy:** Connects to the EC2 instance via `appleboy/ssh-action` using the SSH key from `EC2_SSH_KEY` GitHub Secret
5. **Deployment steps:**
   - Pulls latest code from the GitHub repository
   - Writes `docker-compose.override.yml` with the pinned image digest, 750m memory limit, and health check
   - Pulls the pinned image: `ghcr.io/hkuds/lightrag@<digest>`
   - Restarts containers: `docker compose up -d`
   - Performs a health check against the `/health` endpoint

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `EC2_SSH_KEY` | Contents of the `ec2-static-site-key.pem` private key. Paste the full file contents including `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`. |

### Trigger a deployment

```bash
# Make changes to the repository
git add .
git commit -m "Update configuration"
git tag v0.1.0
git push origin master --tags
```

## Demo

A complete walkthrough demonstrating the full LightRAG workflow: ingest a document, poll for completion, and query in hybrid mode.

```bash
#!/bin/bash
# LightRAG Demo: ingest text -> poll -> query
# Target: http://54.253.108.90:9621

ENDPOINT="http://54.253.108.90:9621"
API_KEY="${LIGHTRAG_API_KEY:-}"  # Set this env var or replace with your key
HEADERS=(-H "x-api-key: ${API_KEY}" -H "Content-Type: application/json")

# Step 1: Health check
echo "=== Health Check ==="
curl -s "${HEADERS[@]}" "${ENDPOINT}/health"
echo ""

# Step 2: Ingest a document about Sydney
echo "=== Ingesting Document ==="
RESPONSE=$(curl -s -X POST "${ENDPOINT}/documents/insert" \
  "${HEADERS[@]}" \
  -d '{
    "text": "The Sydney Harbour Bridge is an iconic Australian landmark connecting the city of Sydney to the North Shore. It was opened in 1932 and spans 504 metres across the harbour. The bridge is made of steel and features a distinctive arch design."
  }')
echo "$RESPONSE"
TASK_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task_id','') or json.load(sys.stdin).get('data',{}).get('task_id',''))" 2>/dev/null)
echo "Task ID: ${TASK_ID}"

# Step 3: Poll until ingestion completes (max 60 seconds)
echo "=== Polling for Completion ==="
for i in $(seq 1 12); do
  sleep 5
  STATUS=$(curl -s "${ENDPOINT}/documents/status?task_id=${TASK_ID}" "${HEADERS[@]}" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null)
  echo "Poll ${i}: ${STATUS}"
  if echo "$STATUS" | grep -qiE "completed|done|success"; then
    if ! echo "$STATUS" | grep -qiE "pending|processing"; then
      echo "Ingestion complete!"
      break
    fi
  fi
done

# Step 4: Query in hybrid mode
echo "=== Query (Hybrid Mode) ==="
curl -s -X POST "${ENDPOINT}/query" \
  "${HEADERS[@]}" \
  -d '{
    "query": "Tell me about the Sydney Harbour Bridge",
    "mode": "hybrid"
  }' | python3 -m json.tool
```

## Project Structure

```
lightrag-aws-deployment/
  .github/
    workflows/
      deploy.yml           # GitHub Actions CI/CD deploy pipeline
  infrastructure/
    main.tf                # EC2, IAM, S3, Security Group resources
    outputs.tf             # Terraform outputs (EIP, endpoint, SSH cmd)
    variables.tf           # Terraform variables
    provider.tf            # AWS provider configuration
    backend.tf             # S3 remote state backend
    oidc.tf                # GitHub Actions OIDC IAM role
    user_data.sh           # EC2 bootstrap script (Docker, SSM, S3 restore)
    terraform.tfvars       # (create this) Variable values for terraform apply
  tests/
    smoke_test.py          # Playwright E2E smoke tests
    requirements.txt       # Python test dependencies
  .gitignore               # Excludes .env, rag_storage/, .terraform/, *.tfstate
  README.md                # This file
  docker-compose.override.yml  # (generated on EC2) Memory limit + health check
```

## Teardown

To destroy all resources created by Terraform:

```bash
cd infrastructure
terraform destroy
```

> **Warning:** Terraform will destroy the S3 bucket and Elastic IP. Ensure rag_storage/ data has been backed up to S3 before running destroy. The cron job (`*/15 * * * *`) syncs rag_storage/ to S3 every 15 minutes, and the systemd shutdown hook syncs on instance stop.

To manually sync before teardown:

```bash
ssh -i ~/.ssh/ec2-static-site-key.pem ubuntu@54.253.108.90 "sudo /usr/local/bin/sync-rag-storage.sh"
```

## Configuration Reference

### LightRAG Environment Variables

The following variables are loaded from SSM Parameter Store into `/opt/lightrag/.env` at boot:

| Variable | Value | Description |
|----------|-------|-------------|
| `ANTHROPIC_API_KEY` | From SSM `/lightrag/ANTHROPIC_API_KEY` | Anthropic API key for LLM queries |
| `OPENAI_API_KEY` | From SSM `/lightrag/OPENAI_API_KEY` | OpenAI API key for text embeddings |
| `LIGHTRAG_API_KEY` | From SSM `/lightrag/LIGHTRAG_API_KEY` | LightRAG API key for WebUI/REST authentication |
| `MODEL` | `claude-sonnet-3-7-20250619` | Claude model for query operations |
| `MODEL_LIST` | `claude-haiku-3-5-20250514` | Claude model for indexing operations |
| `EMBEDDING_MODEL` | `text-embedding-3-large` | OpenAI embedding model |
| `EMBEDDING_DIM` | `3072` | Embedding dimension (text-embedding-3-large) |
| `HOST` | `0.0.0.0` | Host to bind the LightRAG server |
| `PORT` | `9621` | Port for LightRAG API and WebUI |

### Terraform State

Terraform state is stored remotely in S3 (bucket: `mythicc-lightrag-tfstate`, key: `terraform.tfstate`). No local `.tfstate` files are created.
