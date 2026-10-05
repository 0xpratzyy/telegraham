#!/usr/bin/env python3
"""Exploratory confidence sweep on the already-consumed prompt-tuning holdout."""
import concurrent.futures,json,math,pathlib,statistics,time,urllib.request
import jev_prompt_tuning as tuning
OUT=tuning.OUT

def main():
 split=json.loads((OUT/'split.json').read_text());labels=json.loads((OUT/'frozen-labels.json').read_text())
 windows=[w for l in (tuning.BASE/'astra-audit/blind-input.jsonl').read_text().splitlines() for w in [json.loads(l)] if w['batch'] in split['heldout']]
 keys={m['key'] for w in windows for m in w['messages']}
 path=OUT/'confidence-relational.jsonl';existing=[json.loads(l) for l in path.read_text().splitlines()] if path.exists() else [];done={r['batch'] for r in existing if 'error' not in r}
 key=(pathlib.Path.home()/'Library/Application Support/Pidgy/credentials/com.pidgy.aiApiKey.typesafe').read_text().strip()
 def run(w):
  start=time.perf_counter()
  try:
   req=urllib.request.Request('https://api.typesafe.ai/v1/systemone',data=json.dumps(tuning.request_for(w,'relational')).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
   with urllib.request.urlopen(req,timeout=90) as response:data=json.load(response)
   assembled=tuning.assemble(data,w,'relational')
   for i,a in enumerate(assembled):
    names=[f'm{i}']+([f'gate{i}'] if a['choice'] in ('reply','action','owes') else [])
    probs=[data['answers'][n]['probabilities'][data['answers'][n]['choice']] for n in names]
    assert all(isinstance(p,(int,float)) and math.isfinite(p) and 0<=p<=1 for p in probs)
    a['probability']=min(probs) # Both category and gate must pass; not a joint probability.
   return {'batch':w['batch'],'answers':assembled,'rawAnswers':data['answers'],'usage':data.get('usage',{}),'ms':(time.perf_counter()-start)*1000}
  except Exception as e:return {'batch':w['batch'],'error':type(e).__name__}
 with path.open('a') as f,concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
  for row in pool.map(run,[w for w in windows if w['batch'] not in done]):f.write(json.dumps(row)+'\n');f.flush();print('finished',row['batch'],row.get('error','ok'),flush=True)
 rows=list({r['batch']:r for l in path.read_text().splitlines() for r in [json.loads(l)]}.values());assert all('error' not in r for r in rows)
 report={'scope':'Exploratory reuse of previously evaluated holdout, not a fresh confirmatory test','segments':len(keys),'thresholds':{},'estimatedUSD':sum(r['usage'].get('input_tokens',0)*.042/1e6 for r in rows),'medianMS':statistics.median(r['ms'] for r in rows)}
 for threshold in [0,.5,.6,.7,.75,.8,.85,.9,.95]:
  filtered=[{'answers':[dict(a,choice='complex' if a['choice'] in ('fact','reply','action','owes') and a['probability']<threshold else a['choice']) for a in r['answers']]} for r in rows]
  report['thresholds'][str(threshold)]=tuning.score(filtered,labels,keys)
 report['apiConfidenceThresholds']={}
 for threshold in [.7,.85,.95]:
  filtered=[]
  for r in rows:
   answers=[]
   for i,a in enumerate(r['answers']):
    names=[f'm{i}']+([f'gate{i}'] if a['choice'] in ('reply','action','owes') else [])
    confidence=min(r['rawAnswers'][n]['confidence'] for n in names)
    answers.append(dict(a,choice='complex' if a['choice'] in ('fact','reply','action','owes') and confidence<threshold else a['choice']))
   filtered.append({'answers':answers})
  report['apiConfidenceThresholds'][str(threshold)]=tuning.score(filtered,labels,keys)
 (OUT/'confidence-summary.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if __name__=='__main__':main()
