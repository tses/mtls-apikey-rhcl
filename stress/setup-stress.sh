#!/usr/bin/env bash
# mtls-apikey/stress/setup-stress.sh
#
# Prepares the cluster for the mTLS + API Key stress test.
#
# What it does:
#   0. Verify prerequisites (oc login, k6 binary, CA cert, stress cert)
#   1. Resolve Gateway IPs (smoke-check that gateways are up)
#   2. Apply 3000 API key Secrets  (gen-api-keys.sh | oc apply)
#   3. Apply 300 virtual services  (gen-services.sh  | oc apply)
#        HTTPRoute + AuthPolicy + RateLimitPolicy × 300
#        Backends reuse existing 'cars' and 'tax' Services.
#   4. Verify backends are Available
#   5. Wait for all stress AuthPolicies + RateLimitPolicies to reach Enforced=True
#        Initial pause of WAIT_RECONCILE seconds, then active polling every 10 s
#        up to POLICY_ENFORCE_TIMEOUT seconds total.
#
# Usage:
#   chmod +x setup-stress.sh
#   ./mtls-apikey/stress/setup-stress.sh
#
# Options (env vars):
#   SKIP_APPLY=1                skip oc apply (resources already on cluster);
#                               also skips the enforcement check in Step 5
#   WAIT_RECONCILE=30           initial pause before first enforcement check (default: 30)
#   POLICY_ENFORCE_TIMEOUT=3600 max seconds to wait for Enforced=True (default: 3600 = 1 h)
#
# Run once per cluster. After this completes, run run-stress-test.sh.
# Subsequent runs with SKIP_APPLY=1 are safe and fast.

set -euo pipefail

STRESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${STRESS_DIR}/../.." && pwd)"
CERT_DIR="$REPO_ROOT/tmp/mtls-demo"
NS="mtls-apikey"

SKIP_APPLY="${SKIP_APPLY:-0}"
WAIT_RECONCILE="${WAIT_RECONCILE:-30}"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║   mTLS + API Key Stress Test — Setup                               ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
info "Step 0 — checking prerequisites"

if ! command -v oc &>/dev/null; then
  error "oc CLI not found in PATH"; exit 1
fi

if ! command -v k6 &>/dev/null; then
  error "k6 not found in PATH"
  echo "       Install: https://grafana.com/docs/k6/latest/set-up/install-k6/"
  echo "       Quick:   sudo dnf install k6  OR  brew install k6"
  exit 1
fi

K6_VERSION=$(k6 version 2>&1 | grep -oP 'v\d+\.\d+' | head -1)
MINOR=$(echo "$K6_VERSION" | grep -oP '\d+\.\K\d+')
if (( MINOR < 49 )); then
  warn "k6 < 0.49 detected — K6_WEB_DASHBOARD will not work. Upgrade recommended."
fi
info "k6 version: ${K6_VERSION}"

if ! oc whoami &>/dev/null; then
  error "Not logged in to OpenShift — run 'oc login' first"; exit 1
fi
ok "oc: logged in as $(oc whoami)"

if [[ ! -f "$CERT_DIR/ca.crt" ]]; then
  error "CA cert not found at $CERT_DIR/ca.crt"
  echo "       Run: ./mtls-apikey/02-generate-client-certs.sh"
  exit 1
fi

if [[ ! -f "$CERT_DIR/stress-user-001.crt" ]]; then
  warn "Shared stress cert not found at $CERT_DIR/stress-user-001.crt"
  info "Generating it now..."
  bash "$STRESS_DIR/gen-stress-certs.sh"
fi
ok "Shared client cert: $CERT_DIR/stress-user-001.crt"

# ── Step 1: Resolve Gateway IPs ───────────────────────────────────────────────
info "Step 1 — resolving Gateway LoadBalancer IPs"

GW_MTLS=$(oc get svc -n "${NS}" \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

GW_PLAIN=$(oc get svc -n "${NS}" \
  -l gateway.networking.k8s.io/gateway-name=external-plain \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "$GW_MTLS" ]]; then
  error "Cannot resolve IP for external-mtls-apikey gateway"
  echo "       Is the gateway deployed? Run: oc get svc -n ${NS}"
  exit 1
fi
if [[ -z "$GW_PLAIN" ]]; then
  error "Cannot resolve IP for external-plain gateway"
  exit 1
fi

ok "mTLS Gateway IP : ${GW_MTLS}"
ok "Plain Gateway IP: ${GW_PLAIN}"

