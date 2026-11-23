#!/usr/bin/env bash
# Creates the local code-signing identity Housekeeper is signed with.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) changes its
# fingerprint on every single build. macOS records a Full Disk Access grant
# against that fingerprint, so every update silently revoked the permission the
# reader had already given — and the app then asked again, forever. A stable
# certificate makes the grant survive updates.
#
# It is safe to run more than once. It only creates what is missing.
set -euo pipefail

NAME="Housekeeper Local Signing"
DIR="$HOME/Library/Application Support/Housekeeper/Signing"
KEYCHAIN="$HOME/Library/Keychains/housekeeper-signing.keychain-db"
PASSWORD="housekeeper"

mkdir -p "$DIR"

if [[ ! -f "$DIR/cert.pem" || ! -f "$DIR/key.pem" ]]; then
  echo "Creating the local signing certificate…"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -subj "/CN=$NAME/O=Housekeeper/C=US" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -out "$DIR/identity.p12" \
    -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout "pass:$PASSWORD" >/dev/null 2>&1
  chmod 600 "$DIR/key.pem" "$DIR/identity.p12"
fi

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  security import "$DIR/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

# codesign only sees keychains on the search list.
CURRENT="$(security list-keychains -d user | sed 's/^ *//;s/"//g')"
if ! grep -qx "$KEYCHAIN" <<< "$CURRENT"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $CURRENT "$KEYCHAIN"
fi

# A self-signed certificate is not "valid" (and so codesign will not use it)
# until it is trusted for the code-signing purpose.
if ! security find-identity -v -p codesigning | grep -q "$NAME"; then
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$DIR/cert.pem"
fi

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Signing identity ready: $NAME"
else
  echo "The signing identity could not be made valid. Builds will fall back to ad-hoc signing." >&2
  exit 1
fi
