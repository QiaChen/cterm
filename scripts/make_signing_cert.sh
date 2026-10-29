#!/bin/bash
# Create a self-signed code signing certificate in the login keychain, so
# every build of cTerm is signed with the same identity. The keychain then
# keeps trusting cTerm across rebuilds instead of asking for access again.
#
# Only needed once per Mac. build.sh picks the certificate up by name.
set -euo pipefail

NAME="${1:-cTerm Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "Certificate \"${NAME}\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The system LibreSSL writes a PKCS#12 file that `security import` accepts.
OPENSSL=/usr/bin/openssl
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "${WORK}/cert.cnf" -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null
PASS="$("${OPENSSL}" rand -hex 16)"
"${OPENSSL}" pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -name "${NAME}" -out "${WORK}/identity.p12" -passout "pass:${PASS}"

# -T lets codesign use the private key without asking each time.
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "${PASS}" -T /usr/bin/codesign >/dev/null
echo "Created certificate \"${NAME}\" in the login keychain."
