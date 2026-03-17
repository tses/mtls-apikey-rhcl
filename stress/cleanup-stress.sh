#!/usr/bin/env bash
# mtls-apikey/stress/cleanup-stress.sh
#
# Removes all resources created by the stress test scripts:
#   - API key Secrets in kuadrant-system  (label: stress-test=true)
#   - 300 × (Deployment + Service + HTTPRoute + AuthPolicy + RateLimitPolicy) in mtls-apikey
#
# Does NOT touch:
#   - The original PoC resources (00-*.yaml … 13-*.yaml)
#   - The original 3 client certs (insurance-user, accountant-user, accountant-director)
#   - CA cert / CA key in tmp/mtls-demo/
#   - The rhcl-scaling-uc resources (Valkey, Limitador, Authorino scaling)
#
# Usage:
#   chmod +x cleanup-stress.sh
#
#   # Dry-run: show what would be deleted
#   DRY_RUN=1 ./mtls-apikey/stress/cleanup-stress.sh
#
#   # Full cleanup
#   ./mtls-apikey/stress/cleanup-stress.sh
#
#   # Also revert data-plane scaling (Limitador / Authorino back to 1 replica,
#   # Valkey removed, Gateway HPA removed)
#   REVERT_SCALING=1 ./mtls-apikey/stress/cleanup-stress.sh

set -euo pipefail

NS_KEYS="kuadrant-system"
NS_APP="mtls-apikey"

DRY_RUN="${DRY_RUN:-0}"
REVERT_SCALING="${REVERT_SCALING:-0}"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }

OC_DELETE="oc delete"
if [[ "$DRY_RUN" == "1" ]]; then
  warn "DRY_RUN=1 — no resources will actually be deleted"
  OC_DELETE="echo [DRY-RUN] oc delete"
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║   Stress Test Cleanup — mtls-apikey                                ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Helper: delete resources, then poll until gone, showing a live counter ────
# Usage: _delete_with_progress <kind> <namespace> <start_count>
_delete_with_progress() {
  local KIND="$1" NS_TARGET="$2" START="$3"
  local FINALIZER_TIMEOUT=120   # seconds to wait for operator to clear finalizers

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] oc delete ${KIND} -n ${NS_TARGET} -l stress-test=true --ignore-not-found"
    return 0
  fi

  # Phase 1: issue the delete synchronously (marks resources Terminating).
  # Suppress the per-resource "deleted" lines — we show our own counter.
  info "  Issuing delete for ${START} ${KIND}(s)..."
  oc delete "$KIND" -n "$NS_TARGET" -l stress-test=true --ignore-not-found \
    >/dev/null 2>&1 || true

  # Phase 2: poll until all resources are gone (operator removes finalizers)
  # or until FINALIZER_TIMEOUT seconds have elapsed.
  local REMAINING=$START
  local ELAPSED=0
  while (( ELAPSED < FINALIZER_TIMEOUT )); do
    local _R
    _R=$(oc get "$KIND" -n "$NS_TARGET" -l stress-test=true \
      --no-headers 2>/dev/null | wc -l || true)
    if [[ "$_R" =~ ^[0-9]+$ ]]; then
      REMAINING=$_R
    fi
    local DONE=$(( START - REMAINING ))
    printf "\r${CYAN}[INFO]${RESET}   %-18s %4d / %4d gone  (%ds elapsed)..." \
      "${KIND}" "$DONE" "$START" "$ELAPSED"
    (( REMAINING == 0 )) && break
    sleep 3
    (( ELAPSED += 3 ))
  done

  printf "\r%*s\r" 72 ""   # clear the progress line
  if (( REMAINING == 0 )); then
    ok "  ${START} ${KIND}(s) deleted"
  else
    warn "  ${KIND}: ${REMAINING} / ${START} still present after ${FINALIZER_TIMEOUT}s (finalizers?)"
  fi
}

# ── 1. Delete API key Secrets (label selector — covers any COUNT) ─────────────
SECRET_COUNT=$(oc get secret -n "$NS_KEYS" -l stress-test=true \
  --no-headers 2>/dev/null | wc -l || echo "0")
