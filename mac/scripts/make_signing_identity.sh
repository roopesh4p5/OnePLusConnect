#!/bin/zsh
# Creates a self-signed "One+Connect Dev" code signing identity in its own keychain.
# Why: TCC (Screen Recording / Accessibility) keys grants to the app's code signature.
# An ad-hoc signature changes on every build, so macOS re-prompts and forces a relaunch.
# Signing with this stable identity keeps the grants across rebuilds.
# Usage: mac/scripts/make_signing_identity.sh   (run once; safe to re-run)
set -euo pipefail
NAME="One+Connect Dev"
KC="$HOME/Library/Keychains/oneplusconnect-dev.keychain-db"
PW="oneplusconnect"   # keychain password; only protects this dev cert
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cs.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Pacewisdom
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cs.cnf -keyout key.pem -out cert.pem 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -passout "pass:$PW" -out dev.p12 -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -passout "pass:$PW" -out dev.p12

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$PW" "$KC"
security import dev.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# Add to the user's keychain search list (keeps login keychain first).
security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"
# Trust the cert for code signing (user trust domain; macOS may show an auth dialog).
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" cert.pem || true

echo
security find-identity -v -p codesigning | grep -F "$NAME" && echo "Identity ready: $NAME" \
  || { echo "Identity was imported but is not listed as valid. Open Keychain Access, find '$NAME', set Trust → Code Signing → Always Trust."; exit 1; }
echo "Next: mac/scripts/build_app.sh && mac/scripts/install_app.sh --reset-permissions"