# ── Steps 2–4: Apply resources ────────────────────────────────────────────────
if [[ "$SKIP_APPLY" == "1" ]]; then
  warn "SKIP_APPLY=1 — skipping oc apply (assuming resources already deployed)"
else
  # Step 2: API key Secrets
  # gen-api-keys.sh writes progress ticks to stderr (fd 2) which flows directly
  # to the terminal; only oc apply's stdout is piped through the summary filter.
  info "Step 2 — applying 3000 API key Secrets (progress printed every 100 users)..."
  bash "$STRESS_DIR/gen-api-keys.sh" \
    | oc apply -f - --dry-run=none \
    | grep -E "(configured|created|unchanged|Error|error|Warning)" \
    | sed 's/^/  /' \
    || true
  # Count what landed
  SECRET_APPLIED=$(oc get secret -n kuadrant-system -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "?")
  ok "API key Secrets applied — ${SECRET_APPLIED} total in kuadrant-system"

  # Step 3: Virtual services
  # Same pattern: gen-services.sh stderr goes to terminal, oc apply stdout filtered.
  info "Step 3 — applying 300 virtual services (HTTPRoute + AuthPolicy + RateLimitPolicy)"
  info "         Progress printed every 50 services. Operator reconcile follows in Step 5."
  bash "$STRESS_DIR/gen-services.sh" \
    | oc apply -f - --dry-run=none \
    | grep -E "(configured|created|unchanged|Error|error|Warning)" \
    | sed 's/^/  /' \
    || true
  ROUTE_APPLIED=$(oc get httproute -n "${NS}" -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "?")
  AUTH_APPLIED=$(oc get authpolicy -n "${NS}" -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "?")
  RLP_APPLIED=$(oc get ratelimitpolicy -n "${NS}" -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "?")
  ok "HTTPRoutes: ${ROUTE_APPLIED}  AuthPolicies: ${AUTH_APPLIED}  RateLimitPolicies: ${RLP_APPLIED}"

  info "Step 4 — verifying backends are running"
  for SVC in cars tax; do
    oc wait deployment/"${SVC}" -n "${NS}" \
      --for=condition=Available --timeout=60s &>/dev/null && \
      ok "  ${SVC} backend: Available" || \
      warn "  ${SVC} backend: NOT Available — check oc get pods -n ${NS}"
  done
fi

# ── Step 5: Wait for all stress policies to reach Enforced=True ──────────────
# Naming convention (from gen-services.sh):
#   AuthPolicy      stress-svc-NNN-authpolicy   -n mtls-apikey  label: stress-test=true
#   RateLimitPolicy stress-svc-NNN-ratelimit     -n mtls-apikey  label: stress-test=true
#
# We poll oc get <kind> -o jsonpath for all items and count those whose
# .status.conditions[] has type=Enforced AND status=True.
# Initial sleep of WAIT_RECONCILE seconds before first check lets the operator
# finish its first reconcile pass (avoids hammering the API immediately).

POLICY_ENFORCE_TIMEOUT="${POLICY_ENFORCE_TIMEOUT:-3600}"  # max seconds to wait (1 h)
POLICY_POLL_INTERVAL=10                                    # seconds between polls
EXPECTED_POLICIES=300                                      # one per service

# Helper: count how many resources of a given kind have Enforced=True.
# Emits one line per resource via jsonpath:
#   "<name> Accepted=True Enforced=True ..."
# then counts lines that contain the substring "Enforced=True".
# Portable across all oc/kubectl versions (no jsonpath filter syntax needed).
_count_enforced() {
  local KIND="$1" NS_TARGET="$2"
  local _out
  _out=$(oc get "$KIND" -n "$NS_TARGET" -l stress-test=true \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}' \
    2>/dev/null) || true
  # grep -c exits 1 on zero matches; avoid the || echo "0" double-print pattern
  # by counting in-process instead.
  echo "$_out" | grep -c "Enforced=True" 2>/dev/null || echo "0"
}

if [[ "$SKIP_APPLY" == "1" ]]; then
  info "Step 5 — SKIP_APPLY=1, skipping policy enforcement check"
