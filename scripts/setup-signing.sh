#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate, "ClipHistory Local Signing",
# in your login keychain. scripts/build-app.sh signs with it automatically when it exists.
#
# Why: macOS ties the Accessibility permission to the app's signature. Ad-hoc signatures change
# on every build, so the permission silently stops working after each rebuild. Signing every
# build with the same certificate keeps the permission.
#
# The certificate is not marked as trusted and only signs this app. Remove it any time in
# Keychain Access (login → My Certificates).
set -euo pipefail

NAME="ClipHistory Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL=/usr/bin/openssl # Apple's LibreSSL writes .p12 files that `security import` can read

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists in $KEYCHAIN"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "Created '$NAME' in $KEYCHAIN."
echo "Next: run 'make install'. macOS may ask for your login password once so codesign can use the key; choose Always Allow."
