#!/usr/bin/env python3
"""Only synthetic service/UI. No launchd operations, production login or real consumption."""
import argparse,json,os,pathlib,subprocess,tempfile,time,urllib.request,shutil,signal,threading,re
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--seconds',type=int,default=120);p.add_argument('--app',default=str(ROOT/'dist/native/arm64/Bottled Reset Rune.app'));a=p.parse_args()
out=ROOT/'.build/native-smoke';out.mkdir(parents=True,exist_ok=True)
work=pathlib.Path(tempfile.mkdtemp(prefix='bottled-native-smoke-'));processes=[]
try:
    data=work/'data';data.mkdir(mode=0o700);sim=data/'simulation';sim.mkdir(mode=0o700)
    empty=work/'empty-codex';empty.mkdir(mode=0o700)
    app=work/'Bottled Reset Rune.app';shutil.copytree(a.app,app)
    subprocess.run(['/usr/libexec/PlistBuddy','-c','Add :BottledResetRuneMockOnly bool true',str(app/'Contents/Info.plist')],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    env={**os.environ,'RESET_RUNE_DATA_DIR':str(data),'CODEX_HOME':str(empty),'RESET_RUNE_CODEX_PATH':'/not-a-real-runtime','RESET_RUNE_APP_PATH':str(app)}
    helper=app/'Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune'
    # Explicit mock model, far expiry. Enabling here only authorizes this synthetic source.
    now=time.time()*1000
    model={'identity':{'accountId':'sample-account','scope':'sample-workspace','email':'hero@example.invalid'},'credits':[{'id':'mock-far','expiresAt':int(now+3*86400000)}],'remainingPercent':18,'redeemed':{}}
    (sim/'sample-inventory.json').write_text(json.dumps(model));(sim/'sample-inventory.json').chmod(0o600)
    log=open(out/'service.log','w')
    service=subprocess.Popen([str(helper),'--serve','--mock'],env=env,stdout=log,stderr=log);processes.append(service)
    connection=None
    for _ in range(100):
        if service.poll() is not None: raise RuntimeError('mock service failed')
        f=sim/'connection.json'
        if f.exists(): connection=json.loads(f.read_text());break
        time.sleep(.1)
    assert connection
    origin='http://127.0.0.1:'+str(connection['port'])
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def api(path,method='GET',body=None):
        headers={'Authorization':'Bearer '+connection['token']}
        if body is not None: headers['Content-Type']='application/json'
        req=urllib.request.Request(origin+'/api/'+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
        with opener.open(req,timeout=5) as r:return json.load(r)
    for _ in range(100):
        view=api('status')
        if view.get('snapshot'):break
        time.sleep(.05)
    assert view['mode']=='mock'
    api('config','PATCH',{'notify':False,'language':'zh','enabled':True})
    initial=api('status');assert initial['nextActionReason']=='scheduled-expiry'
    received=[]
    def subscription():
        req=urllib.request.Request(origin+'/api/events',headers={'Authorization':'Bearer '+connection['token']})
        try:
            with opener.open(req,timeout=8) as response:
                for line in response:
                    if line.startswith(b'data: '):
                        received.append(json.loads(line[6:]))
                        if len(received)>=2:break
        except Exception:pass
    t=threading.Thread(target=subscription,daemon=True);t.start();time.sleep(.2)
    api('config','PATCH',{'appearance':'dark'});t.join(3);assert len(received)>=2,'SSE state push failed'
    ui=subprocess.Popen([str(app/'Contents/MacOS/Bottled Reset Rune'),'--mock','--start-hidden'],env=env,stdout=log,stderr=log);processes.append(ui)
    time.sleep(2)
    assert ui.poll() is None,'UI exited'
    # Counts must remain fixed while hidden and far from expiry.
    before=api('status');start=time.monotonic();samples=[]
    def snapshot_cpu():
        res=subprocess.run(['ps','-o','pid=,time=,rss=','-p',str(service.pid)+','+str(ui.pid)],capture_output=True,text=True,check=True)
        rows=[]
        for line in res.stdout.splitlines():
            pid,cpu,rss=line.split();m,s=cpu.split(':');rows.append({'pid':int(pid),'cpuSeconds':int(m)*60+float(s),'rssKiB':int(rss)})
        return rows
    cpu0=snapshot_cpu()
    while time.monotonic()-start<a.seconds:
        if service.poll() is not None or ui.poll() is not None:raise RuntimeError('native process exited')
        samples.append(snapshot_cpu());time.sleep(1)
    after=api('status');cpu1=snapshot_cpu();assert before['runtime']['scheduledChecks']==after['runtime']['scheduledChecks'];assert before['runtime']['manualChecks']==after['runtime']['manualChecks'],'hidden UI polled remotely'
    footprint=out/'footprint.json'
    result=subprocess.run(['footprint','-p',str(service.pid),'-p',str(ui.pid),'--noCategories','--swapped','-j',str(footprint)],capture_output=True,text=True)
    (out/'footprint.txt').write_text(result.stdout)
    elapsed=time.monotonic()-start
    # Pause plus subsequent status access must not arm any work.
    paused=api('config','PATCH',{'enabled':False});assert paused['nextActionAt'] is None
    assert not list(empty.iterdir()),'empty Codex home changed'
    report={'syntheticOnly':True,'elapsedSeconds':elapsed,'pids':{'service':service.pid,'menu':ui.pid},'cpuBefore':cpu0,'cpuAfter':cpu1,'cpuPercentOneCore':sum(max(0,y['cpuSeconds']-x['cpuSeconds']) for x,y in zip(cpu0,cpu1))/elapsed*100,'schedulerChecksBefore':before['runtime']['scheduledChecks'],'schedulerChecksAfter':after['runtime']['scheduledChecks'],'manualChecksBefore':before['runtime']['manualChecks'],'manualChecksAfter':after['runtime']['manualChecks'],'sseUpdates':len(received),'pauseHasNoTimer':True,'codexDirectoryUntouched':True,'footprintExit':result.returncode,'samples':samples}
    (out/'report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!='samples'},indent=2))
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:process.wait(timeout=20)
            except subprocess.TimeoutExpired:process.kill();process.wait()
    shutil.rmtree(work,ignore_errors=True)
