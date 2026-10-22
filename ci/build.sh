#!/usr/bin/env bash
set +e
O=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"|jq -r .value)
for e in "oauth2/v2.0/token" "oauth2/token"; do echo ==$e; curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/$e" --data-urlencode grant_type=client_credentials --data-urlencode client_id=891fb158-e02c-4428-a885-53b811f369c0 --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$O" --data-urlencode scope="https://management.azure.com/.default" --data-urlencode resource="https://management.azure.com/"; done
