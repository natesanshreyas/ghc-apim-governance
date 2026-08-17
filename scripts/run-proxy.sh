#!/usr/bin/env bash
#
# Starts the mitmproxy interception layer with the GHC governance addon.
# It intercepts GitHub Copilot model calls and routes prompts through APIM.
#
# Prereqs:
#   - Python 3.10+  (a venv is created automatically under .venv/)
#   - APIM governance endpoint deployed (see scripts/setup-apim.sh)
#
# Usage:
#   export APIM_MODERATE_URL=https://<apim>.azure-api.net/govern/moderate
#   ./scripts/run-proxy.sh
#
# Then, in ANOTHER terminal, run GHC through it (see scripts/run-ghc.sh).
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.venv"
PORT="${PROXY_PORT:-8080}"

if [ ! -d "$VENV" ]; then
  echo ">> Creating venv and installing mitmproxy"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet mitmproxy
fi

# Generate the mitmproxy CA on first run (idempotent).
if [ ! -f "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" ]; then
  echo ">> Generating mitmproxy CA (first run)"
  timeout 5 "$VENV/bin/mitmdump" -q --listen-port "$PORT" >/dev/null 2>&1 || true
fi

echo ">> mitmproxy CA is at: $HOME/.mitmproxy/mitmproxy-ca-cert.pem"
echo ">> Trust it for GHC by exporting (in the GHC terminal):"
echo "     export NODE_EXTRA_CA_CERTS=\$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
echo "     export HTTPS_PROXY=http://localhost:$PORT HTTP_PROXY=http://localhost:$PORT"
echo
echo ">> APIM gate: ${APIM_MODERATE_URL:-<not set!>}"
echo ">> Starting governed proxy on :$PORT  (Ctrl-C to stop)"
exec "$VENV/bin/mitmdump" --listen-port "$PORT" --set block_global=false \
  -s "$ROOT/proxy/ghc_governance_addon.py"
