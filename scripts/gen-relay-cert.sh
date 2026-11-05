#!/usr/bin/env bash
set -euo pipefail

# Generates a self-signed certificate for a local relay test. For a public
# relay, use a real certificate (Let's Encrypt / your reverse proxy) instead.
#
#   ./scripts/gen-relay-cert.sh relay.example.com
#   ./scripts/gen-relay-cert.sh localhost server/certs
#
# Set NB_INSECURE_TLS=1 on the Mac only when testing with a self-signed cert.

HOST="${1:-localhost}"
OUT="${2:-server/certs}"
mkdir -p "$OUT"

if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN="IP:$HOST,IP:127.0.0.1,DNS:localhost"
else
  SAN="DNS:$HOST,DNS:localhost,IP:127.0.0.1"
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$OUT/relay-key.pem" \
  -out "$OUT/relay-cert.pem" \
  -subj "/CN=$HOST" \
  -addext "subjectAltName=$SAN"

chmod 600 "$OUT/relay-key.pem"
chmod 644 "$OUT/relay-cert.pem"

echo "Wrote:"
echo "  $OUT/relay-cert.pem"
echo "  $OUT/relay-key.pem"
echo
echo "Run the relay with:"
echo "  TLS_CERT=$OUT/relay-cert.pem TLS_KEY=$OUT/relay-key.pem PORT=8443 node server/relay.js"
echo
echo "For a self-signed test certificate on the Mac:"
echo "  defaults write com.notifybridge.mac NotifyBridge.network.insecureTLS -bool true"
