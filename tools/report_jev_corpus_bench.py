#!/usr/bin/env python3
"""Generate a shareable aggregate report without message text or chat IDs."""
import csv,json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
s=json.loads((root/'Build/TypeSafeBenchmark/full-corpus/summary.json').read_text())
m=s['manifest'];j=s['models']['jev'];g=s['models']['gemini']
assert all(x['successfulBatches']==m['batches'] and x['failedBatches']==0 and x['coveredUnits']==m['units'] for x in (j,g)), 'Benchmark incomplete; do not present a full-corpus result.'
def candidates(x):return sum(x['categories'].get(k,0) for k in ['reply','action','owes','fact'])
rows=[['Model','Jev 1.13.0','Gemini 3.7 Flash'],['Text messages covered',m['textMessages'],m['textMessages']],['Successful batches',j['successfulBatches'],g['successfulBatches']],['Estimated cost (USD)',f"{j['estimatedUSD']:.6f}",f"{g['estimatedUSD']:.6f}"],['Median batch latency (seconds)',f"{j['medianMS']/1000:.2f}",f"{g['medianMS']/1000:.2f}"],['P95 batch latency (seconds)',f"{j['p95MS']/1000:.2f}",f"{g['p95MS']/1000:.2f}"],['Input tokens',j['inputTokens'],g['inputTokens']],['Output tokens',j['outputTokens'],g['outputTokens']],['Fact / obligation candidates (unvalidated)',candidates(j),candidates(g)],['Explicitly uncertain / complex segments',j['categories'].get('complex',0),g['categories'].get('complex',0)],['No-fact segments',j['categories'].get('none',0),g['categories'].get('none',0)],['Ground-truth accuracy','Not measured','Not measured']]
out=root/'Build/TypeSafeBenchmark/full-corpus/comparison.csv'
with out.open('w') as f:csv.writer(f).writerows(rows)
agreement=s['agreement']['sameCategory']/s['agreement']['comparedUnits']*100
saving=(1-j['estimatedUSD']/g['estimatedUSD'])*100
text=f'''# Jev-only vs Gemini-only: full stored text corpus

Completed September 18, 2026. No fallback between models and no changes to product
routing, facts, extraction cursors or the source database.

Snapshot: {m['storedMessages']:,} stored messages, {m['textMessages']:,} with text,
{m['noTextMessages']:,} without text. All text was included. Three long messages
were split, producing {m['units']:,} distinct segments in {m['batches']} batches
of at most 40 segments / approximately 16 KB of state. Existing OCR/captions in
message text are included; non-text media was not newly transcribed or OCRed.
The initial inventory had three fewer text-bearing messages than the fixed
SQLite backup; message text changed while the app was running. Both models used the same backup.

'''
text+='| Metric | Jev-only | Gemini-only |\n|---|---:|---:|\n'+'\n'.join('| '+' | '.join(map(str,r))+' |' for r in rows)+'\n'
text+=f'''
Jev used **{saving:.1f}% less estimated money**. Exact category agreement was
**{agreement:.1f}%** across {s['agreement']['comparedUnits']:,} segments. Agreement
is NOT accuracy, and a larger candidate count is NOT evidence of better recall.
No human-labeled corpus exists for these messages.

## What was compared

Both models receive identical text, source/sender/outgoing metadata and bounded
conversation context. They assign one of reply, action, owes, fact, none or
complex to each segment. The original message text and IDs supply the extracted
object/evidence; neither model is asked to invent a rewritten action description.
This is a matched typed, extractive workload, not Gemini's richer production
free-text fact-extraction prompt. Existing open-loop state is not included and
cross-window resolutions are outside the measurement. Multiple facts or unclear
ownership should return complex. Group addressees are not assumed to be the user.
All messages are tested regardless of production chat eligibility filters.

Raw choices are reported above. Applying the prototype's conservative Jev
thresholds (0.95 for positive facts, 0.995 for none) accepts only
{j['confidentUnits']:,}/{m['units']:,} segments. The others remain unresolved in
Jev-only mode; NO Gemini request is made for them. Gemini does not expose an
equivalent calibrated probability, so this acceptance figure is not a comparable
accuracy metric.

## Costs and timing

Cost estimates use the app's existing rate table: Jev $0.042/M input tokens and
free output; Gemini $0.75/M input and $3.75/M output. Returned usage is summed,
including recorded usage on invalid-output attempts. Failed requests without
usage may have unreported charges. This is not a verified provider invoice.
Python benchmark requests do not appear in the app's local usage meter.

Requests were paired in alternating submission order, with 12 concurrent workers.
Reported latency is request wall time, including any retry backoff, excluding
queue time and local DB work. Provider/network load and prompt shape affect it.
Two Gemini pilot attempts returned HTTP 403 before the script User-Agent was
corrected; both batches subsequently completed successfully. One Gemini connection
dropped in the full run and its batch was rerun; usage for that disconnected
attempt is unknown and excluded. This is one full
pass, not multiple repeated production trials.

## Reproduction and evidence

- `python3 tools/jev_vs_gemini_corpus.py --live` resumes successful cached benchmark
  batches from the fixed private snapshot; it does not reissue them.
- `python3 tools/report_jev_corpus_bench.py` generates this report only when both
  models have covered every segment.
- `Build/TypeSafeBenchmark/full-corpus/manifest.json`: counts, prompt and snapshot hash.
- `Build/TypeSafeBenchmark/full-corpus/results.jsonl`: per-request outcomes and usage.
- `Build/TypeSafeBenchmark/full-corpus/summary.json`: aggregate measurements.
- `Build/TypeSafeBenchmark/full-corpus/comparison.csv`: final table.
- Private snapshot and detailed results remain local in the ignored Build directory.
'''
(root/'docs/jev-vs-gemini-full-corpus.md').write_text(text)
print(text[:text.index('## What was compared')])
