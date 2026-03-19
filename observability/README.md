# Observability overlay

Applies the Red Hat Connectivity Link v1.3.0 OpenShift-specific observability base, with one additional patch to fix the Istio `Telemetry` CR namespace for this cluster (Gateways live in `mtls-apikey`, not `openshift-ingress`).

```bash
oc apply -k observability/
```

## Base

[`github.com/Kuadrant/kuadrant-operator/config/install/configure/observability/openshift?ref=v1.3.0`](https://github.com/Kuadrant/kuadrant-operator/blob/v1.3.0/config/install/configure/observability/openshift/kustomization.yaml)

Already includes patches for `openshift-ingress` (istiod ServiceMonitor) and `openshift-operators` (ServiceMonitors namespace). We only override the `Telemetry` namespace.

## Resources created per namespace

| Namespace | Resources |
|---|---|
| `monitoring` | `Namespace`, `ServiceAccount`, `ClusterRole/Binding`, `ConfigMap` (custom-resource-state), `Service`, `Deployment`, `ServiceMonitor` — all for `kube-state-metrics-kuadrant` |
| `kuadrant-system` | `ServiceMonitor` ×4 — scrapes authorino-operator, dns-operator, kuadrant-operator, limitador-operator |
| `openshift-ingress` | `ServiceMonitor/istiod` — scrapes `istiod-openshift-gateway` on port `http-monitoring` (15014) |
| `openshift-operators` | `Subscription/grafana-operator` — installs Grafana Operator via OLM |
| `mtls-apikey` | `Telemetry/namespace-metrics` ×2 — adds `request_url_path` / `request_host` / `destination_port` tags to Istio `REQUEST_COUNT` / `REQUEST_DURATION` metrics |

## Patch applied over upstream base

| What | Why |
|---|---|
| `Telemetry/namespace-metrics` namespace → `mtls-apikey` | Upstream v1.3.0 defaults to `openshift-ingress`; must match the Gateway namespace for Istio to apply the metric overrides |

## Next step: Grafana instance + dashboards ✅

The Grafana instance, datasource, and dashboards have been deployed from the upstream grafana overlay.
Steps followed:

```bash
# From a clone of kuadrant-operator (or use the remote URL)
TOKEN="Bearer $(oc whoami -t)"
HOST="$(oc -n openshift-monitoring get route thanos-querier \
        -o jsonpath='https://{.status.ingress[].host}')"

echo "TOKEN=$TOKEN" > config/observability/openshift/grafana/datasource.env
echo "HOST=$HOST"   >> config/observability/openshift/grafana/datasource.env

oc apply -k config/observability/openshift/grafana
```

This created in namespace `monitoring`:
- `ConfigMap/datasource-env-config-*`
- `Grafana/grafana` (v10.4.3, admin: root/secret)
- `GrafanaDatasource/thanos-query-ds` → Thanos Querier via `oc whoami -t` token
- `GrafanaDashboard` ×6: `app-developer`, `business-user`, `platform-engineer`, `controller-resources-metrics`, `controller-runtime-metrics`, `dns-operator`

> ⚠️ The `datasource.env` file contains a bearer token — never commit it to git (already in `.gitignore` of the upstream grafana dir).

To get the Grafana URL:
```bash
oc get route grafana-route -n monitoring -o jsonpath='{.spec.host}'
```

### Dashboard ConfigMaps ✅

Dashboard JSON ConfigMaps deployed separately (must be in `monitoring` ns to match the `GrafanaDashboard` `configMapRef`):

```bash
oc apply -k https://github.com/Kuadrant/kuadrant-operator/examples/dashboards?ref=v1.3.0
```

Created in namespace `monitoring`:
- `ConfigMap/grafana-app-developer`
- `ConfigMap/grafana-business-user`
- `ConfigMap/grafana-platform-engineer`
- `ConfigMap/grafana-controller-resources-metrics`
- `ConfigMap/grafana-controller-runtime-metrics`
- `ConfigMap/grafana-dns-operator`

Login: `https://grafana-route-monitoring.apps.<cluster>/login` — **root / secret**

### Fix: Grafana Operator cross-namespace RBAC ✅

The Grafana Operator runs in `openshift-operators` but watches resources in `monitoring`. A `RoleBinding` is needed so it can read ConfigMaps:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: grafana-operator-read-configmaps
  namespace: monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: ServiceAccount
  name: grafana-operator-controller-manager
  namespace: openshift-operators
EOF
```

After applying, delete the operator pod to force reconcile:
```bash
oc delete pod -n openshift-operators -l app.kubernetes.io/name=grafana-operator
```
