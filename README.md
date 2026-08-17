# GHC × APIM Governance (POC)

**Gating GitHub Copilot CLI traffic through Azure API Management (APIM) for DLP + Content Safety.**

This repo is a **proof-of-concept** that inserts an enterprise governance gate
between the GitHub Copilot **CLI** and GitHub's model backend. Prompts are
inspected by **Azure API Management** (DLP regex + **Azure AI Content Safety**)
and **blocked before they reach the model** if they violate policy.

> ⚠️ **Read [`docs/CAVEATS.md`](docs/CAVEATS.md) first.** This uses a TLS-intercepting
> forward proxy (MITM). It is **not an officially supported** GitHub Copilot
> integration and has real trade-offs. It is intended for evaluation only.

---

## Why a proxy is needed (the short version)

GitHub Copilot CLI has **no base-URL / custom-endpoint setting** (unlike, e.g.,
Claude Code's `ANTHROPIC_BASE_URL`). So you cannot simply point it at APIM.
APIM is a **reverse proxy** — it only receives traffic a client is configured to
send it, and GHC won't cooperate.

To insert governance you must **intercept** the CLI's traffic underneath the app,
using two OS/runtime-level levers GHC can't opt out of:

| Lever | What it does |
|-------|--------------|
| `HTTPS_PROXY` | Forces GHC's network library to route every request through the proxy first (via HTTP `CONNECT`). |
| `NODE_EXTRA_CA_CERTS` | Tells Node (GHC's runtime) to trust the proxy's CA, so the proxy can present a forged cert and decrypt (TLS-break) the traffic. |

The proxy decrypts the request, calls **APIM** for a policy verdict, and either
forwards to GitHub (allow) or returns a 403 (block).

```
┌─────────┐  HTTPS_PROXY   ┌───────────────┐   POST /moderate   ┌────────┐
│ GHC CLI │ ─────────────▶ │  mitmproxy    │ ─────────────────▶ │  APIM  │
│ (Node)  │  trusts CA     │  (TLS-break)  │                    │  gate  │
└─────────┘                └───────┬───────┘  allow/block       └───┬────┘
                                   │                                 │
                    allow → forward│                    DLP regex  ──┤
                                   ▼                    Content Safety┘
                          api.individual.githubcopilot.com (GitHub model)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full explanation.

---

## What's in here

| Path | Purpose |
|------|---------|
| `apim/moderate-policy.xml` | APIM operation policy: DLP regex + Content Safety, returns allow/block JSON. |
| `proxy/ghc_governance_addon.py` | mitmproxy addon: intercepts `/v1/messages`, calls APIM, blocks on verdict. |
| `scripts/setup-apim.sh` | Provisions the `ghc-governance` API + policy + managed-identity role grant. |
| `scripts/test-apim.sh` | Tests the APIM `/moderate` endpoint directly (no proxy). |
| `scripts/run-proxy.sh` | Starts mitmproxy with the governance addon (creates venv, generates CA). |
| `scripts/run-ghc.sh` | Runs the real GHC CLI through the proxy with the allow/block test suite. |
| `docs/ARCHITECTURE.md` | How/why it works, layer by layer. |
| `docs/CAVEATS.md` | Honest limitations, risks, and what is / isn't supported. |
| `docs/RESULTS.md` | The live POC results this repo reproduces. |

---

## Prerequisites

- **Azure**: an APIM instance + an Azure AI Content Safety account; `az` CLI logged in with rights to create role assignments.
- **Local**: Python 3.10+, GitHub Copilot CLI installed & authenticated (`copilot --version`).

---

## Quick start

### 1. Deploy the APIM governance API
```bash
export SUBSCRIPTION_ID=<sub-guid>
export RG=<apim-resource-group>
export APIM_NAME=<apim-name>
export CONTENT_SAFETY_NAME=<content-safety-account>
export CONTENT_SAFETY_RG=<content-safety-rg>   # defaults to $RG

./scripts/setup-apim.sh
```
This prints the moderate endpoint, e.g. `https://<apim>.azure-api.net/govern/moderate`.

### 2. Validate the gate directly (no proxy)
```bash
export APIM_MODERATE_URL=https://<apim>.azure-api.net/govern/moderate
./scripts/test-apim.sh
```
Expect: benign → `allow` (200); AKIA key → `block/dlp` (403); toxic → `block/content-safety` (403).

### 3. Start the governed proxy
```bash
export APIM_MODERATE_URL=https://<apim>.azure-api.net/govern/moderate
./scripts/run-proxy.sh          # leave running
```

### 4. Run GHC CLI through it (another terminal)
```bash
./scripts/run-ghc.sh
```
Expect: benign prompts answered; secret/toxic prompts blocked with **0 AI credits**
used (they never reach the model). Watch the proxy terminal for `[APIM GATE]` lines.

---

## Policy tuning

- **DLP patterns**: edit the `dlpHit` regex list in `apim/moderate-policy.xml`
  (AWS keys, SSN, private keys, custom `SECRET-*` tokens by default).
- **Content Safety threshold**: change `maxSev >= 4` in the same file (0–7 severity).
- **Fail-open vs fail-closed**: the proxy addon currently **fails closed** (blocks
  if APIM is unreachable). See `_moderate()` in `proxy/ghc_governance_addon.py`.

---

## Cleanup
```bash
./scripts/teardown-apim.sh   # removes the API + role assignment
# stop the proxy with Ctrl-C; optionally: rm -rf .venv ~/.mitmproxy
```
