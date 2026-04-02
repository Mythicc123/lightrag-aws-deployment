#!/bin/bash
# LightRAG EC2 Bootstrap Script
# Runs on first boot via cloud-init user_data.
# Idempotent: skips full bootstrap if /var/lib/lightrag/.bootstrapped exists.
#
# S3 bucket name is computed from instance metadata at boot time:
#   ${project_name}-graph-storage-<aws_account_id>
# This avoids templatefile() conflicts with bash variable syntax.
set -euo pipefail

LOGFILE="/var/log/lightrag-bootstrap.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== LightRAG Bootstrap START $(date -u) ==="

# ─── BOOT-07: Idempotency ─────────────────────────────────────────────────────
if [ -f /var/lib/lightrag/.bootstrapped ]; then
  echo "[BOOT-07] Bootstrap flag found. Ensuring Docker Compose is running..."
  if command -v docker >/dev/null 2>&1; then
    cd /opt/lightrag 2>/dev/null && docker compose up -d 2>/dev/null || true
  fi
  echo "=== LightRAG Bootstrap SKIPPED (already bootstrapped) ==="
  exit 0
fi

# ─── BOOT-01: Swap File ────────────────────────────────────────────────────────
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

if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

sysctl vm.swappiness=60 2>/dev/null || true

# ─── BOOT-02: Docker Install ──────────────────────────────────────────────────
echo "[BOOT-02] Installing Docker, Docker Compose v2, and awscli..."

apt-get update -y
apt-get install -y docker.io docker-compose-v2 awscli curl jq

systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# ─── Determine S3 bucket name ─────────────────────────────────────────────────
# Bucket naming: lightrag-graph-storage-<AWS_ACCOUNT_ID>
# Use awscli (already installed above) to get account ID without jq dependency.
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
PROJECT_NAME="lightrag"
S3_BUCKET_NAME="${PROJECT_NAME}-graph-storage-${AWS_ACCOUNT_ID}"
echo "[INFO] S3 bucket name: ${S3_BUCKET_NAME}"

# ─── Create directories ─────────────────────────────────────────────────────────
echo "Creating application directories..."
mkdir -p /opt/lightrag/scripts /opt/lightrag/systemd /opt/lightrag/data /var/lib/lightrag /var/lock/lightrag

# ─── BOOT-03: Clone LightRAG Repo ─────────────────────────────────────────────
echo "[BOOT-03] Cloning LightRAG repository..."

if [ -d /opt/lightrag/.git ]; then
  echo "[BOOT-03] LightRAG repo already exists at /opt/lightrag, skipping clone."
else
  git clone https://github.com/HKUDS/LightRAG.git /opt/lightrag
fi

# ─── BOOT-04: Restore rag_storage from S3 ──────────────────────────────────────
echo "[BOOT-04] Restoring rag_storage from S3 bucket: ${S3_BUCKET_NAME}..."

aws s3 sync "s3://${S3_BUCKET_NAME}/rag_storage/" /opt/lightrag/data/rag_storage/ || true

# ─── BOOT-05: Load Secrets from SSM Parameter Store ───────────────────────────
echo "[BOOT-05] Loading secrets from SSM Parameter Store..."

