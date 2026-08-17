#!/usr/bin/env bash
#
# Provisions the APIM governance API used to gate GitHub Copilot CLI traffic.
# Creates a `ghc-governance` API with a POST /moderate operation whose policy
# runs DLP regex + Azure AI Content Safety and returns an allow/block verdict.
#
# Prereqs:
#   - az CLI logged in (az login) with rights on the target subscription
#   - An existing APIM instance
#   - An existing Azure AI Content Safety account
#
# Usage:
#   Edit the variables below (or export them), then run: ./setup-apim.sh
#
set -euo pipefail

# ---- CONFIG (override via env) -------------------------------------------
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}"
RG="${RG:?set RG (resource group of APIM)}"
APIM_NAME="${APIM_NAME:?set APIM_NAME}"
CONTENT_SAFETY_NAME="${CONTENT_SAFETY_NAME:?set CONTENT_SAFETY_NAME}"
CONTENT_SAFETY_RG="${CONTENT_SAFETY_RG:-$RG}"
API_ID="${API_ID:-ghc-governance}"
API_PATH="${API_PATH:-govern}"
# --------------------------------------------------------------------------

echo ">> Using subscription $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"

echo ">> Resolving Content Safety endpoint"
CS_ENDPOINT=$(az cognitiveservices account show \
  -n "$CONTENT_SAFETY_NAME" -g "$CONTENT_SAFETY_RG" \
  --query "properties.endpoint" -o tsv)
echo "   Content Safety endpoint: $CS_ENDPOINT"

echo ">> Ensuring APIM has a system-assigned managed identity"
az apim update -n "$APIM_NAME" -g "$RG" --set identity.type=SystemAssigned -o none || true
APIM_MI=$(az apim show -n "$APIM_NAME" -g "$RG" --query "identity.principalId" -o tsv)
echo "   APIM MI principalId: $APIM_MI"

echo ">> Granting APIM MI 'Cognitive Services User' on Content Safety"
CS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$CONTENT_SAFETY_RG/providers/Microsoft.CognitiveServices/accounts/$CONTENT_SAFETY_NAME"
az role assignment create \
  --assignee-object-id "$APIM_MI" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" --scope "$CS_ID" -o none 2>/dev/null \
  && echo "   role assigned" || echo "   role already present (ok)"

echo ">> Creating API $API_ID (path /$API_PATH)"
az apim api create -g "$RG" -n "$APIM_NAME" --api-id "$API_ID" \
  --display-name "GHC Governance" --path "$API_PATH" --protocols https \
  --service-url "$CS_ENDPOINT" --subscription-required false -o none

echo ">> Creating POST /moderate operation"
az apim api operation create -g "$RG" -n "$APIM_NAME" --api-id "$API_ID" \
  --operation-id moderate --display-name "Moderate" \
  --method POST --url-template "/moderate" -o none

echo ">> Rendering policy with Content Safety endpoint substituted"
POLICY_SRC="$(dirname "$0")/../apim/moderate-policy.xml"
POLICY_TMP="$(mktemp)"
sed "s|__CONTENT_SAFETY_ENDPOINT__|${CS_ENDPOINT%/}|g" "$POLICY_SRC" > "$POLICY_TMP"

echo ">> Applying policy to the operation"
PAYLOAD="$(mktemp)"
python3 - "$POLICY_TMP" "$PAYLOAD" <<'PY'
import json, sys
xml = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(json.dumps({"properties": {"format": "rawxml", "value": xml}}))
PY

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/$API_ID/operations/moderate/policies/policy?api-version=2022-08-01" \
  --headers "Content-Type=application/json" \
  --body "@$PAYLOAD" --output none

GW="https://${APIM_NAME}.azure-api.net/${API_PATH}/moderate"
echo
echo ">> DONE. Moderate endpoint: $GW"
echo "   Test it with:  scripts/test-apim.sh"
echo "   export APIM_MODERATE_URL=$GW"
