#!/usr/bin/env bash
set -euo pipefail

# =========================
# Logging & Error Handling
# =========================
LOG_FILE="/tmp/vless_$(date +%s).log"
touch "$LOG_FILE"

trap 'echo "[ERROR] Failed at line $LINENO"; exit 1' ERR

# =========================
# Colors
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
# Input Fix
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

read -rp "Chat ID(s) (optional, comma-separated): " _ids || true
[[ -n "${_ids:-}" ]] && TELEGRAM_CHAT_IDS="${_ids// /}"

IFS=',' read -r -a CHAT_IDS <<< "${TELEGRAM_CHAT_IDS:-}" || true

send_telegram(){
  local msg="$1"
  [[ -z "$TELEGRAM_TOKEN" || ${#CHAT_IDS[@]} -eq 0 ]] && return
  for id in "${CHAT_IDS[@]}"; do
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${id}" \
      --data-urlencode "text=${msg}" >>"$LOG_FILE" 2>&1
  done
}

# =========================
# GCP Check
# =========================
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

if [[ -z "$PROJECT" ]]; then
  log_err "No active GCP project"
  exit 1
fi

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

log_ok "Project: $PROJECT"

# =========================
# Config
# =========================
read -rp "Service name [default: vless-service]: " SERVICE
SERVICE="${SERVICE:-vless-service}"

read -rp "Region [default: us-central1]: " REGION
REGION="${REGION:-us-central1}"

read -rp "CPU [default: 2]: " CPU
CPU="${CPU:-2}"

read -rp "Memory [default: 2Gi]: " MEMORY
MEMORY="${MEMORY:-2Gi}"

read -rp "Host/SNI [default: youtube.com]: " HOST
HOST="${HOST:-youtube.com}"

PORT="8080"
TIMEOUT="3600"
IMAGE="docker.io/nkka404/vless-ws:latest"

# =========================
# UUID
# =========================
UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

log_info "UUID generated"

# =========================
# Enable APIs
# =========================
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet >>"$LOG_FILE" 2>&1

# =========================
# Deploy
# =========================
log_info "Deploying..."

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
SERVICE_URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)' 2>/dev/null)"

if [[ -z "$SERVICE_URL" ]]; then
  SERVICE_URL="https://${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
fi

VLESS_URI="vless://${UUID}@${HOST}:443?type=ws&security=tls&host=${SERVICE_URL#https://}&path=%2F"

echo ""
log_ok "Deployment completed"
echo "Service URL: $SERVICE_URL"
echo "VLESS: $VLESS_URI"

# =========================
# Telegram
# =========================
send_telegram "Deployment completed: $SERVICE_URL"