info "Deleting ${SECRET_COUNT} API key Secrets in ${NS_KEYS} (label: stress-test=true)"
_delete_with_progress secret "$NS_KEYS" "$SECRET_COUNT"

# ── 2. Delete per-service resources (label selector — much faster than 300×) ──
# NOTE: No Deployments or Services are generated — gen-services.sh reuses the
#       existing 'cars' and 'tax' Services from 01-backend-app.yaml.
info "Deleting all stress-test labelled resources in namespace: ${NS_APP}"
info "  → RateLimitPolicies, AuthPolicies, HTTPRoutes only (no Deployments/Services)"

for KIND in ratelimitpolicy authpolicy httproute; do
  COUNT_FOUND=$(oc get "$KIND" -n "$NS_APP" -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "0")
  if (( COUNT_FOUND > 0 )); then
    _delete_with_progress "$KIND" "$NS_APP" "$COUNT_FOUND"
  else
    info "  no ${KIND}s with label stress-test=true found"
  fi
done

# ── 3. Remove generated cert files (optional) ─────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CERT_DIR="$REPO_ROOT/tmp/mtls-demo"

STRESS_CERT_COUNT=$(find "$CERT_DIR" -name 'stress-user-*.crt' 2>/dev/null | wc -l || echo "0")
if (( STRESS_CERT_COUNT > 0 )); then
  info "Found ${STRESS_CERT_COUNT} stress cert files in $CERT_DIR"
  read -r -p "  Delete stress-user-*.{crt,key} files? [y/N] " CONFIRM_CERTS
  if [[ "$CONFIRM_CERTS" =~ ^[Yy]$ ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[DRY-RUN] would delete: $(find "$CERT_DIR" -name 'stress-user-*' | wc -l) files"
    else
      find "$CERT_DIR" -name 'stress-user-*' -delete
      ok "Stress cert files deleted"
    fi
  else
    info "Cert files kept in $CERT_DIR"
  fi
fi

# ── 4. Optionally revert data-plane scaling ───────────────────────────────────
if [[ "$REVERT_SCALING" == "1" ]]; then
  warn "REVERT_SCALING=1 — reverting Limitador, Authorino, and Gateway HPA"

  info "Reverting Limitador to 1 replica + in-memory storage"
  $OC_DELETE secret limitador-valkey-url -n kuadrant-system --ignore-not-found || true
  if [[ "$DRY_RUN" != "1" ]]; then
    oc patch limitador limitador -n kuadrant-system --type merge \
      -p '{"spec":{"replicas":1,"storage":{"redis":null}}}' || true
  fi
  ok "Limitador reverted"

  info "Reverting Authorino to 1 replica"
  if [[ "$DRY_RUN" != "1" ]]; then
    oc patch authorino authorino -n kuadrant-system --type merge \
      -p '{"spec":{"replicas":1}}' || true
  fi
  ok "Authorino reverted"

  info "Removing Valkey (rhcl-dbs namespace)"
  REPO_ROOT_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  $OC_DELETE -f "$REPO_ROOT_LOCAL/rhcl-scaling-uc/01-valkey_deploy.yaml" \
    --ignore-not-found || true
  ok "Valkey removed"

  info "Reverting Gateway HPA (back to base 04-gateway.yaml)"
  $OC_DELETE configmap external-gateway-options -n api-gateway --ignore-not-found || true
  if [[ "$DRY_RUN" != "1" ]]; then
    oc apply -f "$REPO_ROOT_LOCAL/04-gateway.yaml" || true
  fi
  ok "Gateway reverted to base config"
fi

# ── 5. Verify cleanup ────────────────────────────────────────────────────────
echo ""
info "Verification — remaining stress resources:"
echo ""
echo "  Secrets in ${NS_KEYS}:"
oc get secret -n "$NS_KEYS" -l stress-test=true --no-headers 2>/dev/null \
  | wc -l | xargs -I{} echo "    {} remaining (expected: 0)"

for KIND in httproute authpolicy ratelimitpolicy; do
  REMAINING=$(oc get "$KIND" -n "$NS_APP" -l stress-test=true \
    --no-headers 2>/dev/null | wc -l || echo "?")
  echo "  ${KIND} in ${NS_APP}: ${REMAINING} remaining (expected: 0)"
done

echo ""
ok "Cleanup complete."