ssm_get_with_retry() {
  local param_name="$1"
  local result=""
  for attempt in 1 2 3; do
    result=$(aws ssm get-parameter --name "$param_name" --with-decryption --output json 2>/dev/null | jq -r '.Parameter.Value' || true)
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

OPENAI_API_KEY=$(ssm_get_with_retry "/lightrag/OPENAI_API_KEY")
LIGHTRAG_API_KEY=$(ssm_get_with_retry "/lightrag/LIGHTRAG_API_KEY")

if [ -z "$OPENAI_API_KEY" ] || [ -z "$LIGHTRAG_API_KEY" ]; then
  echo "[BOOT-05] WARNING: One or more API keys missing from SSM Parameter Store."
  echo "[BOOT-05] Ensure the following SSM parameters exist:"
  echo "  - /lightrag/OPENAI_API_KEY"
  echo "  - /lightrag/LIGHTRAG_API_KEY"
  echo "[BOOT-05] LightRAG will show auth errors but not crash. Fix keys and restart."
fi

cat > /opt/lightrag/.env << 'ENVEOF'
OPENAI_API_KEY=OPENAI_API_KEY_PLACEHOLDER
LIGHTRAG_API_KEY=LIGHTRAG_API_KEY_PLACEHOLDER
HOST=0.0.0.0
PORT=9621
ENVEOF

# Replace placeholder tokens with actual SSM-loaded values
sed -i "s/OPENAI_API_KEY_PLACEHOLDER/$OPENAI_API_KEY/g" /opt/lightrag/.env
sed -i "s/LIGHTRAG_API_KEY_PLACEHOLDER/$LIGHTRAG_API_KEY/g" /opt/lightrag/.env
chmod 600 /opt/lightrag/.env
echo "[BOOT-05] Secrets written to /opt/lightrag/.env"

# ─── BOOT-06 / PERS-01 / PERS-02: Sync scripts, systemd unit, Docker Compose override ────

# PERS-01: S3 sync script with flock locking
cat > /usr/local/bin/sync-rag-storage.sh << 'SYNCEOF'
#!/bin/bash
set -euo pipefail
LOCK_FILE="/var/lock/lightrag-s3-sync.lock"
SOURCE_DIR="/opt/lightrag/data/rag_storage"
S3_BUCKET=""
if [ -n "${1:-}" ]; then
  S3_BUCKET="$1"
elif [ -n "${LIGHTRAG_S3_BUCKET:-}" ]; then
  S3_BUCKET="$LIGHTRAG_S3_BUCKET"
else
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
  S3_BUCKET="lightrag-graph-storage-${AWS_ACCOUNT_ID}"
fi
if [ -z "$S3_BUCKET" ]; then
  echo "$(date -u) ERROR: S3 bucket not determined." >&2
  exit 1
fi
exec flock -n "$LOCK_FILE" -c "
  echo \"$(date -u) INFO: Starting S3 sync: $SOURCE_DIR -> s3://$S3_BUCKET/rag_storage/\"
  aws s3 sync \"$SOURCE_DIR/\" \"s3://$S3_BUCKET/rag_storage/\" --delete
  echo \"$(date -u) INFO: S3 sync complete\"
" || {
  echo "$(date -u) INFO: Sync skipped (lock held by another process)"
  exit 0
}
SYNCEOF
chmod +x /usr/local/bin/sync-rag-storage.sh

# Copy sync script into the LightRAG directory structure for reference
mkdir -p /opt/lightrag/scripts
cp /usr/local/bin/sync-rag-storage.sh /opt/lightrag/scripts/sync-rag-storage.sh

# PERS-02: systemd shutdown unit
cat > /etc/systemd/system/docker-rag-sync.service << 'SYSEOF'
[Unit]
Description=LightRAG rag_storage S3 Sync on Shutdown
Documentation=https://github.com/HKUDS/LightRAG

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/sync-rag-storage.sh
Requires=docker.service
After=docker.service

[Install]
WantedBy=multi-user.target
SYSEOF

# Copy systemd unit into the LightRAG directory structure for reference
mkdir -p /opt/lightrag/systemd
cp /etc/systemd/system/docker-rag-sync.service /opt/lightrag/systemd/docker-rag-sync.service

systemctl daemon-reload
systemctl enable docker-rag-sync.service 2>/dev/null || true

# Install cron job: every 15 minutes, sync rag_storage to S3
echo "*/15 * * * * root /usr/local/bin/sync-rag-storage.sh >> /var/log/lightrag-s3-sync.log 2>&1" > /etc/cron.d/lightrag-s3-sync
chmod 0644 /etc/cron.d/lightrag-s3-sync

# PERS-03: Docker Compose override (750m memory limit + health check)
cat > /opt/lightrag/docker-compose.override.yml << 'COMPOSEEOF'
services:
  lightrag:
    restart: unless-stopped
    stop_grace_period: 30s
    deploy:
      resources:
        limits:
          memory: 750m
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9621/health"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    environment:
      LLM_BINDING: "openai"
      LLM_MODEL: "gpt-4o-mini"
      LLM_BINDING_HOST: "https://api.openai.com/v1"
      LLM_BINDING_API_KEY: "${OPENAI_API_KEY}"
      MODEL_LIST: "gpt-4o-mini"
      EMBEDDING_BINDING: "openai"
      EMBEDDING_MODEL: "text-embedding-3-large"
      EMBEDDING_DIM: "3072"
      EMBEDDING_BINDING_API_KEY: "${OPENAI_API_KEY}"
      LIGHTRAG_API_KEY: "${LIGHTRAG_API_KEY}"
COMPOSEEOF

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
echo "$(date -u)" > /var/lib/lightrag/.bootstrapped

echo "=== LightRAG Bootstrap COMPLETE $(date -u) ==="
echo "Endpoint: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'EIP'):9621"
