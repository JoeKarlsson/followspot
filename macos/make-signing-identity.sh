#!/usr/bin/env bash
# Create a self-signed code-signing identity, "Followspot Local Signing", in
# the login keychain. build.sh signs with it when it exists.
#
#   macos/make-signing-identity.sh
#
# Why: an ad-hoc signature changes on every build, and macOS keys camera,
# microphone, and Documents permissions to the signature, so each rebuild
# asked again. A fixed certificate gives every build the same identity. It's
# only for builds on this Mac; it isn't a Developer ID and doesn't help
# Gatekeeper on other Macs. Remove it in Keychain Access to undo.
set -euo pipefail

NAME="Followspot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in your login keychain."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A throwaway password: the .p12 only exists for the import below.
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in your login keychain. build.sh will sign with it."
