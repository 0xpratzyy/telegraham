#!/usr/bin/env python3
"""Fresh conversation-disjoint Jev evaluation with saved Gemini fallback replay."""
import concurrent.futures,hashlib,json,math,pathlib,time,urllib.request,statistics
import jev_prompt_tuning as t
O=t.OUT/'hybrid';O.mkdir(exist_ok=True)
def main():
 labels=json.loads((t.OUT/'frozen-labels.json').read_text());split=json.loads((t.OUT/'split.json').read_text());windows=[json.loads(l) for l in (t.BASE/'astra-audit/blind-input.jsonl').read_text().splitlines()];used=set(split['development']+split['heldout']);chats={(m['source'],m['chat']) for w in windows if w['batch'] in used for m in w['messages']}
 fresh=[w for w in windows if w['batch'] not in used and all(m['key'] in labels and (m['source'],m['chat']) not in chats for m in w['messages'])]
 manifest={'batches':[w['batch'] for w in fresh],'positiveThreshold':.75,'noneThreshold':.995,'promptSHA256':hashlib.sha256(pathlib.Path(t.__file__).read_bytes()).hexdigest(),'fallback':'Full original window to Gemini for any unresolved segment, reuse saved outputs; merge only accepted Jev predictions. Includes low-confidence none and complex, not just positive candidates.'}
 mp=O/'manifest.json'
 if mp.exists():assert json.loads(mp.read_text())==manifest
 else:mp.write_text(json.dumps(manifest,indent=2))
 path=O/'jev.jsonl';old=[json.loads(l) for l in path.read_text().splitlines()] if path.exists() else [];done={r['batch'] for r in old if 'error' not in r};key=(pathlib.Path.home()/'Library/Application Support/Pidgy/credentials/com.pidgy.aiApiKey.typesafe').read_text().strip()
 def run(w):
  start=time.perf_counter()
  try:
   req=urllib.request.Request('https://api.typesafe.ai/v1/systemone',data=json.dumps(t.request_for(w,'relational')).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
   with urllib.request.urlopen(req,timeout=90) as r:d=json.load(r)
   out=t.assemble(d,w,'relational')
   for i,a in enumerate(out):
    names=[f'm{i}']+([f'gate{i}'] if a['choice'] in ('reply','action','owes') else [])
    probs=[d['answers'][n]['probabilities'][d['answers'][n]['choice']] for n in names];assert all(math.isfinite(p) and 0<=p<=1 for p in probs)
    p=min(probs);a['probability']=p;a['accept']=a['choice'] in ('fact','reply','action','owes') and p>=.75 or a['choice']=='none' and d['answers'][f'm{i}']['choice']=='none' and p>=.995
   return {'batch':w['batch'],'answers':out,'usage':d.get('usage',{}),'ms':(time.perf_counter()-start)*1000}
  except Exception as e:return {'batch':w['batch'],'error':type(e).__name__}
 with path.open('a') as f,concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
  for r in pool.map(run,[w for w in fresh if w['batch'] not in done]):f.write(json.dumps(r)+'\n');f.flush();print('finished',r['batch'],r.get('error','ok'),flush=True)
 rows={r['batch']:r for l in path.read_text().splitlines() for r in [json.loads(l)]};assert all('error' not in rows[w['batch']] for w in fresh)
 gems={r['batch']:r for l in (t.BASE/'results.jsonl').read_text().splitlines() for r in [json.loads(l)] if r['model']=='gemini' and 'error' not in r};merged=[];fallback=[];accepted=[]
 for w in fresh:
  j=rows[w['batch']];g={a['key']:a for a in gems[w['batch']]['answers']};merged.append({'answers':[a if a['accept'] else g[a['key']] for a in j['answers']]});accepted.extend(a for a in j['answers'] if a['accept'])
  if any(not a['accept'] for a in j['answers']):fallback.append(w['batch'])
 keys={m['key'] for w in fresh for m in w['messages']}
 def cost(r):
  u=r['usage'];return (u.get('prompt_tokens',0)*.75+u.get('completion_tokens',0)*3.75)/1e6
 jc=sum(r['usage'].get('input_tokens',0)*.042/1e6 for r in rows.values());gc=sum(cost(gems[w['batch']]) for w in fresh)
 result={'segments':len(keys),'batches':len(fresh),'jev':t.score(list(rows.values()),labels,keys),'gemini':t.score([gems[w['batch']] for w in fresh],labels,keys),'hybrid':t.score(merged,labels,keys),'acceptedSegments':len(accepted),'acceptedPositives':sum(a['choice']!='none' for a in accepted),'fallbackBatches':len(fallback),'estimatedJevUSD':jc,'estimatedGeminiUSD':gc,'estimatedHybridUSD':jc+sum(cost(gems[b]) for b in fallback),'jevMedianMS':statistics.median(r['ms'] for r in rows.values()),'geminiCachedMedianMS':statistics.median(gems[w['batch']]['ms'] for w in fresh),'hybridModeledMedianMS':statistics.median(rows[w['batch']]['ms']+(gems[w['batch']]['ms'] if w['batch'] in fallback else 0) for w in fresh)}
 (O/'summary.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
