#!/bin/bash
# LightRAG S3 Sync Script
# Syncs /opt/lightrag/data/rag_storage/ to S3 for persistence across instance lifecycle.
# Used by: cron job (every 15 min) + systemd shutdown unit.
# Uses flock for non-blocking lock to prevent concurrent syncs.
set -euo pipefail

LOCK_FILE="/var/lock/lightrag-s3-sync.lock"
SOURCE_DIR="/opt/lightrag/data/rag_storage"
LOG_FILE="/var/log/lightrag-s3-sync.log"

# S3 bucket is passed as first argument or read from environment
S3_BUCKET="${1:-${LIGHTRAG_S3_BUCKET:-}}"

if [ -z "$S3_BUCKET" ]; then
  echo "$(date -u) ERROR: S3 bucket not specified. Set LIGHTRAG_S3_BUCKET env var or pass as argument." >&2
  exit 1
fi

# Non-blocking flock: skip if another sync is already running.
# Exit 0 always so cron does not report errors on skipped runs.
exec flock -n "$LOCK_FILE" -c "
  echo \"\$(date -u) INFO: Starting S3 sync: $SOURCE_DIR -> s3://$S3_BUCKET/rag_storage/\"
  aws s3 sync \"$SOURCE_DIR/\" \"s3://$S3_BUCKET/rag_storage/\" --delete
  echo \"\$(date -u) INFO: S3 sync complete\"
" || {
  echo "$(date -u) INFO: Sync skipped (lock held by another process)"
  exit 0
}
