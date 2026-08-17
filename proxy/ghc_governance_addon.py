"""
GHC governance addon: intercepts GitHub Copilot model calls (/v1/messages),
sends the prompt text to the APIM governance gate (DLP + Content Safety),
and blocks the request (403) before it reaches GitHub if the verdict is 'block'.
"""
from mitmproxy import http
import json, sys, os, urllib.request, urllib.error

# APIM governance endpoint. Override via env var APIM_MODERATE_URL.
APIM_MODERATE = os.environ.get(
    "APIM_MODERATE_URL",
    "https://apim-finops-28016.azure-api.net/govern/moderate",
)
# Optional APIM subscription key if the API requires one.
APIM_KEY = os.environ.get("APIM_SUBSCRIPTION_KEY", "")
# Host whose /v1/messages calls we govern (GitHub Copilot model endpoint).
MODEL_HOST_PATH = os.environ.get("MODEL_MESSAGES_PATH", "/v1/messages")

def _log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()

def _extract_user_text(body):
    """Pull all text from user messages in an Anthropic Messages payload."""
    chunks = []
    for m in body.get("messages", []):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, str):
            chunks.append(c)
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and part.get("type") == "text":
                    chunks.append(part.get("text", ""))
    return "\n".join(chunks)

def _moderate(text):
    payload = json.dumps({"text": text}).encode()
    headers = {"Content-Type": "application/json"}
    if APIM_KEY:
        headers["Ocp-Apim-Subscription-Key"] = APIM_KEY
    req = urllib.request.Request(APIM_MODERATE, data=payload,
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.getcode(), json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {"verdict": "block", "reason": "gate error"}
    except Exception as e:
        # Fail-open vs fail-closed is a policy choice; here we FAIL-CLOSED.
        return 403, {"verdict": "block", "reason": "gate unreachable: %s" % e}

def response(flow: http.HTTPFlow):
    # Decompress every response and strip Content-Encoding so the Node client
    # never has to decode a codec, eliminating intermittent decode errors.
    try:
        flow.response.decode()
    except Exception:
        pass


def request(flow: http.HTTPFlow):
    if MODEL_HOST_PATH not in flow.request.pretty_url:
        return
    try:
        body = json.loads(flow.request.get_text())
    except Exception:
        return
    user_text = _extract_user_text(body)
    if not user_text.strip():
        return
    status, verdict = _moderate(user_text)
    preview = user_text.replace("\n", " ")[:80]
    if verdict.get("verdict") == "block":
        _log("\n[APIM GATE] BLOCKED (%s): %s | prompt: %s" %
             (verdict.get("stage", "?"), verdict.get("reason", verdict), preview))
        # Short-circuit: GHC gets this response, GitHub is never contacted.
        flow.response = http.Response.make(
            403,
            json.dumps({
                "type": "error",
                "error": {
                    "type": "governance_blocked",
                    "message": "Blocked by APIM governance gate: %s (%s)" %
                               (verdict.get("stage", "policy"), verdict.get("reason", "")),
                }
            }).encode(),
            {"Content-Type": "application/json"},
        )
    else:
        _log("\n[APIM GATE] ALLOWED (maxSev=%s) | prompt: %s" %
             (verdict.get("maxSeverity", "?"), preview))
