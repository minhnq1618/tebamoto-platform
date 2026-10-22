#!/usr/bin/env bash
set +e
O=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"|jq -r .value)
az login --service-principal -u 891fb158-e02c-4428-a885-53b811f369c0 -t "$AZURE_TENANT_ID" --federated-token "$O" --allow-no-subscriptions -o json
