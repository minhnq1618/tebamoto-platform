#!/usr/bin/env bash
set +e
O=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"|jq -r .value)
p=${O#*.};p=${p%%.*};p=$(printf '%s' "$p"|tr '_-' '/+');p="$p$(printf '=%.0s' $(seq 1 $(( (4-${#p}%4)%4 ))))";echo "claims=$(printf '%s' "$p"|base64 -d 2>/dev/null|jq -c '{aud,iss,sub,repository}' )"
for c in 891fb158-e02c-4428-a885-53b811f369c0 462d1c38-4459-48b8-9333-82e389e59514; do echo "== $c";curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" --data-urlencode grant_type=client_credentials --data-urlencode client_id="$c" --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$O" --data-urlencode scope="https://management.azure.com/.default";done
