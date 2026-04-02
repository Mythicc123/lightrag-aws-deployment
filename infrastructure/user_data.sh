#!/bin/bash
# LightRAG EC2 Bootstrap Script
# Runs on first boot via cloud-init user_data.
# Idempotent: skips full bootstrap if /var/lib/lightrag/.bootstrapped exists.
#
# Expected variables (passed via Terraform templatefile):
#   s3_bucket_name  - S3 bucket for rag_storage/ persistence
set -euo pipefail

LOGFILE="/var/log/lightrag-bootstrap.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== LightRAG Bootstrap START $(date -u) ==="

# ─── BOOT-07: Idempotency ─────────────────────────────────────────────────────
# Skip full bootstrap if already done (e.g., instance restart).
if [ -f /var/lib/lightrag/.bootstrapped ]; then
  echo "[BOOT-07] Bootstrap flag found. Ensuring Docker Compose is running..."
  if command -v docker >/dev/null 2>&1; then
    cd /opt/lightrag 2>/dev/null && docker compose up -d 2>/dev/null || true
  fi
  echo "=== LightRAG Bootstrap SKIPPED (already bootstrapped) ==="
  exit 0
fi

# ─── BOOT-01: Swap File ────────────────────────────────────────────────────────
# t3.micro has 1GB RAM. Create 2GB swap to run LightRAG (Python + model overhead).
echo "[BOOT-01] Setting up 2GB swap file..."

if swapon --show | grep -q /swapfile; then
  echo "[BOOT-01] Swap already enabled, skipping."
else
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  else
    dd if=/dev/zero of=/swapfile bs=1M count=2048
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi

# Add to /etc/fstab if not already present
if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# Enable swappiness for LightRAG workloads
sysctl vm.swappiness=60 2>/dev/null || true

# ─── BOOT-02: Docker Install ──────────────────────────────────────────────────
echo "[BOOT-02] Installing Docker, Docker Compose v2, and awscli..."

apt-get update -y
apt-get install -y docker.io docker-compose-v2 awscli curl

systemctl start docker
systemctl enable docker

# Allow ubuntu user to access Docker socket
usermod -aG docker ubuntu

# ─── Create directories ─────────────────────────────────────────────────────────
echo "Creating application directories..."
mkdir -p /opt/lightrag /var/lib/lightrag /var/lock/lightrag

# ─── BOOT-03: Clone LightRAG Repo ─────────────────────────────────────────────
# Only clone if not already present (idempotent).
echo "[BOOT-03] Cloning LightRAG repository..."

if [ -d /opt/lightrag/.git ]; then
  echo "[BOOT-03] LightRAG repo already exists at /opt/lightrag, skipping clone."
else
  git clone https://github.com/HKUDS/LightRAG.git /opt/lightrag
fi

# ─── BOOT-04: Restore rag_storage from S3 ──────────────────────────────────────
# If rag_storage/ exists in S3, restore it to the host.
# If S3 is empty (first boot), this gracefully does nothing.
echo "[BOOT-04] Restoring rag_storage from S3 bucket: ${s3_bucket_name}..."

mkdir -p /opt/lightrag/data
aws s3 sync "s3://${s3_bucket_name}/rag_storage/" /opt/lightrag/data/rag_storage/ || true

# ─── BOOT-05: Load Secrets from SSM Parameter Store ───────────────────────────
# Fetch API keys from SSM and write /opt/lightrag/.env.
# All secrets loaded at runtime — none hardcoded.
echo "[BOOT-05] Loading secrets from SSM Parameter Store..."

# Retry helper: retry up to 3 times with 5-second backoff.
ssm_get_with_retry() {
  local param_name="$1"
  local result=""
  for attempt in 1 2 3; do
    result=$(aws ssm get-parameter --name "$param_name" --with-decryption --output text --query Parameter.Value 2>/dev/null || true)
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
    echo "[SSM] Attempt $attempt failed for $param_name, retrying in 5s..."
    sleep 5
  done
  echo ""
  return 1
}

