# 📊 Stress Test — mTLS + API Key at Scale (300 services / 3000 keys / 1500 users)

Realistic load test for the [`mtls-apikey`](../README.md) PoC using **k6** as the load generator.

---

## Scenario

| Dimension | Value |
|-----------|-------|
| Services (HTTPRoutes + AuthPolicies + RateLimitPolicies) | **300** |
| mTLS clients — API key Secrets + k6 VUs (`kuadrant.io/mtls-required: "true"`) | **1500** (configurable via `MTLS_VUS`) |
| Plain clients — API key Secrets + k6 VUs (`kuadrant.io/mtls-required: "false"`) | **1500** (configurable via `PLAIN_VUS`) |
| API key Secrets total | **3000** (1500 mTLS + 1500 plain) |
| Client certs | **1 shared cert** (`stress-user-001`, CN=stress-user-001, RSA 2048) |
| Default run VUs (`run-stress-test.sh`) | **10** per tier (safe warm-up default) |
| Traffic pattern | ramp-up 30 s → steady 120 s → ramp-down 15 s (default) |
| User window | each user owns 10 consecutive service groups (mod 300) |
| Level split | user idx % 10 == 0 → `premium` (100 req/10s) / rest → `basic` (5 req/10s) |
| Path split | service 001-150 → `/cars` backend / 151-300 → `/tax` backend |

---

## File layout

```
mtls-apikey/stress/
├── setup-stress.sh          # One-time cluster setup: prereq checks → apply resources → wait
├── run-stress-test.sh       # Resolve GW IPs and pass env vars to k6-stress-combined.js
├── gen-api-keys.sh          # Emit YAML for 3000 API key Secrets to stdout
├── gen-services.sh          # Emit YAML for 300 services to stdout
├── gen-stress-certs.sh      # Generate shared stress client cert in tmp/mtls-demo/
├── k6-stress-combined.js    # k6 script — mTLS + plain in ONE run (two parallel scenarios)
├── cleanup-stress.sh        # Teardown all generated resources
├── results/                 # Auto-created by run-stress-test.sh
│   ├── combined-summary.json
│   └── combined-raw.json
└── README.md                # This file
```

---

## Prerequisites

### 1. Cluster-side (run once)

#### a) Deploy the base PoC (files `00` – `07`) — **required before `setup-stress.sh`**

[`setup-stress.sh`](setup-stress.sh) assumes the namespace, backends, gateways, TLS policies, and
EnvoyFilters are already on the cluster. It will exit immediately with an error if the Gateway
LoadBalancer IPs cannot be resolved.

Apply in order:

```bash
oc apply -f 00-namespace.yaml
oc apply -f 01-backend-app.yaml
# 02 is a script — generates CA + client certs (run once, see step b below)
oc apply -f 04-gateway-infra-configmap.yaml
oc apply -f 05-gateway-mtls.yaml
oc apply -f 05b-gateway-plain.yaml
oc apply -f 06-tlspolicy-mtls.yaml
oc apply -f 06-tlspolicy-plain.yaml
oc apply -f 07-envoyfilter-mtls.yaml

# Wait for gateways to get LoadBalancer IPs before proceeding
oc wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
  svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  --timeout=120s
oc wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
  svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-plain \
  --timeout=120s
```

> See the [root README](../README.md) for full details on each manifest.

#### b) Generate CA + base client certs (if not already done)

```bash
chmod +x 02-generate-client-certs.sh
./02-generate-client-certs.sh
```

#### c) Scale Authorino before the test

```bash
# Stateless — each replica handles auth independently
oc patch authorino authorino -n kuadrant-system --type merge -p '
{
  "spec": {
    "replicas": 4,
    "logLevel": "warn"
  }
}'
oc rollout status deployment/authorino -n kuadrant-system
```

#### d) Increase `kuadrant-operator-controller-manager` memory limits

```bash
# With 300 HTTPRoutes + AuthPolicies + RateLimitPolicies the operator OOMKills.
# Patching the Deployment directly does NOT persist — OLM reconciles it back.
# Patch the CSV instead — OLM reads this as the source manifest.
oc patch csv rhcl-operator.v1.3.0 -n kuadrant-system --type=json -p '[
  {"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/resources/limits/cpu",      "value": "2000m"},
  {"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/resources/limits/memory",   "value": "600Mi"},
  {"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/resources/requests/cpu",    "value": "200m"},
  {"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/resources/requests/memory", "value": "200Mi"}
]'
# oc rollout status deployment/kuadrant-operator-controller-manager -n kuadrant-system
```

