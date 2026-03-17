#!/usr/bin/env bash
# mtls-apikey/stress/gen-services.sh
#
# Generates YAML for 300 stress-test "virtual services" and emits to stdout.
# Each service NNN (001-300) gets:
#   - HTTPRoute          (stress-svc-NNN-route)
#   - AuthPolicy         (stress-svc-NNN-authpolicy)
#   - RateLimitPolicy    (stress-svc-NNN-ratelimit)
#
# NO new Deployments or Services are created — the existing 'cars' and 'tax'
# Services (from 01-backend-app.yaml) are reused as backends.
#
# Window model:
#   Each HTTPRoute belongs to exactly ONE group named "service-NNN".
#   The AuthPolicy OPA rule allows access only when the caller's
#   kuadrant.io/groups annotation contains "service-NNN".
#   Users are assigned a window of 10 consecutive service groups (gen-api-keys.sh).
#
# Path / backend assignment (unchanged):
#   NNN 001-150 → path /service-NNN/cars → backend: cars:80
#   NNN 151-300 → path /service-NNN/tax  → backend: tax:80
#
# Apply:
#   ./gen-services.sh | oc apply -f -
#
# Dry-run preview:
#   ./gen-services.sh | less
#
# Count resources:
#   ./gen-services.sh | grep -c '^kind:'
#   # Expected: 900  (300 × 3 resources each)

set -euo pipefail

NS="mtls-apikey"
TOTAL_SERVICES=300
CAR_LIMIT=150   # NNN 001-150 → cars backend
PROGRESS_INTERVAL=50   # print progress every N services (stderr, does not pollute stdout YAML)

# Colour helpers (stderr only — stdout is pure YAML)
CYAN='\033[0;36m'; RESET='\033[0m'
_info() { echo -e "${CYAN}[INFO]${RESET} $*" >&2; }

_info "Generating ${TOTAL_SERVICES} virtual services (HTTPRoute + AuthPolicy + RateLimitPolicy each)..."

for i in $(seq -w 1 ${TOTAL_SERVICES}); do
  IDX=$(( 10#$i ))

  # Progress tick to stderr every PROGRESS_INTERVAL services
  if (( IDX % PROGRESS_INTERVAL == 0 || IDX == 1 || IDX == TOTAL_SERVICES )); then
    _info "  service ${IDX}/${TOTAL_SERVICES}  ($(( IDX * 3 - 2 ))–$(( IDX * 3 )) of $(( TOTAL_SERVICES * 3 )) resources emitted)"
  fi
  NAME="stress-svc-${i}"
  GROUP="service-${i}"   # one-to-one: 1 HTTPRoute == 1 group

  if (( IDX <= CAR_LIMIT )); then
    PATH_PREFIX="/service-${i}/cars"
    BACKEND_SVC="cars"
  else
    PATH_PREFIX="/service-${i}/tax"
    BACKEND_SVC="tax"
  fi

  cat <<YAML
---
# ── ${NAME}: HTTPRoute (dual-gateway, unique path prefix) ─────────────────────
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${NAME}-route
  namespace: ${NS}
  labels:
    stress-test: "true"
    stress-group: "${GROUP}"
spec:
  parentRefs:
  - name: external-mtls-apikey
    namespace: ${NS}
    sectionName: api
  - name: external-plain
    namespace: ${NS}
    sectionName: api
  hostnames:
  - "mtls.mapi.example.com"
  - "cert.mapi.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${PATH_PREFIX}
    backendRefs:
    - name: ${BACKEND_SVC}
      port: 80
---
# ── ${NAME}: AuthPolicy ───────────────────────────────────────────────────────
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: ${NAME}-authpolicy
  namespace: ${NS}
  labels:
    stress-test: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ${NAME}-route
  defaults:
    rules:
      authentication:
        "api-key-users":
          apiKey:
            selector:
              matchLabels:
                app: government-services
          credentials:
            authorizationHeader:
              prefix: APIKEY
      response:
        success:
          filters:
            "identity":
              json:
                properties:
                  "userid":
                    selector: auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id
                  "level":
                    selector: auth.identity.metadata.annotations.kuadrant\.io/level
      authorization:
        "mtls-apikey-binding":
          priority: 0
          opa:
            rego: |
              mtls_required := object.get(
                input.auth.identity.metadata.annotations,
                "kuadrant.io/mtls-required",
                "false"
              )
              allow {
                mtls_required == "false"
              }
              xfcc := input.context.request.http.headers["x-forwarded-client-cert"]
              subject = v {
                matches := regex.find_all_string_submatch_n(
                  \`Subject="([^"]*)"\`, xfcc, 1
                )
                v := matches[0][1]
              }
              dn = parsed {
                fields := split(subject, ",")
                parsed := {k: val |
                  part := fields[_]
                  idx  := indexof(part, "=")
                  idx  >= 0
                  k    := substring(part, 0, idx)
                  val  := substring(part, idx + 1, -1)
                }
              }
              expected_cn := input.auth.identity.metadata.annotations["kuadrant.io/expected-cn"]
              allow {
                mtls_required == "true"
                dn["CN"] == expected_cn
              }
        "group-${i}":
          priority: 1
          opa:
            rego: |
              groups := split(object.get(input.auth.identity.metadata.annotations, "kuadrant.io/groups", ""), ",")
              allow { groups[_] == "${GROUP}" }
---
# ── ${NAME}: RateLimitPolicy ──────────────────────────────────────────────────
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: ${NAME}-ratelimit
  namespace: ${NS}
  labels:
    stress-test: "true"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ${NAME}-route
  limits:
    "premium-user-limit":
      rates:
        - limit: 100
          window: 10s
      counters:
        - expression: "auth.identity.userid"
      when:
        - predicate: "auth.identity.level == 'premium'"
    "basic-user-limit":
      rates:
        - limit: 5
          window: 10s
      counters:
        - expression: "auth.identity.userid"
      when:
        - predicate: "auth.identity.level == 'basic'"
YAML
done
