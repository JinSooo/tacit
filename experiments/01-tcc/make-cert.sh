#!/bin/sh
# 在独立的钥匙串里创建一张自签名代码签名证书（不动登录钥匙串）。删除：security delete-keychain "$KC"
set -e
KC="$HOME/Library/Keychains/ra-dev.keychain-db"
PASSFILE="$(dirname "$0")/.keychain-pass"
[ -f "$PASSFILE" ] || head -c 24 /dev/urandom | base64 > "$PASSFILE"
PASS="$(cat "$PASSFILE")"
[ -f "$KC" ] || security create-keychain -p "$PASS" "$KC"
security unlock-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
if security find-certificate -c "Record Anything Dev" "$KC" >/dev/null 2>&1; then echo "cert exists"; exit 0; fi
T="$(mktemp -d)"
cat > "$T/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Record Anything Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/key.pem" -out "$T/cert.pem" -config "$T/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:tmp
security import "$T/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
rm -rf "$T"
echo "cert created"
