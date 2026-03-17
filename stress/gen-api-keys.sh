#!/usr/bin/env bash
# mtls-apikey/stress/gen-api-keys.sh
#
# Generates YAML for 3000 API key Secrets and emits to stdout.
#
# Window model:
#   - 300 services (HTTPRoutes), each named service-NNN, each is its own group
#   - 1500 users; each user owns a sliding window of 10 consecutive groups
#     VU / user NNN (1-based):
#       window start = ((NNN-1) * 10) % 300 + 1
#       groups       = service-WWW, ..., service-WWW+9  (mod 300, wraps)
#
# 3000 Secrets:
#   1500 mTLS-required keys  (stress-mtls-key-0001 … stress-mtls-key-1500)
#     kuadrant.io/mtls-required: "true"
#     kuadrant.io/expected-cn:   "stress-user-001"  ← pinned to shared cert CN
#       All 1500 mTLS keys share the same expected-cn because k6 cannot select
#       per-VU certs at runtime (no tlsClientConfig per-request yet).
#       The OPA CN-binding Rego still executes and validates CN == "stress-user-001".
#
#   1500 plain keys          (stress-plain-key-0001 … stress-plain-key-1500)
#     kuadrant.io/mtls-required: "false"
#
# All keys:
#   kuadrant.io/groups: service-WWW,...,service-WWW+9   (10 groups, comma-separated)
#   kuadrant.io/level:  premium (NNN % 10 == 0) | basic (rest)
#
# Apply:
#   ./gen-api-keys.sh | oc apply -f -
#
# Delete all generated keys:
#   ./gen-api-keys.sh | oc delete -f - --ignore-not-found

set -euo pipefail

NS="kuadrant-system"
COUNT=1500
WINDOW=10
TOTAL_SERVICES=300
PROGRESS_INTERVAL=100   # print progress every N users (stderr, does not pollute stdout YAML)

# Colour helpers (stderr only — stdout is pure YAML)
CYAN='\033[0;36m'; RESET='\033[0m'
_info() { echo -e "${CYAN}[INFO]${RESET} $*" >&2; }

emit_secret() {
  local name=$1 ns=$2 level=$3 groups=$4 mtls=$5 cn=$6 key=$7 userid=$8

  cat <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: government-services
    stress-test: "true"
  annotations:
    kuadrant.io/mtls-required: "${mtls}"
    kuadrant.io/expected-cn: "${cn}"
    kuadrant.io/groups: "${groups}"
    kuadrant.io/level: ${level}
    secret.kuadrant.io/user-id: ${userid}
stringData:
  api_key: ${key}
type: Opaque
YAML
}

_info "Generating ${COUNT} mTLS + ${COUNT} plain API key Secrets (total: $(( COUNT * 2 )))..."

for i in $(seq -w 1 ${COUNT}); do
  IDX=$(( 10#$i ))

  # Progress tick to stderr every PROGRESS_INTERVAL users
  if (( IDX % PROGRESS_INTERVAL == 0 || IDX == 1 || IDX == COUNT )); then
    _info "  user ${IDX}/${COUNT}  ($(( IDX * 2 - 1 ))–$(( IDX * 2 )) of $(( COUNT * 2 )) Secrets emitted)"
  fi

  # ── Build window of 10 group names inline (avoids $() function capture bug) ──
  start=$(( ((IDX - 1) * WINDOW) % TOTAL_SERVICES + 1 ))
  unset GRP_LIST; GRP_LIST=""
  for (( j = 0; j < WINDOW; j++ )); do
    svc=$(( (start - 1 + j) % TOTAL_SERVICES + 1 ))
    if   (( svc < 10  )); then svc_id="00${svc}"
    elif (( svc < 100 )); then svc_id="0${svc}"
    else                       svc_id="${svc}"
    fi
    if [[ -z "${GRP_LIST}" ]]; then GRP_LIST="service-${svc_id}"
    else                            GRP_LIST="${GRP_LIST},service-${svc_id}"
    fi
  done

  # level: multiples of 10 → premium, rest → basic
  if (( IDX % 10 == 0 )); then LEVEL="premium"; else LEVEL="basic"; fi

  # mTLS key — all 1500 keys share expected-cn "stress-user-001" (single shared cert)
  emit_secret \
    "stress-mtls-key-${i}" "${NS}" "${LEVEL}" "${GRP_LIST}" \
    "true" "stress-user-001" "STRESS-MTLS-${i}" "stress-user-${i}"

  # Plain key
  emit_secret \
    "stress-plain-key-${i}" "${NS}" "${LEVEL}" "${GRP_LIST}" \
    "false" "" "STRESS-PLAIN-${i}" "stress-plain-${i}"
done
