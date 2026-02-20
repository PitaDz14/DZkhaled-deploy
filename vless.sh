#!/usr/bin/env bash
set -euo pipefail

# =========================
# Logging & Error Handling
# =========================
LOG_FILE="/tmp/vless_$(date +%s).log"
touch "$LOG_FILE"

trap 'echo "[ERROR] Failed at line $LINENO"; exit 1' ERR

# =========================
# Colors (optional)
# =========================
if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; CYAN=$'\e[36m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
  GREEN= RED= CYAN= YELLOW= RESET=
fi

log_info(){ echo -e "${CYAN}[INFO] $1${RESET}"; }
log_ok(){ echo -e "${GREEN}[OK] $1${RESET}"; }
log_warn(){ echo -e "${YELLOW}[WARN] $1${RESET}"; }
log_err(){ echo -e "${RED}[ERR] $1${RESET}"; }

# =========================
# Ensure interactive input
# =========================
if [[ ! -t 0 && -e /dev/tty ]]; then
  exec </dev/tty
fi

# =========================
# Telegram (Optional)
# =========================
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_IDS="${TELEGRAM_CHAT_IDS:-}"

read -rp "Telegram Bot Token (optional): " _tk || true
[[ -n "${_tk:-}" ]] && TELEGRAM_TOKEN="$_tk"

read -rp "Chat ID(s) (comma-separated, optional): " _ids || true
[[ -n "${_ids:-}" ]] && TELEGRAM_CHAT_IDS="${_ids// /}"

IFS=',' read -r -a CHAT_IDS <<< "${TELEGRAM_CHAT_IDS:-}" || true

send_telegram(){
  local msg="$1"
  if [[ -z "${TELEGRAM_TOKEN}" || ${#CHAT_IDS[@]} -eq 0 ]]; then return; fi
  for id in "${CHAT_IDS[@]}"; do
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${id}" \
      --data-urlencode "text=${msg}" >>"$LOG_FILE" 2>&1
  done
}

# =========================
# Validate Environment
# =========================
if ! command -v gcloud >/dev/null 2>&1; then
  log_err "gcloud CLI not installed"
  exit 1
fi

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "$PROJECT" ]]; then
  log_err "No active GCP project"
  exit 1
fi

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

log_ok "Project: $PROJECT"

# =========================
# Configuration
# =========================
read -rp "Service name [default: vless-service]: " SERVICE
SERVICE="${SERVICE:-vless-service}"

read -rp "Region [default: us-central1]: " REGION
REGION="${REGION:-us-central1}"

read -rp "CPU cores [default: 2]: " CPU
CPU="${CPU:-2}"

read -rp "Memory (e.g. 2Gi) [default: 2Gi]: " MEMORY
MEMORY="${MEMORY:-2Gi}"

# 🔥 الجديد: إدخال الهوست
echo ""
log_info "Enter SNI/Host (example: youtube.com, cloudflare.com)"
read -rp "Host [default: youtube.com]: " CUSTOM_HOST
CUSTOM_HOST="${CUSTOM_HOST:-youtube.com}"

if [[ -z "$CUSTOM_HOST" ]]; then
  log_err "Host cannot be empty"
  exit 1
fi

PORT="8080"
TIMEOUT="3600"
IMAGE="docker.io/nkka404/vless-ws:latest"

# =========================
# Generate UUID
# =========================
if command -v uuidgen >/dev/null 2>&1; then
  UUID="$(uuidgen)"
else
  UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

log_info "Generated UUID: $UUID"

# =========================
# Enable APIs
# =========================
log_info "Enabling required services..."
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet >>"$LOG_FILE" 2>&1

# =========================
# Deploy
# =========================
log_info "Deploying service..."

gcloud run deploy "$SERVICE" \
  --image="$IMAGE" \
  --platform=managed \
  --region="$REGION" \
  --memory="$MEMORY" \
  --cpu="$CPU" \
  --timeout="$TIMEOUT" \
  --allow-unauthenticated \
  --port="$PORT" \
  --quiet >>"$LOG_FILE" 2>&1

# =========================
# Output
# =========================
HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
URL="https://${HOST}"

VLESS_URI="vless://${UUID}@${CUSTOM_HOST}:443?type=ws&security=tls&host=${HOST}&path=%2F"

echo ""
log_ok "Deployment completed successfully"
echo "----------------------------------------"
echo "Service URL:"
echo "$URL"
echo ""
echo "VLESS Configuration:"
echo "$VLESS_URI"
echo "----------------------------------------"

# =========================
# Telegram Notification
# =========================
send_telegram "Deployment successful: $URL"

log_ok "Done"