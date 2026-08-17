# Caveats, Risks & Support Status

**Read this before drawing conclusions from the POC.** This approach works, but it
is a workaround with real trade-offs.

## 1. This is NOT an officially supported integration

GitHub Copilot does not provide a supported way to route its traffic (especially
inline completions) through a third-party gateway. This POC uses a **TLS-intercepting
forward proxy (MITM)**. Officially supported alternatives are narrower:

| Want to govern… | Supported path? |
|-----------------|-----------------|
| **VS Code Copilot Chat** | ✅ **BYOK "Custom Endpoint"** → point Chat at APIM (admin must enable the *"Bring Your Own Language Model Key in VS Code"* org policy). Chat only. |
| VS Code **inline completions** | ❌ Always served by GitHub's backend; cannot be redirected. |
| **GHC CLI** (this repo) | ❌ No supported mechanism → MITM only. |

If the goal is a *supported* architecture, prefer **VS Code Chat + BYOK → APIM**
over intercepting the CLI.

## 2. Legal / policy risk

TLS-intercepting and decrypting traffic to a SaaS you don't own may conflict with
**GitHub's Terms of Service** and your org's security policy. Get sign-off before
using beyond an isolated evaluation.

## 3. Certificate pinning is the make-or-break unknown

Interception only works because GHC (via Node) trusts the OS/`NODE_EXTRA_CA_CERTS`
store. In this POC, **GHC did not pin** GitHub's cert, so interception succeeded.
A future client update could add pinning and break this overnight — you'd see TLS
validation failures even with the CA trusted.

## 4. Reliability: intermittent interception errors

During the POC, intercepting `api.github.com` occasionally produced:
- `error decoding response body` (client couldn't decompress the response), and
- transient `503` on the auth/entitlement call.

Mitigations applied in this repo:
- A global `response.decode()` in the addon strips content-encoding so the Node
  client never has to decompress (removes the decode-error path).

Separately, GitHub may return `503` on `copilot_internal/user` under **high
request volume from a single token** (observed after running many prompts in
quick succession — it reproduces **with and without** the proxy, so it is
GitHub-side throttling, not the gate). Space out requests or use a fresh session.

Still, a production rollout needs **retry/backoff** and careful handling of the
non-model endpoints. This is a POC, not hardened.

## 5. Blocked-request UX is crude

On a block, GHC currently surfaces a generic **"Authorization error, you may need
to run /login"** rather than a clean "blocked by policy" message, because the
synthetic 403 body doesn't match GitHub's exact error schema. The *governance*
works (0 AI credits consumed, model never reached); only the user-facing message
is imperfect. Improving it requires matching GitHub's error response shape.

## 6. Scope of governance

- Only the **model call** (`/v1/messages`) is inspected. Auth, telemetry, and
  model-list calls are forwarded untouched.
- Only **prompt (inbound)** governance is implemented here. Response (outbound)
  redaction is possible via the addon's `response()` hook but is not enabled.
- DLP is **regex-based** (illustrative). Real DLP should use a dedicated engine or
  Azure Content Safety's PII/Prompt Shields features.

## 7. "Copilot OpenTelemetry" does not exist

GHC does **not** emit OpenTelemetry. It sends proprietary telemetry to
`telemetry.individual.githubcopilot.com`. Per-request observability is only
available for traffic you route through your own gateway (as in this POC, for
chat/model calls). Org-level usage data comes from GitHub's **Copilot Metrics API**,
which is aggregate — not per-prompt, not OTEL.

## 8. Fail-open vs fail-closed

The proxy addon **fails closed** (blocks if APIM is unreachable). Flip this in
`_moderate()` if availability matters more than enforcement in your context.
