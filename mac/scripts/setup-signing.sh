#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity "NetDisplay Dev"
# in the login keychain. A stable identity gives the signature a stable
# Designated Requirement, so macOS keeps the Screen-Recording TCC grant across
# rebuilds (otherwise you'd re-authorize every build).
#
# Run once:  bash scripts/setup-signing.sh
set -euo pipefail

NAME="NetDisplay Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$NAME"; then
  echo "✅ Signing identity '$NAME' already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > ext.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = NetDisplay Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config ext.cnf
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout pass:netdisplay -name "$NAME"
security import id.p12 -k "$KEYCHAIN" -P netdisplay -T /usr/bin/codesign -A
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem

echo ""
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$NAME"; then
  echo "✅ Created signing identity '$NAME'."
else
  echo "⚠️  Identity created but not valid for code signing — check keychain trust settings."
fi
