#!/usr/bin/env python3
"""Compact, lossless source display for blind manual review, with stable row IDs."""
import argparse,json,pathlib,datetime
p=argparse.ArgumentParser();p.add_argument('start',type=int);p.add_argument('count',type=int,default=1,nargs='?');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];path=root/'Build/TypeSafeBenchmark/full-corpus/astra-audit/blind-input.jsonl'
for line in path.read_text().splitlines():
 b=json.loads(line)
 if not a.start<=b['batch']<a.start+a.count:continue
 print(f"WINDOW {b['batch']} ({len(b['messages'])} segments)")
 last=None
 for i,m in enumerate(b['messages']):
  identity=(m['source'],m['chat'])
  if identity!=last:print('CONVERSATION',m['source'],m['chat']);last=identity
  print(f"[{b['batch']}:{i}] {datetime.datetime.fromtimestamp(m['date'],datetime.timezone.utc).isoformat()} {'[ME]' if m['outgoing'] else m['sender']} (part {m['part']}/{m['parts']}): {json.dumps(m['text'],ensure_ascii=False)}")
