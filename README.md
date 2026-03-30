# 🔐 mTLS + API Key — Dual-Gateway PoC

**Ref:** [Kuadrant/architecture#140](https://github.com/Kuadrant/architecture/issues/140) | **Docs:** [RHCL 1.3](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3)

Two Gateways, same HTTPRoutes + AuthPolicies:

| Gateway | Hostname | Requirement |
|---------|----------|-------------|
| `external-mtls-apikey` | `mtls.mapi.example.com` | mTLS client cert **+** API key (CN binding enforced) |
| `external-plain` | `cert.mapi.example.com` | API key only |

**Why split across layers:** `AuthPolicy.authentication` is OR — to enforce a true AND (cert + key), mTLS is enforced at the Envoy level (EnvoyFilter), and CN↔key binding is enforced in OPA `authorization` (priority 0). The decision lives in the API key Secret annotation `kuadrant.io/mtls-required`, not in routing logic.

---

## 📁 Files

```
00-namespace.yaml               # Namespace: mtls-apikey
01-backend-app.yaml             # cars + tax Deployments + Services
02-generate-client-certs.sh     # Generates CA + client certs → tmp/mtls-demo/
03-client-ca-secret.yaml.skip   # CA Secret (created by script — do not apply manually)
04-gateway-infra-configmap.yaml # Mounts CA cert into mTLS proxy pod
05-gateway-mtls.yaml            # Gateway: external-mtls-apikey
05b-gateway-plain.yaml          # Gateway: external-plain
06-tlspolicy-mtls.yaml          # TLSPolicy for external-mtls-apikey
06-tlspolicy-plain.yaml         # TLSPolicy for external-plain
07-envoyfilter-mtls.yaml        # requireClientCertificate + XFCC injection
08-httproute.yaml               # cars-route + tax-route (parentRefs: both gateways)
09-api-keys.yaml                # API key Secrets — mtls-required=true/false tiers
10-authpolicy-cars.yaml         # API key auth + OPA CN binding (p0) + group check (p1)
11-authpolicy-tax.yaml
12-ratelimitpolicy-cars.yaml    # Per-user rate limits: premium 100/10s, basic 5/10s
13-ratelimitpolicy-tax.yaml     # Per-user rate limits: premium 10/10s,  basic 5/10s
stress/                         # Load test (k6) — see stress/README.md
```

> For a stress-test environment: deploy the **full base PoC** (`00`–`13`) first, then run [`stress/setup-stress.sh`](stress/setup-stress.sh) followed by [`stress/run-stress-test.sh`](stress/run-stress-test.sh).

---

## 👥 Clients

| Cert / Key | CN / user-id | Group | Level | Gateway |
|------------|-------------|-------|-------|---------|
| `client-insurance-user` | `insurance-user` | `car` | basic | mTLS |
| `client-accountant-user` | `accountant-user` | `tax` | basic | mTLS |
| `client-accountant-director` | `accountant-director` | `tax` | premium | mTLS |
| `PLAIN-CAR` | `plain-car-user` | `car` | basic | plain |
| `PLAIN-TAX` | `plain-tax-user` | `tax` | basic | plain |

---

## 🚀 Setup

**Prerequisites:** OpenShift + RHCL 1.3+, Istio/Sail Operator, cert-manager, `ClusterIssuer` `self-signed` (from [`../02-clusterissuer.yaml`](../02-clusterissuer.yaml))

```bash
# 1. Generate CA + client certs (also creates the CA Secret in the cluster)
./mtls-apikey/02-generate-client-certs.sh

# 2. Namespace + backends
oc apply -f mtls-apikey/00-namespace.yaml
oc apply -f mtls-apikey/01-backend-app.yaml

# 3. Gateway infrastructure
oc apply -f mtls-apikey/04-gateway-infra-configmap.yaml
oc apply -f mtls-apikey/05-gateway-mtls.yaml
oc apply -f mtls-apikey/05b-gateway-plain.yaml
oc apply -f mtls-apikey/06-tlspolicy-mtls.yaml
oc apply -f mtls-apikey/06-tlspolicy-plain.yaml

# Wait for server certs
oc wait tlspolicy gw-external-mtls-apikey-tls -n mtls-apikey --for=condition=Accepted --timeout=120s
oc wait tlspolicy gw-external-plain-tls       -n mtls-apikey --for=condition=Accepted --timeout=120s

# 4. EnvoyFilter + routes
oc apply -f mtls-apikey/07-envoyfilter-mtls.yaml
oc apply -f mtls-apikey/08-httproute.yaml

# 5. Auth + rate limiting
oc apply -f mtls-apikey/09-api-keys.yaml
oc apply -f mtls-apikey/10-authpolicy-cars.yaml
oc apply -f mtls-apikey/11-authpolicy-tax.yaml
oc apply -f mtls-apikey/12-ratelimitpolicy-cars.yaml
oc apply -f mtls-apikey/13-ratelimitpolicy-tax.yaml
```

---

## 🧪 Testing

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
GW_MTLS=$(oc get svc -n mtls-apikey -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
GW_PLAIN=$(oc get svc -n mtls-apikey -l gateway.networking.k8s.io/gateway-name=external-plain \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
```

### ✅ Happy path

```bash
# mTLS: insurance cert + INSURANCE key → /cars → 200
curl -sk --cert $REPO_ROOT/tmp/mtls-demo/client-insurance-user.crt \
         --key  $REPO_ROOT/tmp/mtls-demo/client-insurance-user.key \
         --resolve "mtls.mapi.example.com:443:$GW_MTLS" \
         -H "Authorization: APIKEY INSURANCE" https://mtls.mapi.example.com/cars -i

# Plain: no cert + PLAIN-CAR key → /cars → 200
curl -sk --resolve "cert.mapi.example.com:443:$GW_PLAIN" \
         -H "Authorization: APIKEY PLAIN-CAR" https://cert.mapi.example.com/cars -i
```

### ❌ Blocked cases

| Scenario | Expected |
|----------|----------|
| No client cert on mTLS gateway | `000` TLS alert |
| Valid cert, no API key | `401` |
| Anti-swap: insurance cert + ACCOUNTANT key | `403` CN mismatch |
| Wrong group (car key → `/tax`) | `403` |
| `mtls-required=true` key on plain gateway | `403` no XFCC |
| Basic user > 5 req/10s | `429` |

> **`-k` is always required** — server certs are self-signed via cert-manager.

---

## Hardening notes (beyond PoC)

- Use cert **fingerprint** binding instead of CN for stronger identity
- CA rotation: update `mtls-client-ca-secret` + restart gateway pod:
  ```bash
  oc rollout restart deployment -n mtls-apikey \
    -l gateway.networking.k8s.io/gateway-name=external-mtls-apikey
  ```
- XFCC header is **lower-cased** by Envoy → use `x-forwarded-client-cert` in OPA
