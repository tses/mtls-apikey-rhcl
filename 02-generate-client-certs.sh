#!/usr/bin/env bash
# mtls-apikey/06-generate-client-certs.sh
#
# Generates a private client CA and three client certificates for the
# mTLS + API Key combined authentication PoC.
# Creates the CA Secret in the mtls-apikey namespace only.
#
# PoC simplification: CN == secret.kuadrant.io/user-id == kuadrant.io/expected-cn
# No OU is used — CN is the sole binding anchor between the cert and the API key Secret.
#
# Clients:
#   CN=insurance-user    → INSURANCE key    (car group,  basic   level)
#   CN=accountant-user   → ACCOUNTANT key   (tax group,  basic   level)
#   CN=accountant-director → ACCOUNTANT-DIRECTOR key (tax group, premium level)
#
# Usage:
#   chmod +x 06-generate-client-certs.sh
#   ./06-generate-client-certs.sh
#
# Output files:
#   <repo-root>/tmp/mtls-demo/ca.{crt,key}
#   <repo-root>/tmp/mtls-demo/client-insurance-user.{crt,key}       (CN=insurance-user)
#   <repo-root>/tmp/mtls-demo/client-accountant-user.{crt,key}      (CN=accountant-user)
#   <repo-root>/tmp/mtls-demo/client-accountant-director.{crt,key}  (CN=accountant-director)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$REPO_ROOT/tmp/mtls-demo"
NS="mtls-apikey"

mkdir -p "$OUTDIR"

# ── x509v3 extension file for CLIENT certs ────────────────────────────────────
# Marks the cert as a non-CA leaf with clientAuth EKU — required for mTLS
cat > "$OUTDIR/x509v3-client.ext" << 'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

echo "── Generating client CA ──────────────────────────────────────────────────"
openssl req -x509 -sha512 -nodes \
  -days 3650 \
  -newkey rsa:4096 \
  -subj "/CN=mtls-demo-ca/O=Demo/OU=Platform" \
  -addext "basicConstraints=CA:TRUE" \
  -addext "keyUsage=keyCertSign,cRLSign" \
  -keyout "$OUTDIR/ca.key" \
  -out    "$OUTDIR/ca.crt"

echo "── Generating client cert: insurance-user (CN=insurance-user, car/basic) ─"
openssl genrsa -out "$OUTDIR/client-insurance-user.key" 4096
openssl req -new \
  -subj "/CN=insurance-user/O=Demo" \
  -key  "$OUTDIR/client-insurance-user.key" \
  -out  "$OUTDIR/client-insurance-user.csr"
openssl x509 -req -sha512 -days 365 \
  -CA "$OUTDIR/ca.crt" -CAkey "$OUTDIR/ca.key" -CAcreateserial \
  -extfile "$OUTDIR/x509v3-client.ext" \
  -in  "$OUTDIR/client-insurance-user.csr" \
  -out "$OUTDIR/client-insurance-user.crt"

echo "── Generating client cert: accountant-user (CN=accountant-user, tax/basic) ─"
openssl genrsa -out "$OUTDIR/client-accountant-user.key" 4096
openssl req -new \
  -subj "/CN=accountant-user/O=Demo" \
  -key  "$OUTDIR/client-accountant-user.key" \
  -out  "$OUTDIR/client-accountant-user.csr"
openssl x509 -req -sha512 -days 365 \
  -CA "$OUTDIR/ca.crt" -CAkey "$OUTDIR/ca.key" -CAcreateserial \
  -extfile "$OUTDIR/x509v3-client.ext" \
  -in  "$OUTDIR/client-accountant-user.csr" \
  -out "$OUTDIR/client-accountant-user.crt"

echo "── Generating client cert: accountant-director (CN=accountant-director, tax/premium) ─"
openssl genrsa -out "$OUTDIR/client-accountant-director.key" 4096
openssl req -new \
  -subj "/CN=accountant-director/O=Demo" \
  -key  "$OUTDIR/client-accountant-director.key" \
  -out  "$OUTDIR/client-accountant-director.csr"
openssl x509 -req -sha512 -days 365 \
  -CA "$OUTDIR/ca.crt" -CAkey "$OUTDIR/ca.key" -CAcreateserial \
  -extfile "$OUTDIR/x509v3-client.ext" \
  -in  "$OUTDIR/client-accountant-director.csr" \
  -out "$OUTDIR/client-accountant-director.crt"

echo "── Verifying certificate chains ──────────────────────────────────────────"
openssl verify -CAfile "$OUTDIR/ca.crt" "$OUTDIR/client-insurance-user.crt"
openssl verify -CAfile "$OUTDIR/ca.crt" "$OUTDIR/client-accountant-user.crt"
openssl verify -CAfile "$OUTDIR/ca.crt" "$OUTDIR/client-accountant-director.crt"

echo "── Creating Secret in namespace: $NS ────────────────────────────────────"
oc create secret generic mtls-client-ca-secret \
  --namespace "$NS" \
  --from-file=ca.crt="$OUTDIR/ca.crt" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "✅ Done. Files in $OUTDIR:"
ls -1 "$OUTDIR"
echo ""
echo "=== CA cert subject/issuer ==="
openssl x509 -in "$OUTDIR/ca.crt" -noout -issuer -subject -dates

echo ""
echo "=== insurance-user (CN=insurance-user, car/basic) — subject + EKU ==="
openssl x509 -in "$OUTDIR/client-insurance-user.crt" -noout -subject
openssl x509 -in "$OUTDIR/client-insurance-user.crt" -noout -text \
  | grep -A2 "Extended Key Usage" || true

echo ""
echo "=== accountant-user (CN=accountant-user, tax/basic) — subject + EKU ==="
openssl x509 -in "$OUTDIR/client-accountant-user.crt" -noout -subject
openssl x509 -in "$OUTDIR/client-accountant-user.crt" -noout -text \
  | grep -A2 "Extended Key Usage" || true

echo ""
echo "=== accountant-director (CN=accountant-director, tax/premium) — subject + EKU ==="
openssl x509 -in "$OUTDIR/client-accountant-director.crt" -noout -subject
openssl x509 -in "$OUTDIR/client-accountant-director.crt" -noout -text \
  | grep -A2 "Extended Key Usage" || true
