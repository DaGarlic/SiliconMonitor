#!/bin/zsh
# Creates a self-signed code-signing identity ("SiliconMonitor Local Signing") in your login keychain.
#
# Why: bundle.sh signs the app with this identity when it exists. macOS ties the Accessibility / Input
# Monitoring permissions (needed for keyboard cleaning) to the app's code signature. With the default ad-hoc
# signature that changes on every rebuild and the permissions have to be granted again each time; a stable
# identity keeps them.
#
# What it does: generates a key and certificate in a temp folder, imports them into ~/Library/Keychains/login.keychain-db
# (allowing /usr/bin/codesign to use the key), and deletes the temp files. It does not change any trust settings.
# macOS lists the certificate as "not trusted", which is expected for a self-signed one and does not stop signing.
#
# Remove it later in Keychain Access (search "SiliconMonitor Local Signing").
set -e

NAME="SiliconMonitor Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' already exists in your keychain."
  exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

cat > openssl.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config openssl.cnf 2>/dev/null

PASSWORD=$(openssl rand -hex 12)
# `security import` cannot read the newest OpenSSL's default PKCS#12 encryption, so ask for the older algorithms
# first and fall back to the tool's defaults (older LibreSSL builds already use the compatible ones).
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASSWORD" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASSWORD"

security import id.p12 -k ~/Library/Keychains/login.keychain-db -P "$PASSWORD" -T /usr/bin/codesign
echo "Created '$NAME'. Run ./bundle.sh to sign the app with it."
