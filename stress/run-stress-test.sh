#!/usr/bin/env bash
# mtls-apikey/stress/run-stress-test.sh
#
# Passes env vars to k6-stress-combined.js and runs it.
#
# Usage:
#   MTLS_VUS=10 PLAIN_VUS=10 STEADY_DURATION=60s ./mtls-apikey/stress/run-stress-test.sh
#
# Env vars (all optional):
#   MTLS_VUS=10          peak mTLS VUs          (default: 10)
#   PLAIN_VUS=10         peak plain VUs         (default: 10)
#   MAX_USERS=1500       random user pool size  (default: 1500)
#   RAMP_DURATION=30s    ramp-up                (default: 30s)
#   STEADY_DURATION=120s steady state           (default: 120s)
#   RAMP_DOWN_DURATION=15s ramp-down            (default: 15s)
#   SLEEP_MIN=0.1        min sleep/req (s)      (default: 0.1)
#   SLEEP_MAX=0.5        max sleep/req (s)      (default: 0.5)
#   RAW_JSON=true        write combined-raw.json (default: off — file can be multi-GB)

set -euo pipefail

STRESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${STRESS_DIR}/../.." && pwd)"
CERT_DIR="$REPO_ROOT/tmp/mtls-demo"
NS="mtls-apikey"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

MTLS_VUS="${MTLS_VUS:-10}"
PLAIN_VUS="${PLAIN_VUS:-10}"
MAX_USERS="${MAX_USERS:-1500}"
RAMP_DURATION="${RAMP_DURATION:-30s}"
STEADY_DURATION="${STEADY_DURATION:-120s}"
RAMP_DOWN_DURATION="${RAMP_DOWN_DURATION:-15s}"
SLEEP_MIN="${SLEEP_MIN:-0.1}"
SLEEP_MAX="${SLEEP_MAX:-0.5}"

# Auto-generate results dir: results/<timestamp>_mtls<N>_plain<N>_s<steady>
# Override by setting RESULTS_DIR explicitly before running.
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${RESULTS_DIR:-${STRESS_DIR}/results/${TIMESTAMP}_mtls${MTLS_VUS}_plain${PLAIN_VUS}_s${STEADY_DURATION}}"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║   mTLS + API Key Stress Test — Run                                 ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Pre-flight — checking prerequisites..."

if ! command -v k6 &>/dev/null; then
  error "k6 not found in PATH — install: https://grafana.com/docs/k6/latest/set-up/install-k6/"
  exit 1
fi
ok "k6 found: $(k6 version 2>&1 | head -1)"

if ! oc whoami &>/dev/null; then
  error "Not logged in to OpenShift — run 'oc login' first"
  exit 1
fi
ok "oc: logged in as $(oc whoami)"

if [[ ! -f "$CERT_DIR/stress-user-001.crt" ]]; then
  error "Shared stress cert not found at $CERT_DIR/stress-user-001.crt"
  error "Run: ./mtls-apikey/stress/gen-stress-certs.sh"
  exit 1
fi
ok "Client cert: $CERT_DIR/stress-user-001.crt"

# ── Resolve Gateway IPs ───────────────────────────────────────────────────────
info "Resolving Gateway LoadBalancer IPs..."

GW_MTLS=$(oc get svc -n "${NS}" \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
GW_PLAIN=$(oc get svc -n "${NS}" \
  -l gateway.networking.k8s.io/gateway-name=external-plain \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "$GW_MTLS" ]]; then
  error "Cannot resolve IP for external-mtls-apikey — run setup-stress.sh first"
  exit 1
fi
if [[ -z "$GW_PLAIN" ]]; then
  error "Cannot resolve IP for external-plain — run setup-stress.sh first"
  exit 1
fi

ok "mTLS Gateway  : ${GW_MTLS}"
ok "Plain Gateway : ${GW_PLAIN}"

# ── Quick resource sanity check ───────────────────────────────────────────────
info "Checking stress resources on cluster..."
SECRET_COUNT=$(oc get secret -n kuadrant-system -l stress-test=true \
  --no-headers 2>/dev/null | wc -l || echo "0")
