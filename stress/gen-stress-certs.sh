#!/usr/bin/env bash
# mtls-apikey/stress/gen-stress-certs.sh
#
# Generates the ONE shared client certificate used by all mTLS stress-test VUs.
#
# k6 does not support per-VU cert selection (tlsAuth is domain-keyed, not
# VU-keyed), so all VUs present the same cert: CN=stress-user-001, O=Demo.
# All 1500 mTLS API keys carry kuadrant.io/expected-cn: "stress-user-001".
#
# Output (in <repo-root>/tmp/mtls-demo/):
#   stress-user-001.crt   — client certificate (RSA 2048, SHA-256, 90 days)
#   stress-user-001.key   — private key
#
# Prerequisites:
#   - 06-generate-client-certs.sh must have been run first (CA must exist)
#   - openssl must be available in PATH
#
# Usage:
#   chmod +x gen-stress-certs.sh
#   ./gen-stress-certs.sh
#
# Verify:
#   openssl verify -CAfile $REPO_ROOT/tmp/mtls-demo/ca.crt \
#     $REPO_ROOT/tmp/mtls-demo/stress-user-001.crt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR="$REPO_ROOT/tmp/mtls-demo"

CERT="$OUTDIR/stress-user-001.crt"
KEY="$OUTDIR/stress-user-001.key"
CSR="$OUTDIR/stress-user-001.csr"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ ! -f "$OUTDIR/ca.crt" || ! -f "$OUTDIR/ca.key" ]]; then
  echo "❌ CA not found in $OUTDIR"
  echo "   Run mtls-apikey/02-generate-client-certs.sh first."
  exit 1
fi

if [[ ! -f "$OUTDIR/x509v3-client.ext" ]]; then
  echo "── Recreating x509v3-client.ext (clientAuth EKU) ──────────────────────────"
  cat > "$OUTDIR/x509v3-client.ext" << 'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
fi

echo "── CA subject ──"
openssl x509 -in "$OUTDIR/ca.crt" -noout -subject

echo ""
echo "── Generating shared stress cert: stress-user-001 (RSA 2048, SHA-256, 90 days) ──"
echo "   CN=stress-user-001, O=Demo"
echo "   Output: $OUTDIR/stress-user-001.{crt,key}"
echo ""

# Skip if cert already exists, is still valid (> 7 days remaining),
# AND was signed by the current CA (detect CA rotation).
if [[ -f "$CERT" ]]; then
  # Extract Subject Key Identifier from CA and Authority Key Identifier from client cert
  CA_SKI=$(openssl x509 -in "$OUTDIR/ca.crt" -noout -ext subjectKeyIdentifier 2>/dev/null \
           | grep -v 'Subject Key Identifier' | tr -d ' :')
  CERT_AKI=$(openssl x509 -in "$CERT" -noout -ext authorityKeyIdentifier 2>/dev/null \
             | grep -v 'Authority Key Identifier' | tr -d ' :')

  if [[ "$CA_SKI" != "$CERT_AKI" ]]; then
    echo "⚠️  CA has been rotated (key identifiers differ) — regenerating client cert"
    rm -f "$CERT" "$KEY"
  elif openssl x509 -in "$CERT" -noout -checkend 604800 2>/dev/null; then
    echo "✅ stress-user-001.crt already exists and is valid — skipping generation"
    SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
    EXPIRY=$(openssl x509 -in "$CERT"  -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    echo "   ${SUBJECT} | expires: ${EXPIRY}"
    exit 0
  else
    echo "⚠️  stress-user-001.crt exists but expires soon — regenerating"
  fi
fi

# Generate key
openssl genrsa -out "$KEY" 2048 2>/dev/null

# Generate CSR
openssl req -new \
  -subj "/CN=stress-user-001/O=Demo" \
  -key  "$KEY" \
  -out  "$CSR" \
  2>/dev/null

# Sign with CA
openssl x509 -req -sha256 -days 90 \
  -CA    "$OUTDIR/ca.crt" \
  -CAkey "$OUTDIR/ca.key" \
  -CAcreateserial \
  -extfile "$OUTDIR/x509v3-client.ext" \
  -in  "$CSR" \
  -out "$CERT" \
  2>/dev/null

# Remove CSR (not needed after signing)
rm -f "$CSR"

echo "✅ Done"
echo ""
echo "── Verification ────────────────────────────────────────────────────────────"
SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
EXPIRY=$(openssl x509  -in "$CERT" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
VERIFY=$(openssl verify -CAfile "$OUTDIR/ca.crt" "$CERT" 2>&1 | grep -v "^$")
echo "   ${SUBJECT} | expires: ${EXPIRY} | ${VERIFY}"