else
  echo ""
  info "Step 5 — waiting for ${EXPECTED_POLICIES} AuthPolicies + ${EXPECTED_POLICIES} RateLimitPolicies to reach Enforced=True"
  info "         Timeout: ${POLICY_ENFORCE_TIMEOUT}s (1 h).  Press Ctrl+C at any time to skip and proceed manually."
  info "         Manual check command:"
  echo  "           oc get authpolicy      -n ${NS} -l stress-test=true -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{range .status.conditions[*]}{.type}{\"=\"}{.status}{\" \"}{end}{\"\\n\"}{end}' | grep -v 'Enforced=True'"
  echo  "           oc get ratelimitpolicy -n ${NS} -l stress-test=true -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{range .status.conditions[*]}{.type}{\"=\"}{.status}{\" \"}{end}{\"\\n\"}{end}' | grep -v 'Enforced=True'"
  echo ""
  info "         Initial pause of ${WAIT_RECONCILE}s before first check..."

  # Trap Ctrl+C so we can print a clean message instead of a raw stack abort
  # The trap is scoped: we restore the default handler after the polling block.
  _enforce_interrupted=0
  trap '_enforce_interrupted=1' INT

  # Initial sleep (countdown ticker)
  for (( _t = WAIT_RECONCILE; _t > 0; _t-- )); do
    [[ "$_enforce_interrupted" == "1" ]] && break
    printf "\r${CYAN}[INFO]${RESET}   Initial reconcile pause: %3d s remaining..." "$_t"
    sleep 1
  done
  printf "\r%*s\r" 72 ""

  # Active poll loop — use bash $SECONDS for wall-clock timing
  AP_ENFORCED=0
  RL_ENFORCED=0
  _STEP5_START=$SECONDS

  while (( SECONDS - _STEP5_START < POLICY_ENFORCE_TIMEOUT )); do
    [[ "$_enforce_interrupted" == "1" ]] && break

    AP_ENFORCED=$(_count_enforced authpolicy      "$NS")
    RL_ENFORCED=$(_count_enforced ratelimitpolicy "$NS")
    _ELAPSED=$(( SECONDS - _STEP5_START ))
    _ELAPSED_MIN=$(( _ELAPSED / 60 ))
    _ELAPSED_SEC=$(( _ELAPSED % 60 ))

    printf "\r${CYAN}[INFO]${RESET}   AuthPolicy %3d/%d enforced  |  RateLimitPolicy %3d/%d enforced  (%dm%02ds elapsed)..." \
      "$AP_ENFORCED" "$EXPECTED_POLICIES" \
      "$RL_ENFORCED" "$EXPECTED_POLICIES" \
      "$_ELAPSED_MIN" "$_ELAPSED_SEC"

    if (( AP_ENFORCED >= EXPECTED_POLICIES && RL_ENFORCED >= EXPECTED_POLICIES )); then
      printf "\r%*s\r" 88 ""
      _TOTAL=$(( SECONDS - _STEP5_START ))
      ok "All ${EXPECTED_POLICIES} AuthPolicies enforced"
      ok "All ${EXPECTED_POLICIES} RateLimitPolicies enforced"
      ok "Enforcement completed in $(( _TOTAL / 60 ))m$(( _TOTAL % 60 ))s"
      break
    fi

    sleep "$POLICY_POLL_INTERVAL"
  done

  # Restore default INT handler
  trap - INT

  _TOTAL_ELAPSED=$(( SECONDS - _STEP5_START ))

  if [[ "$_enforce_interrupted" == "1" ]]; then
    printf "\r%*s\r" 88 ""
    warn "Step 5 interrupted by user after ${_TOTAL_ELAPSED}s."
    warn "  AuthPolicy      : ${AP_ENFORCED} / ${EXPECTED_POLICIES} enforced at interrupt"
    warn "  RateLimitPolicy : ${RL_ENFORCED} / ${EXPECTED_POLICIES} enforced at interrupt"
    warn "  Re-check manually with the commands printed above."
  elif (( AP_ENFORCED < EXPECTED_POLICIES || RL_ENFORCED < EXPECTED_POLICIES )); then
    printf "\r%*s\r" 88 ""
    warn "Timeout after ${_TOTAL_ELAPSED}s — not all policies enforced:"
    warn "  AuthPolicy      : ${AP_ENFORCED} / ${EXPECTED_POLICIES} enforced"
    warn "  RateLimitPolicy : ${RL_ENFORCED} / ${EXPECTED_POLICIES} enforced"
    warn "  Re-check manually with the commands printed above."
  fi
fi

echo ""
ok "Setup complete. Run ./mtls-apikey/stress/run-stress-test.sh to start the load test."
