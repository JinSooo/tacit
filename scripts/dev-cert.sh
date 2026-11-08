#!/bin/sh
# 在独立钥匙串里创建固定的自签名代码签名证书。证书不换，重新构建后系统权限就不会丢（实验 0-A）。
# 钥匙串密码放在 ~/Library/Keychains/ra-dev.pass（0600）。删除：security delete-keychain ~/Library/Keychains/ra-dev.keychain-db
set -e
KC="$HOME/Library/Keychains/ra-dev.keychain-db"
PASSFILE="$HOME/Library/Keychains/ra-dev.pass"
OLD="$(cd "$(dirname "$0")/.." && pwd)/experiments/01-tcc/.keychain-pass"
if [ ! -f "$PASSFILE" ]; then
  umask 077
  if [ -f "$OLD" ]; then cp "$OLD" "$PASSFILE"; else head -c 24 /dev/urandom | base64 > "$PASSFILE"; fi
fi
PASS="$(cat "$PASSFILE")"
[ -f "$KC" ] || security create-keychain -p "$PASS" "$KC"
security unlock-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
if security find-certificate -c "Record Anything Dev" "$KC" >/dev/null 2>&1; then exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
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
security import "$T/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
echo "已创建证书 Record Anything Dev"