ROUTE_COUNT=$(oc get httproute -n "${NS}" -l stress-test=true \
  --no-headers 2>/dev/null | wc -l || echo "0")
if (( SECRET_COUNT == 0 || ROUTE_COUNT == 0 )); then
  warn "API key Secrets: ${SECRET_COUNT}  HTTPRoutes: ${ROUTE_COUNT}"
  warn "Resources look incomplete — did setup-stress.sh complete successfully?"
else
  ok "API key Secrets: ${SECRET_COUNT}  HTTPRoutes: ${ROUTE_COUNT}"
fi

mkdir -p "$RESULTS_DIR"

# ── Test plan summary ─────────────────────────────────────────────────────────
echo ""
info "Test plan:"
info "  VUs          : mTLS=${MTLS_VUS}  plain=${PLAIN_VUS}"
info "  User pool    : ${MAX_USERS}"
info "  Durations    : ramp=${RAMP_DURATION}  steady=${STEADY_DURATION}  down=${RAMP_DOWN_DURATION}"
info "  Sleep/req    : ${SLEEP_MIN}–${SLEEP_MAX}s"
info "  Results dir  : ${RESULTS_DIR}"
info "  Dashboard    : http://localhost:5665  (live while test runs)"
echo ""
ok "Starting k6..."

# Dashboard: live at http://localhost:5665 while test runs.
# k6 exits automatically when the test ends IF no browser window is open.
# If it hangs, close the browser tab — the process will exit immediately.
#
# Errors: k6 writes console.error() to stderr.
#   stderr is piped through `tee` so errors appear on the terminal in real-time
#   AND are persisted to ${RESULTS_DIR}/errors.log.
#   --out json is omitted by default (multi-GB). Set RAW_JSON=true to enable it.
ERRORS_LOG="${RESULTS_DIR}/errors.log"
RAW_JSON="${RAW_JSON:-false}"

# Build optional --out json flag
RAW_JSON_ARGS=()
if [[ "${RAW_JSON}" == "true" ]]; then
  RAW_JSON_ARGS=(--out "json=${RESULTS_DIR}/combined-raw.json")
  warn "RAW_JSON=true — combined-raw.json will be written (can be multi-GB!)"
fi

info "Errors log    : ${ERRORS_LOG}"
[[ "${RAW_JSON}" == "true" ]] && info "Raw JSON      : ${RESULTS_DIR}/combined-raw.json"

K6_WEB_DASHBOARD=true \
K6_WEB_DASHBOARD_PORT=5665 \
K6_WEB_DASHBOARD_EXPORT="${RESULTS_DIR}/combined-report.html" \
  k6 run \
    --insecure-skip-tls-verify \
    -e GW_MTLS="${GW_MTLS}" \
    -e GW_PLAIN="${GW_PLAIN}" \
    -e CERT_DIR="${CERT_DIR}" \
    -e MTLS_VUS="${MTLS_VUS}" \
    -e PLAIN_VUS="${PLAIN_VUS}" \
    -e MAX_USERS="${MAX_USERS}" \
    -e RAMP_DURATION="${RAMP_DURATION}" \
    -e STEADY_DURATION="${STEADY_DURATION}" \
    -e RAMP_DOWN_DURATION="${RAMP_DOWN_DURATION}" \
    -e SLEEP_MIN="${SLEEP_MIN}" \
    -e SLEEP_MAX="${SLEEP_MAX}" \
    -e RESULTS_DIR="${RESULTS_DIR}" \
    "${RAW_JSON_ARGS[@]}" \
    "$STRESS_DIR/k6-stress-combined.js" \
    2> >(tee "${ERRORS_LOG}" >&2)

echo ""
ERROR_COUNT=$(grep -c '^\(ERRO\|time=\)' "${ERRORS_LOG}" 2>/dev/null || true)
if (( ERROR_COUNT > 0 )); then
  warn "Errors recorded: ${ERROR_COUNT} — see ${ERRORS_LOG}"
else
  ok "No errors recorded in ${ERRORS_LOG}"
fi
