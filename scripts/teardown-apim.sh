#!/usr/bin/env bash
#
# Removes the APIM governance API and the managed-identity role assignment.
# Does NOT delete APIM or the Content Safety account.
#
set -uo pipefail
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}"
RG="${RG:?set RG}"
APIM_NAME="${APIM_NAME:?set APIM_NAME}"
API_ID="${API_ID:-ghc-governance}"
CONTENT_SAFETY_NAME="${CONTENT_SAFETY_NAME:-}"
CONTENT_SAFETY_RG="${CONTENT_SAFETY_RG:-$RG}"

az account set --subscription "$SUBSCRIPTION_ID"

echo ">> Deleting API $API_ID"
az apim api delete -g "$RG" -n "$APIM_NAME" --api-id "$API_ID" --delete-revisions true -y -o none \
  && echo "   deleted" || echo "   not found (ok)"

if [ -n "$CONTENT_SAFETY_NAME" ]; then
  APIM_MI=$(az apim show -n "$APIM_NAME" -g "$RG" --query "identity.principalId" -o tsv 2>/dev/null || true)
  if [ -n "$APIM_MI" ]; then
    CS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$CONTENT_SAFETY_RG/providers/Microsoft.CognitiveServices/accounts/$CONTENT_SAFETY_NAME"
    echo ">> Removing role assignment for APIM MI on Content Safety"
    az role assignment delete --assignee "$APIM_MI" --role "Cognitive Services User" --scope "$CS_ID" -o none \
      && echo "   removed" || echo "   not found (ok)"
  fi
fi
echo ">> Done."
