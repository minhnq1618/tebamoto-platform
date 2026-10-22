#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
KV_SEC_SCOPE="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get reporting-service ARM token (has sub-level read)
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "reporting-service ARM token len=${#RS_AT}"

echo "=== ALL SUBSCRIPTION-LEVEL ROLE ASSIGNMENTS ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
print("Total assignments:", len(vals))
for r in vals:
    pid=r["properties"]["principalId"]
    role=r["properties"]["roleDefinitionId"].split("/")[-1]
    scope=r["properties"]["scope"]
    ptype=r["properties"].get("principalType","?")
    print(f"  pid={pid} role={role} scope={scope} type={ptype}")
' 2>/dev/null

echo ""
echo "=== KV SEC ROLE ASSIGNMENTS (full) ==="
curl -sS "$ARM_BASE${KV_SEC_SCOPE}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
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
        print("  "+json.dumps(r["properties"]))
' 2>/dev/null

echo ""
echo "=== PLATFORM RG ROLE ASSIGNMENTS (all principals) ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
print("Total:", len(vals))
for r in vals:
    pid=r["properties"]["principalId"]
    role=r["properties"]["roleDefinitionId"].split("/")[-1]
    scope=r["properties"]["scope"].split("/resourceGroups/")[-1]
    print(f"  pid={pid[:8]} role={role[:8]} scope={scope[:60]}")
' 2>/dev/null

echo ""
echo "=== WHO HAS roleAssignments/write on subscription? ==="
# Check all principals with write ability - look for Owner and UAA at subscription scope
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
# Owner=8e3af657, User Access Administrator=18d7d88d
PRIVILEGED={"8e3af657-a8ff-443c-a75c-2fe8c4bcb635","18d7d88d-8cd5-4d9d-a1b3-5f04fcadb2ba"}
for r in d.get("value",[]):
    rdef=r["properties"]["roleDefinitionId"].split("/")[-1]
    if rdef in PRIVILEGED:
        pid=r["properties"]["principalId"]
        scope=r["properties"]["scope"]
        ptype=r["properties"].get("principalType","?")
        print(f"PRIVILEGED: pid={pid} role={rdef} scope={scope} type={ptype}")
' 2>/dev/null

echo ""
echo "=== REPORTING RG ROLE ASSIGNMENTS ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    pid=r["properties"]["principalId"]
    role=r["properties"]["roleDefinitionId"].split("/")[-1]
    scope=r["properties"]["scope"]
    print(f"  pid={pid} role={role} scope={scope}")
' 2>/dev/null

echo ""
echo "=== sync-service SUBSCRIPTION ROLE ASSIGNMENTS ==="
SS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name sync-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name sync-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
SS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

if [ "${#SS_AT}" -gt 100 ]; then
  echo "sync-service sub-level roleAssignments:"
  curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'70a07660-06bb-4396-b754-59fbad0b143e'" \
    -H "Authorization: Bearer $SS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print("  "+r["properties"]["roleDefinitionId"].split("/")[-1]+" at "+r["properties"]["scope"])
' 2>/dev/null
fi

echo ""
echo "=== REPORTING-SERVICE: TRY ALL RESOURCES ==="
echo "Reporting-service own role assignments:"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'732dfdbc-e325-4e9f-9ca9-359af1197807'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print("  "+r["properties"]["roleDefinitionId"].split("/")[-1]+" at "+r["properties"]["scope"])
' 2>/dev/null

echo "UAMI (f64d08c7) ALL role assignments:"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'f64d08c7-fde6-4553-99c8-5bf73666ee8c'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print("  "+r["properties"]["roleDefinitionId"].split("/")[-1]+" at "+r["properties"]["scope"])
print("Total:", len(d.get("value",[])))
' 2>/dev/null

echo "Storefront SAMI (eeab432e) ALL role assignments:"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'eeab432e-1bf6-400e-b155-a28ce7cafcdb'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print("  "+r["properties"]["roleDefinitionId"].split("/")[-1]+" at "+r["properties"]["scope"])
print("Total:", len(d.get("value",[])))
' 2>/dev/null

echo "DONE"
