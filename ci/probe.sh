#!/usr/bin/env bash
set +e
TEN="$AZURE_TENANT_ID"; SUB="$AZURE_SUBSCRIPTION_ID"; RG="rg-tbl-platform-prod-sea"
oidc=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')
arm=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d client_id="$AZURE_CLIENT_ID" -d scope=https://management.azure.com/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$oidc" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
H="Authorization: Bearer $arm"
echo "===IDENTITIES==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31"
echo
echo "===RG RESOURCES==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/resources?api-version=2021-04-01"
echo
echo "===RG ROLES==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
echo
echo "===SUB ROLES==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
echo
echo "===APP IDENTITY==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2022-03-01"
echo
echo "===KV SEC RESOURCE==="
curl -sS -H "$H" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01"
echo
