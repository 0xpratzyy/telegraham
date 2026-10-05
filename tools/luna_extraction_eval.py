#!/usr/bin/env python3
"""Bounded Luna benchmark, reusing frozen inputs and independent Astra labels."""
import argparse,concurrent.futures,hashlib,json,pathlib,plistlib,statistics,time,urllib.request,urllib.error,urllib.parse
import jev_prompt_tuning as t
from jev_vs_gemini_corpus import RULES,KINDS
O=t.OUT/'luna';O.mkdir(exist_ok=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--live',action='store_true');a=p.parse_args()
 b=plistlib.loads(pathlib.Path('/private/tmp/pidgy-codex-derived/Build/Products/Debug/Pidgy.app/Contents/Info.plist').read_bytes());u=urllib.parse.urlsplit(b['PidgyBundledAIProxyURL']);url=urllib.parse.urlunsplit((u.scheme,u.netloc,'/v1/chat/completions',u.query,''));headers={'Content-Type':'application/json','User-Agent':'Pidgy/14 CFNetwork Darwin','Authorization':'Bearer '+b['PidgyBundledAIProxyToken']};lf=pathlib.Path.home()/'Library/Application Support/Pidgy/credentials/com.pidgy.dodoLicenseKey'
 if lf.exists():headers['X-Pidgy-License']=lf.read_text().strip()
 def call(body):
  req=urllib.request.Request(url,data=json.dumps(body).encode(),headers=headers)
  with urllib.request.urlopen(req,timeout=90) as r:return json.load(r)
 split=json.loads((t.OUT/'split.json').read_text());ids=sorted(set(split['heldout']+json.loads((t.OUT/'hybrid/manifest.json').read_text())['batches']));windows=[w for l in (t.BASE/'astra-audit/blind-input.jsonl').read_text().splitlines() for w in [json.loads(l)] if w['batch'] in ids];labels=json.loads((t.OUT/'frozen-labels.json').read_text());keys={m['key'] for w in windows for m in w['messages']}
 manifest={'model':'gpt-6-luna','reasoning_effort':'low','batches':ids,'segments':len(keys),'promptHash':hashlib.sha256((RULES+json.dumps(KINDS)).encode()).hexdigest(),'scope':'44 prior evaluation windows, excluded prompt-development conversations; cached Gemini 3.7 baseline, no prompt tuning'}
 mp=O/'manifest.json'
 if mp.exists():assert json.loads(mp.read_text())==manifest
 else:mp.write_text(json.dumps(manifest,indent=2))
 path=O/'results.jsonl';old=[json.loads(l) for l in path.read_text().splitlines()] if path.exists() else [];done={r['batch'] for r in old if 'error' not in r}
 if a.live:
  try:
   smoke=call({'model':'gpt-6-luna','reasoning_effort':'low','messages':[{'role':'user','content':'Return JSON {"ok":true}.'}],'response_format':{'type':'json_object'},'max_completion_tokens':512});assert smoke['model'].startswith('gpt-6-luna');assert json.loads(smoke['choices'][0]['message']['content'])['ok'] is True
   (O/'smoke.json').write_text(json.dumps({'model':smoke['model'],'usage':smoke.get('usage',{})}));print('smoke passed',flush=True)
  except urllib.error.HTTPError as e:
   try:err=json.loads(e.read()).get('error',{});code=err.get('code') if isinstance(err,dict) else err
   except Exception:code='unknown'
   print(json.dumps({'blockedHTTP':e.code,'code':code}),flush=True);return
  def run(w):
   start=time.perf_counter();usage={}
   try:
    messages=[dict(m,id=f'm{i+1}') for i,m in enumerate(w['messages'])];state={'instructions':RULES,'messages':messages}
    d=call({'model':'gpt-6-luna','reasoning_effort':'low','response_format':{'type':'json_object'},'max_completion_tokens':8192,'messages':[{'role':'system','content':RULES+' Categories: '+json.dumps(KINDS)+'. Return JSON {"answers":{"m1":"category",...}} for EVERY input ID. Use complex when uncertain.'},{'role':'user','content':json.dumps(state,ensure_ascii=False)}]});usage=d.get('usage',{});assert d['model'].startswith('gpt-6-luna');assert d['choices'][0]['finish_reason']=='stop';pred=json.loads(d['choices'][0]['message']['content'])['answers'];assert set(pred)=={m['id'] for m in messages};assert all(v in KINDS for v in pred.values())
    return {'batch':w['batch'],'model':d['model'],'answers':[{'key':m['key'],'choice':pred[m['id']]} for m in messages],'usage':usage,'ms':(time.perf_counter()-start)*1000}
   except Exception as e:return {'batch':w['batch'],'error':type(e).__name__,'usage':usage,'ms':(time.perf_counter()-start)*1000}
  with path.open('a') as f,concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   for r in pool.map(run,[w for w in windows if w['batch'] not in done]):f.write(json.dumps(r)+'\n');f.flush();print('finished',r['batch'],r.get('error','ok'),flush=True)
 if not path.exists():return
 rows=[json.loads(l) for l in path.read_text().splitlines()];latest={r['batch']:r for r in rows};valid=[r for r in latest.values() if 'error' not in r];gems={r['batch']:r for l in (t.BASE/'results.jsonl').read_text().splitlines() for r in [json.loads(l)] if r['model']=='gemini' and 'error' not in r and r['batch'] in ids}
 def perf(rs,luna):
  inp=sum(r['usage'].get('prompt_tokens',0) for r in rs);out=sum(max(r['usage'].get('completion_tokens',0),r['usage'].get('total_tokens',0)-r['usage'].get('prompt_tokens',0)) for r in rs);cached=sum(r['usage'].get('prompt_tokens_details',{}).get('cached_tokens',0) for r in rs)
  return {'inputTokens':inp,'billedOutputTokens':out,'cachedInputTokens':cached,'estimatedUSD':((inp-cached)*.1+cached*.01+out*.5)/1e6 if luna else (inp*.75+out*3.75)/1e6,'medianMS':statistics.median(r['ms'] for r in rs) if rs else None}
 result={'manifest':manifest,'luna':t.score(valid,labels,keys),'gemini37':t.score(list(gems.values()),labels,keys),'lunaUsage':perf(rows,True),'geminiUsage':perf(list(gems.values()),False),'failedBatches':len(latest)-len(valid)};(O/'summary.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
