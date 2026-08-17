# Architecture

## The core problem

GitHub Copilot CLI (`@github/copilot`, a Node.js app) talks directly to GitHub's
endpoints and has **no setting to change its base URL**. To govern its traffic you
cannot ask it to use APIM; you must intercept it transparently.

### Two levers that work *underneath* the application

| Lever | Layer | Effect |
|-------|-------|--------|
| `HTTPS_PROXY` | OS / network library | GHC's HTTP stack sends every request to the proxy first via HTTP `CONNECT host:443`. GHC can't opt out — it happens below the app. |
| `NODE_EXTRA_CA_CERTS` | Node.js runtime | Adds the proxy's CA to Node's trusted roots, so a forged server cert validates. GHC never checks certs itself; Node's TLS layer does. |

## What mitmproxy actually does (TLS interception)

Normally GHC↔GitHub is one end-to-end encrypted tunnel nobody can read.
mitmproxy turns it into **two** tunnels with a readable gap:

```
GHC ═══ TLS #1 ═══ mitmproxy ═══ TLS #2 ═══ GitHub
                       │
                  plaintext here → policy / APIM
```

1. **Accept CONNECT** — GHC asks the proxy to reach `api.individual.githubcopilot.com:443`.
2. **Impersonate GitHub (TLS #1)** — mitmproxy mints a leaf cert for that host,
   signed by its own CA (which you trusted via `NODE_EXTRA_CA_CERTS`), and completes
   the handshake as if it were GitHub.
3. **Decrypt** — the request body (the prompt) is now plaintext.
4. **Govern** — the addon extracts the prompt and `POST`s it to APIM `/moderate`.
5. **Re-originate (TLS #2)** — on *allow*, mitmproxy opens its own real TLS to
   GitHub and forwards. On *block*, it returns a synthetic 403 and GitHub is never
   contacted.

## The APIM gate

`ghc-governance` API → `POST /moderate` operation. Its policy (`apim/moderate-policy.xml`)
runs entirely in the **inbound** stage and short-circuits with `return-response`:

1. **DLP regex** over the prompt (`dlpHit`): AWS keys, SSN, PEM private keys,
   `SECRET-*`. Any match → `403 {verdict:block, stage:dlp}`.
2. **Content Safety** — `send-request` to Azure AI Content Safety
   `text:analyze`, authenticated with APIM's **system-assigned managed identity**
   (`authentication-managed-identity`, resource `https://cognitiveservices.azure.com`).
   Max category severity `>= 4` → `403 {verdict:block, stage:content-safety}`.
3. Otherwise → `200 {verdict:allow, maxSeverity:n}`.

Because the verdict is produced in inbound and returned directly, the API's
`service-url` backend is never actually called for allow/block decisions — APIM
acts purely as a policy engine here.

### Why managed identity (not keys)?

The Content Safety accounts in the POC have `disableLocalAuth=true` (no API keys),
which is the recommended enterprise posture. APIM's managed identity is granted the
**Cognitive Services User** role on the Content Safety account by `setup-apim.sh`.

## Request flow, end to end

```
copilot -p "…"                     (Node process)
  └─ HTTPS_PROXY → mitmproxy:8080
       ├─ api.github.com/*                  (auth/entitlement)  → tunneled/forwarded
       ├─ api.individual.githubcopilot.com/v1/messages          → INTERCEPTED
       │     └─ addon extracts prompt → APIM POST /moderate
       │           ├─ allow → forward to GitHub → model responds
       │           └─ block → 403 to GHC (0 AI credits, model never sees it)
       └─ telemetry.individual.githubcopilot.com/telemetry      → forwarded
```

## Known endpoints observed

| Endpoint | Role |
|----------|------|
| `api.github.com/copilot_internal/user` | auth / entitlement check |
| `api.individual.githubcopilot.com/v1/messages` | **the model call** (Anthropic Messages format) — governed here |
| `api.individual.githubcopilot.com/models` | model list |
| `telemetry.individual.githubcopilot.com/telemetry` | GitHub's proprietary telemetry (not OpenTelemetry) |
