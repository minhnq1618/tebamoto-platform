#!/usr/bin/env bash
set -eu
tag="$1"; cid="$2"; tid="$3"
jwt=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
claims=$(echo "$jwt" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null)
echo "SUBJECT_${tag}=$(echo "$claims" | jq -r .sub)"
resp=$(curl -sS -X POST "https://login.microsoftonline.com/$tid/oauth2/v2.0/token" \
  --data-urlencode grant_type=client_credentials --data-urlencode client_id="$cid" \
  --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode client_assertion="$jwt" --data-urlencode scope=https://vault.azure.net/.default)
echo "$resp" | jq '{error,error_description,has_token:(.access_token != null)}'
