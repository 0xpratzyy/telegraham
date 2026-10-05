#!/usr/bin/env python3
"""Compare frozen independent Astra labels with full-corpus model answers.
Refuses to publish full-coverage scores if any labels are missing or duplicated.
"""
import collections,json,pathlib,csv,argparse
ROOT=pathlib.Path(__file__).resolve().parents[1]
BASE=ROOT/'Build/TypeSafeBenchmark/full-corpus';AUDIT=BASE/'astra-audit'
KINDS={'reply','action','owes','fact','none','complex'};TASKS={'reply','action','owes'};POSITIVE=TASKS|{'fact'}
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--partial',action='store_true');args=parser.parse_args()
 source=[json.loads(line) for line in (AUDIT/'blind-input.jsonl').read_text().splitlines()]
 keys={m['key'] for b in source for m in b['messages']}
 paths=[AUDIT/name for name in ['review-labels.jsonl','review-middle.jsonl','review-tail.jsonl']]
 if not any(path.exists() for path in paths):raise SystemExit('Astra review is still pending; no scores produced.')
 rows=[json.loads(line) for path in paths if path.exists() for line in path.read_text().splitlines() if line.strip()]
 labels={r['key']:r for r in rows};counts=collections.Counter(r['key'] for r in rows)
 missing=keys-labels.keys();extra=labels.keys()-keys;duplicates=[k for k,v in counts.items() if v>1]
 status={'expected':len(keys),'reviewed':len(labels.keys() & keys),'missing':len(missing),'unexpected':len(extra),'duplicates':len(duplicates)}
 (AUDIT/'coverage.json').write_text(json.dumps(status,indent=2))
 print(json.dumps(status))
 if extra or duplicates or (missing and not args.partial):raise SystemExit('Incomplete or invalid audit. Full-data scores withheld.')
 all_keys=keys
 if args.partial:keys=set(labels)
 for r in rows:
  assert r['category'] in KINDS and r['confidence'] in ['high','medium','low']
  allowed=r['acceptableCategories'];assert allowed and set(allowed)<=KINDS and r['category'] in allowed
  assert isinstance(r['reason'],str) and r['reason'].strip()
 predictions={}
 for line in (BASE/'results.jsonl').read_text().splitlines():
  r=json.loads(line)
  if 'error' not in r:predictions[(r['model'],r['batch'])]=r
 metrics={};confusions={}
 decidable={k for k,r in labels.items() if r['confidence']!='low' and len(r['acceptableCategories'])==1 and r['category']!='complex'}
 def ratio(a,b):return a/b if b else None
 for model in ['jev','gemini']:
  pred={a['key']:a['choice'] for (name,_),r in predictions.items() if name==model for a in r['answers']}
  assert pred.keys()==all_keys
  exact=sum(pred[k]==labels[k]['category'] for k in keys)
  accepted=sum(pred[k] in labels[k]['acceptableCategories'] for k in keys)
  supported=sum(pred[k] in labels[k]['acceptableCategories'] for k in decidable)
  factpred=[k for k in decidable if pred[k] in POSITIVE]
  factgold=[k for k in decidable if labels[k]['category'] in POSITIVE]
  taskgold=[k for k in decidable if labels[k]['category'] in TASKS]
  taskpred=[k for k in decidable if pred[k] in TASKS]
  correctfacts=sum(pred[k] in labels[k]['acceptableCategories'] for k in factpred)
  recoveredfacts=sum(pred[k] in labels[k]['acceptableCategories'] for k in factgold)
  correcttasks=sum(pred[k] in labels[k]['acceptableCategories'] for k in taskpred)
  recoveredtasks=sum(pred[k] in labels[k]['acceptableCategories'] for k in taskgold)
  wrongowner=sum((pred[k]=='owes') != (labels[k]['category']=='owes') for k in taskgold if pred[k] in TASKS)
  metrics[model]={'reviewed':len(keys),'exactCategoryMatches':exact,'acceptableCategoryMatches':accepted,'decidableMatches':supported,'decidableCount':len(decidable),'decidableAgreement':ratio(supported,len(decidable)),
   'factCandidatesOnDecidable':len(factpred),'supportedFactCandidates':correctfacts,'factPrecision':ratio(correctfacts,len(factpred)), 'referenceFacts':len(factgold),'recoveredFacts':recoveredfacts,'factRecall':ratio(recoveredfacts,len(factgold)),
   'obligationCandidates':len(taskpred),'supportedObligations':correcttasks,'obligationPrecision':ratio(correcttasks,len(taskpred)), 'referenceObligations':len(taskgold),'recoveredObligations':recoveredtasks,'obligationRecall':ratio(recoveredtasks,len(taskgold)),
   'wrongOwnership':wrongowner,'abstainedOnDecidable':sum(pred[k]=='complex' for k in decidable)}
  confusion=collections.Counter((labels[k]['category'],pred[k]) for k in keys)
  confusions[model]=[{'astra':a,'prediction':p,'count':n} for (a,p),n in sorted(confusion.items())]
 report={'reviewer':'Three gpt-6-astra reviewers on non-overlapping blind shards','scope':status,'partial':bool(missing),'decidableCount':len(decidable),'ambiguousOrLowConfidence':len(keys)-len(decidable),'referenceCategories':dict(collections.Counter(r['category'] for r in rows)),'metrics':metrics,'confusions':confusions,'caveat':'Independent Astra judgments, not human-verified ground truth. Measures this bounded-window typed-extraction task only.'}
 (AUDIT/('comparison-partial.json' if args.partial else 'comparison.json')).write_text(json.dumps(report,indent=2))
 print(json.dumps({'decidable':len(decidable),'metrics':metrics},indent=2))
if __name__=='__main__':main()
