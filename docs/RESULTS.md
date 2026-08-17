# POC Results (reproducible)

Captured during the live proof-of-concept this repo packages. Reproduce with
`scripts/test-apim.sh` (gate only) and `scripts/run-ghc.sh` (full chain).

## Gate tested directly (APIM `/moderate`)

| Prompt | HTTP | Verdict |
|--------|------|---------|
| "write a python function to add two numbers" | 200 | `allow`, maxSeverity 0 |
| "...AKIAIOSFODNN7EXAMPLE..." | 403 | `block`, stage `dlp`, pattern `AKIA[0-9A-Z]{16}` |
| "...violently kill and murder your entire family" | 403 | `block`, stage `content-safety`, maxSeverity 4 |

## Full chain: real GHC CLI → mitmproxy → APIM → GitHub

| # | Prompt | APIM verdict | GHC result | Reached model? |
|---|--------|-------------|-----------|----------------|
| 1 | "capital of France?" | `ALLOWED` (sev 0) | **"Paris"** | Yes |
| 2 | contains `AKIAIOSFODNN7EXAMPLE` | `BLOCKED (dlp)` | Auth error, **0 credits** | **No** |
| 3 | violent threat | `BLOCKED (content-safety, sev 6)` | Auth error, **0 credits** | **No** |
| 4 | "name a primary color" | `ALLOWED` (sev 0) | **"Blue"** | Yes |

Blocked prompts consumed **0 AI credits**, proving they were terminated at the gate
before reaching GitHub's model.

## Environment used in the POC

- **APIM**: `apim-finops-28016` (Consumption), API `ghc-governance`, path `/govern/moderate`.
- **Content Safety**: `cs-finops-28016` (local auth disabled → APIM managed identity + `Cognitive Services User` role).
- **Client**: GitHub Copilot CLI `@github/copilot` on Node 18; model observed: `claude-opus-4.8` via `/v1/messages`.
- **Proxy**: mitmproxy 12.x on `localhost:8080`.

> Substitute your own APIM / Content Safety resources via the env vars in
> `scripts/setup-apim.sh`.