> ⚠️ **[CONNLINK-678](https://issues.redhat.com/browse/CONNLINK-678)** — `kuadrant-operator-controller-manager` OOMKilled with large object counts (300 × HTTPRoute + AuthPolicy + RateLimitPolicy).
> Patching the Deployment directly is **not persistent** — OLM reconciles it back.
> Patch the **CSV** (`rhcl-operator.v1.3.0`) `spec.install.spec.deployments[0]…containers[0].resources` — OLM uses this as the source manifest and re-applies it on every reconciliation.
> Do **not** remove limits entirely — Noisy Neighbor risk on shared nodes.

### 2. Client-side — install k6

```bash
# k6 >= 0.49 (for web dashboard)
# Fedora / RHEL:
sudo dnf install k6
# macOS:
brew install k6
# Or download binary: https://grafana.com/docs/k6/latest/set-up/install-k6/
```

> Certs (`02-generate-client-certs.sh` + `gen-stress-certs.sh`) are covered in steps **1b** and
> auto-generated by [`setup-stress.sh`](setup-stress.sh) if the stress cert is missing.

---

## Default parameters

All durations and VU counts are overridable via environment variables.

| Parameter | `run-stress-test.sh` default | k6 script fallback | Full-run value |
|---|---|---|---|
| `MTLS_VUS` / `PLAIN_VUS` | **10** | `10` | **1500** |
| `MAX_USERS` | **1500** | `1500` | 1500 |
| `RAMP_DURATION` | **30s** | `30s` | 60s |
| `STEADY_DURATION` | **120s** | `120s` | 300s |
| `RAMP_DOWN_DURATION` | **15s** | `15s` | 30s |
| `SLEEP_MIN` | **0.1s** | `0.1s` | 0.1s |
| `SLEEP_MAX` | **0.5s** | `0.5s` | 0.5s |
| `WAIT_RECONCILE` | **30s** | — | 30s |

> **Note:** Defaults are deliberately conservative (10 VUs) so that a bare
> `./run-stress-test.sh` acts as a quick connectivity check.
> Scale up by overriding `MTLS_VUS=1500 PLAIN_VUS=1500 STEADY_DURATION=300s`.

---

## Quick start

```bash
chmod +x mtls-apikey/stress/*.sh

# 1. One-time cluster setup (apply 3000 keys + 300 services, wait for reconciliation)
./mtls-apikey/stress/setup-stress.sh

# 2. Connectivity check (1 VU each tier, 60 s — verify auth + routing before scaling up)
MTLS_VUS=1 PLAIN_VUS=1 STEADY_DURATION=60s ./mtls-apikey/stress/run-stress-test.sh

# 3. Full load test (repeatable, use SKIP_APPLY=1 to skip apply on subsequent runs)
MTLS_VUS=1500 PLAIN_VUS=1500 RAMP_DURATION=60s STEADY_DURATION=300s \
  ./mtls-apikey/stress/run-stress-test.sh
```

Then open: **http://localhost:5665** — live dashboard (both tiers, filter by `scenario` / `tier` tag).

> k6 exits automatically when the test ends **if no browser tab is open**.
> If it hangs, close the browser tab — the process exits immediately.

Results in `mtls-apikey/stress/results/`:
- `combined-report.html` — static HTML report (written on exit)
- `combined-summary.json` — end-of-test metrics
- `combined-raw.json` — per-request time series

---

## Combined script — single run, single report

[`k6-stress-combined.js`](k6-stress-combined.js) is the **only** script used by [`run-stress-test.sh`](run-stress-test.sh).
It runs both tiers as two parallel scenarios (`mtls_load` + `plain_load`) in a **single k6 process**:

- **One** `combined-summary.json` — end-of-test metrics tagged per `scenario` / `tier`
- **One** raw JSON (`combined-raw.json`) for post-processing
- Concurrent VU pools — the two scenarios ramp independently

> `run-stress-test.sh` is the recommended entry point. Direct `k6 run` is also shown below for reference.

### Direct k6 run (reference)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

GW_MTLS=$(oc get svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

GW_PLAIN=$(oc get svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-plain \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

mkdir -p mtls-apikey/stress/results

K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_PORT=5665 \
K6_WEB_DASHBOARD_EXPORT=mtls-apikey/stress/results/combined-report.html \
  k6 run --insecure-skip-tls-verify \
    -e GW_MTLS="${GW_MTLS}" \
    -e GW_PLAIN="${GW_PLAIN}" \
    -e CERT_DIR="${REPO_ROOT}/tmp/mtls-demo" \
    -e MTLS_VUS=1 -e PLAIN_VUS=1 -e STEADY_DURATION=60s \
    -e RESULTS_DIR=mtls-apikey/stress/results \
    --out json=mtls-apikey/stress/results/combined-raw.json \
    mtls-apikey/stress/k6-stress-combined.js
```

### Combined script env vars

| Env var | Default | Description |
|---|---|---|
| `GW_MTLS` | — | LoadBalancer IP of `external-mtls-apikey` gateway |
| `GW_PLAIN` | — | LoadBalancer IP of `external-plain` gateway |
| `CERT_DIR` | `/tmp/mtls-demo` | Directory with `stress-user-001.crt` / `.key` |
| `MTLS_VUS` | `10` | Peak VUs for mTLS scenario |
| `PLAIN_VUS` | `10` | Peak VUs for plain scenario |
| `MAX_USERS` | `1500` | Random user pool size |
| `RAMP_DURATION` | `30s` | Ramp-up duration |
| `STEADY_DURATION` | `120s` | Steady-state duration |
| `RAMP_DOWN_DURATION` | `15s` | Ramp-down duration |
| `RESULTS_DIR` | `results` | Output directory for `combined-summary.json` |
## Gradual ramp-up strategy (recommended)

Run `setup-stress.sh` once, then escalate:

```bash
# Step 0 — Connectivity check: 1 VU each tier, 60 s steady
MTLS_VUS=1 PLAIN_VUS=1 STEADY_DURATION=60s ./mtls-apikey/stress/run-stress-test.sh

# Step 1 — Warm-up: 10 VUs each tier, 30 s ramp, 60 s steady
MTLS_VUS=10 PLAIN_VUS=10 RAMP_DURATION=30s STEADY_DURATION=60s \
  ./mtls-apikey/stress/run-stress-test.sh

# Step 2 — Medium: 50 VUs each tier, 60 s ramp, 120 s steady
MTLS_VUS=50 PLAIN_VUS=50 RAMP_DURATION=60s STEADY_DURATION=120s \
  ./mtls-apikey/stress/run-stress-test.sh

# Step 3 — Full load: 1500 VUs each tier
MTLS_VUS=1500 PLAIN_VUS=1500 RAMP_DURATION=60s STEADY_DURATION=300s RAMP_DOWN_DURATION=30s \
  ./mtls-apikey/stress/run-stress-test.sh
```

---

## Step-by-step (manual)

### Step 1 — Apply API key Secrets

```bash
./mtls-apikey/stress/gen-api-keys.sh | oc apply -f -
# Verify: oc get secret -n kuadrant-system -l stress-test=true | wc -l
# Expected: 3000
```

### Step 2 — Apply services

```bash
./mtls-apikey/stress/gen-services.sh | oc apply -f -
# Takes ~30-60 s for operator reconciliation
# Verify: oc get httproute -n mtls-apikey -l stress-test=true | wc -l
# Expected: 300
```

### Step 3 — Wait for policies to reconcile

```bash
# Check a sample AuthPolicy
oc get authpolicy stress-svc-001-authpolicy -n mtls-apikey \
  -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" ("}{.reason}{")\n"}{end}'
# Expected: Accepted: True (Accepted)
#           Enforced: True (Enforced)
```

### Step 4 — Get Gateway IPs

```bash
GW_MTLS=$(oc get svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

GW_PLAIN=$(oc get svc -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-plain \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "mTLS GW: $GW_MTLS  |  Plain GW: $GW_PLAIN"
```

### Step 5 — Connectivity check before full load

Verifies auth, CN-binding (OPA), and group authorization **without** triggering
the rate limiter (low request rate at 1 VU << 5 req/10 s basic limit).

#### Option A — k6 connectivity check (automated, both tiers):
```bash
MTLS_VUS=1 PLAIN_VUS=1 STEADY_DURATION=60s ./mtls-apikey/stress/run-stress-test.sh
# 1 VU per tier × 60 s — verifies HTTP 200, no 401, no 403, no TLS errors
```

#### Option B — manual curl smoke (mTLS tier):
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

curl -sk \
  --cert $REPO_ROOT/tmp/mtls-demo/stress-user-001.crt \
  --key  $REPO_ROOT/tmp/mtls-demo/stress-user-001.key \
  --resolve "mtls.mapi.example.com:443:${GW_MTLS}" \
  -H "Authorization: APIKEY STRESS-MTLS-001" \
  https://mtls.mapi.example.com/service-001/cars \
  -w "\nHTTP_STATUS:%{http_code}\n"
# Expected: HTTP_STATUS:200
```

#### Option C — manual curl smoke (plain tier):
```bash
curl -sk \
  --resolve "cert.mapi.example.com:443:${GW_PLAIN}" \
  -H "Authorization: APIKEY STRESS-PLAIN-001" \
  https://cert.mapi.example.com/service-001/cars \
  -w "\nHTTP_STATUS:%{http_code}\n"
# Expected: HTTP_STATUS:200
```

> **What the connectivity check does NOT cover:**
> - Window routing for users 2–1500 (only user-0001 / service-001 is tested)
> - Rate-limit enforcement (Limitador) — use Step 1 warm-up (10 VUs) to verify 429s

### Step 6 — Run k6 (combined — both tiers, single process)

```bash
# Via run-stress-test.sh (recommended)
MTLS_VUS=10 PLAIN_VUS=10 RAMP_DURATION=30s STEADY_DURATION=60s \
  ./mtls-apikey/stress/run-stress-test.sh
```

Live dashboard → **http://localhost:5665**
Report → `mtls-apikey/stress/results/combined-report.html`

---



### Debugging examples

```bash
# Low VU count — debug Authorino / OPA slow ramp
MTLS_VUS=10 PLAIN_VUS=10 \
  RAMP_DURATION=120s SLEEP_MIN=0.5 SLEEP_MAX=1.5 \
  ./mtls-apikey/stress/run-stress-test.sh

# Verify rate-limit at 50 VUs each tier
MTLS_VUS=50 PLAIN_VUS=50 \
  RAMP_DURATION=30s STEADY_DURATION=90s \
  ./mtls-apikey/stress/run-stress-test.sh
```

---

## Observability during the test

Run in separate terminals while k6 is running:

```bash
# 1. Gateway pod count + HPA
watch -n5 'oc get pods -n mtls-apikey --no-headers | wc -l; oc get hpa -n mtls-apikey 2>/dev/null'

# 2. Authorino errors
oc logs -n kuadrant-system -l authorino-resource=authorino --tail=50 -f \
  | grep -E "denied|error|failed"

# 3. Gateway proxy resource usage
watch -n10 'oc adm top pods -n mtls-apikey \
  -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey'
```

---

## Expected results

| Metric | Expected | Reason |
|--------|----------|--------|
| HTTP 200 — all users | > 98% (low VU runs) | At ≤150 VUs / 1500-user pool, rate limits are rarely hit |
| HTTP 429 — basic users | depends on VU/user ratio | See note below |
| HTTP 401 | **0%** | All 3000 keys are valid |
| HTTP 403 | **0%** | Shared cert CN matches `expected-cn` on all 1500 mTLS keys |
| TLS errors (curl exit 56) | **0** | Shared `stress-user-001` cert is CA-signed |
| p95 latency — mTLS | < 2 000 ms | Includes TLS handshake + OPA + Limitador |
| p95 latency — plain | < 1 500 ms | No TLS handshake overhead |
| TLS handshake p95 | < 500 ms | RSA 2048, single shared cert, no per-VU cert switching |
| Authorino pod restarts | **0** | Stability check |
| Limitador pod restarts | **0** | Stability check |

> **HTTP 429 rate depends on the VU-count-to-user-pool ratio.**
> With 150 VUs and 1500-user random pool the per-user hit rate is low (~1 req every few seconds per user)
> so basic users (5 req/10s limit) are rarely rate-limited — expect **< 1% 429s**.
> As VU count approaches or exceeds the user pool size (e.g. 1500 VUs / 1500 users)
> many VUs collide on the same user key and 429s rise sharply — expect **> 90% 429s** for basic users.
> Premium users (100 req/10s limit) see negligible 429s at any tested VU count.
> 429 responses at high load are **expected and correct**: they prove Limitador enforces per-user
> counters accurately across replicas.

---

## Cleanup

```bash
# Remove all generated resources (keeps CA cert and base PoC resources)
./mtls-apikey/stress/cleanup-stress.sh

# Also revert data-plane scaling (Authorino → 1 replica)
REVERT_SCALING=1 ./mtls-apikey/stress/cleanup-stress.sh

# Dry-run (see what would be deleted)
DRY_RUN=1 ./mtls-apikey/stress/cleanup-stress.sh
```

---

## Known limitations

| Limitation | Impact | Workaround |
|-----------|--------|-----------|
| Multi-node cluster: backends (cars/tax) are single-replica | Backend may become the bottleneck before the RHCL data plane | Scale backends: `oc scale deploy/cars deploy/tax --replicas=3 -n mtls-apikey` |
| k6 does not support per-VU cert selection (`tlsAuth` is domain-keyed) | All 1500 mTLS VUs present the same cert (`stress-user-001`) | All 1500 mTLS keys set `expected-cn: stress-user-001` — OPA CN check still executes |
| Rate limits will be hit immediately at 1500 VUs (basic = 5 req/10s) | Test shows 429s quickly | Expected — premium keys (every 10th user idx) still see 200s |
| Connectivity check covers only user-0001 / service-001 | Window routing for users 2–1500 is not checked | Use Step 1 warm-up (10 VUs) for broader coverage |
| `k6-stress-combined.js` uses `options.hosts` for DNS override | No extra CLI flags needed | Requires k6 ≥ 0.46 (`options.hosts` stable since that release) |
| Combined script has no `default` export (uses named exports) | `k6 run` works fine; named exports are the k6 multi-scenario pattern | If you see "no default function" ensure k6 ≥ 0.46 |
