import json, pathlib, urllib.request, urllib.parse, urllib.error, yaml, subprocess, hashlib, os, stat, time
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs): return None
op=urllib.request.build_opener(NoRedirect)
def get(url,headers={},data=None):
 r=op.open(urllib.request.Request(url,data=data,headers={'User-Agent':'Bettbox-validation/1',**headers}),timeout=15)
 with r:
  b=r.read(1048577)
  assert len(b)<=1048576
  return b
def run_probe(exe,nodes,timeout=45):
 # 启动前序列化，异常路径也必须收回本工具拥有的子进程。
 payload=json.dumps(nodes).encode()
 if len(payload)>1048576:
  raise ValueError('input_limit')
 process=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'PATH':'/usr/bin:/bin','HOME':str(pathlib.Path.home())})
 try:
  out,err=process.communicate(payload,timeout=timeout)
  if process.returncode!=0 or process.poll() is None:
   raise ValueError('probe_failed')
  return out,err,process.returncode
 finally:
  if process.poll() is None:
   process.kill()
   process.communicate()
  for pipe in (process.stdin,process.stdout,process.stderr):
   if pipe is not None:
    pipe.close()

def main():
 stage='credentials'
 try:
  root=pathlib.Path(__file__).resolve().parents[1]
  p=root/'.test/three-platform-release/account-provision/private/credentials.json'
  st=p.lstat()
  assert stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_uid==os.getuid() and st.st_nlink==1
  c=json.loads(p.read_text())
  stage='login'
  a=json.loads(get('https://api.bingcn.site/api/v1/passport/auth/login',{'Content-Type':'application/json'},json.dumps({'email':c['email'],'password':c['password']}).encode()))['data']['auth_data']
  stage='subscription'
  d=json.loads(get('https://api.bingcn.site/api/v1/user/getSubscribe',{'Authorization':a}))['data']
  u=urllib.parse.urlparse(d['subscribe_url']);assert u.scheme=='https' and u.hostname in ['api.bingcn.site','cloud.bingcn.site']
  cfg=yaml.safe_load(get(d['subscribe_url'],{'User-Agent':'FlClash/ClashMetaForAndroid/2.11.32.Meta'}))
  counts={};nodes=[]
  for n in cfg['proxies']:
   kind=n.get('type')
   if kind in ['anytls','hysteria2'] and counts.get(kind,0)<2:
    nodes.append(n);counts[kind]=counts.get(kind,0)+1
  assert nodes
  stage='probe'
  exe=root/'.test/android-node-probe/nodeprobe'
  assert exe.is_file() and not exe.is_symlink()
  binary_hash=hashlib.sha256(exe.read_bytes()).hexdigest()
  started=time.monotonic()
  out,err,exit_code=run_probe(exe,nodes)
  results=json.loads(out)
  assert isinstance(results,list) and len(results)==len(nodes)
  for i,r in enumerate(results):
   assert set(r)<=set(['index','protocol','stage','error_class','http_status','trace_present'])
   assert type(r['index']) is int and r['index']==i and r['protocol']==nodes[i]['type'] and r['stage'] in ['parse','request','response']
   assert r.get('error_class','') in ['','configuration','timeout','certificate','peer_closed','authentication','transport','response_limit']
   assert type(r.get('http_status',0)) is int and 0<=r.get('http_status',0)<=599 and type(r['trace_present']) is bool
  assert hashlib.sha256(exe.read_bytes()).hexdigest()==binary_hash
  receipt={'binary_sha256':binary_hash,'exit_code':exit_code,'exit_confirmed':True,'elapsed_seconds':round(time.monotonic()-started,2),'results':results,'secrets_reported':False,'boundary':'macOS独立核心协议探测；不证明Android JNI/TUN或系统代理通过。'}
  (root/'.test/android-node-probe/receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
  print(json.dumps(receipt,ensure_ascii=False))
 except Exception as e:
  print(json.dumps({'stage':stage,'failure_class':type(e).__name__,'HTTP_status':e.code if isinstance(e,urllib.error.HTTPError) else None}))
  raise SystemExit(1)

if __name__=="__main__":
 main()