ANTHROPIC_API_KEY=$(ssm_get_with_retry "/lightrag/ANTHROPIC_API_KEY")
OPENAI_API_KEY=$(ssm_get_with_retry "/lightrag/OPENAI_API_KEY")
LIGHTRAG_API_KEY=$(ssm_get_with_retry "/lightrag/LIGHTRAG_API_KEY")

# Validate all three keys are non-empty
if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$OPENAI_API_KEY" ] || [ -z "$LIGHTRAG_API_KEY" ]; then
  echo "[BOOT-05] WARNING: One or more API keys missing from SSM Parameter Store."
  echo "[BOOT-05] Ensure the following SSM parameters exist:"
  echo "  - /lightrag/ANTHROPIC_API_KEY"
  echo "  - /lightrag/OPENAI_API_KEY"
  echo "  - /lightrag/LIGHTRAG_API_KEY"
  echo "[BOOT-05] LightRAG will show auth errors but not crash. Fix keys and restart."
fi

# Write .env file with loaded secrets and LightRAG configuration.
cat > /opt/lightrag/.env << EOF
# LightRAG Environment Variables
# Loaded from SSM Parameter Store at bootstrap time
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY}
MODEL=claude-sonnet-3-7-20250619
MODEL_LIST=claude-haiku-3-5-20250514
EMBEDDING_MODEL=text-embedding-3-large
EMBEDDING_DIM=3072
HOST=0.0.0.0
PORT=9621
EOF

chmod 600 /opt/lightrag/.env
echo "[BOOT-05] Secrets written to /opt/lightrag/.env"

# ─── BOOT-06: Copy sync script, systemd unit, and Docker Compose override ────────
echo "[BOOT-06] Setting up sync scripts and Docker Compose override..."

# Copy S3 sync script to /usr/local/bin
cp /opt/lightrag/scripts/sync-rag-storage.sh /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/sync-rag-storage.sh

# Copy systemd shutdown unit
cp /opt/lightrag/systemd/docker-rag-sync.service /etc/systemd/system/ 2>/dev/null || true

systemctl daemon-reload
systemctl enable docker-rag-sync.service 2>/dev/null || true

# Install cron job for periodic S3 sync (every 15 minutes)
mkdir -p /etc/cron.d
echo "*/15 * * * * root /usr/local/bin/sync-rag-storage.sh >> /var/log/lightrag-s3-sync.log 2>&1" > /etc/cron.d/lightrag-s3-sync
chmod 0644 /etc/cron.d/lightrag-s3-sync

# Copy Docker Compose override (750m memory limit + health check)
cp /opt/lightrag/docker-compose.override.yml /opt/lightrag/docker-compose.override.yml 2>/dev/null || true

# ─── BOOT-06: Docker Compose Up ────────────────────────────────────────────────
echo "[BOOT-06] Starting LightRAG containers via Docker Compose..."

cd /opt/lightrag
docker compose up -d

# Wait for container to be healthy (up to 90 seconds)
echo "[BOOT-06] Waiting for LightRAG to become healthy..."
HEALTHY=false
for i in $(seq 1 18); do
  sleep 5
  if curl -sf http://localhost:9621/health >/dev/null 2>&1; then
    echo "[BOOT-06] LightRAG is healthy!"
    HEALTHY=true
    break
  fi
  echo "[BOOT-06] Waiting... ($i/18)"
done

if [ "$HEALTHY" = "false" ]; then
  echo "[BOOT-06] WARNING: LightRAG health check did not pass within 90 seconds."
  echo "[BOOT-06] Container may still be starting. Check: docker compose ps"
fi

# ─── Bootstrap Complete ─────────────────────────────────────────────────────────
echo "[BOOT-07] Creating bootstrap flag..."
mkdir -p /var/lib/lightrag
echo "$(date -u)" > /var/lib/lightrag/.bootstrapped

echo "=== LightRAG Bootstrap COMPLETE $(date -u) ==="
echo "Endpoint: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'EIP'):9621"
