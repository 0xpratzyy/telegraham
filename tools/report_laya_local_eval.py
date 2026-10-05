#!/usr/bin/env python3
"""Write a sanitized report from the local-only Laya pilot artifacts."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
d = json.loads((ROOT / 'Build/Laya/summary.json').read_text())
s = d['short']
c = d['corpus']
accepted = [r for r in s['results'] if r['probability'] >= .85]
revision = d['health']['revisions']['multilingual']
lines = [
    '# Laya local Pidgy pilot', '',
    'Measured on 2026-09-28 on an Apple M5 MacBook Pro with 16 GB unified memory. '
    'Laya 0.3.21, multilingual checkpoint, PyTorch MPS. This runs the model highlighted '
    'by Unsloth through the official Laya SDK server, not through the Unsloth Desktop app.', '',
    f'Model revision: `{revision}`. Local endpoint: `http://127.0.0.1:8889/v1/systemone`. '
    'The final health probe confirms MPS with zero CPU fallbacks. No paid inference calls, '
    'no live database writes, and no production provider changes.', '',
    '## Short decisions', '',
    'Uses the exact reply-versus-action question and criteria in Pidgy’s TypeSafeClient. '
    '24 synthetic English/Hinglish examples with expected labels written before execution. '
    'Each example is sent separately; the additional six-question shared-state request '
    'matches the app’s existing benchmark. This is a screening test, not a production acceptance set.', '',
    '| Check | Result |', '|---|---:|',
    f"| Single-item decisions correct | {s['correct']}/{s['total']} ({s['correct']/s['total']:.1%}) |",
    f"| Warm median single-item HTTP latency | {s['medianMS']:.1f} ms |",
    f"| Six-item app batch correct | {d['appSixItemBatch']['correct']}/6 |",
    f"| Six-item app batch latency | {d['appSixItemBatch']['ms']:.0f} ms |",
    f"| Correct among answers with selected probability ≥85% | {sum(r['choice']==r['expected'] for r in accepted)}/{len(accepted)} |",
    '| Inference API bill | $0 |', '',
    'Warm latency excludes the first request. Model download, startup and earlier synthetic '
    'connectivity/debug attempts are outside this table. $0 refers to API charges; local '
    'compute still consumes memory, energy and disk space. A probability threshold did not '
    'eliminate confidently wrong answers.', '',
    '## Existing chat snapshot', '',
    f"Four preselected windows ({c['manifest']['batches']}), {c['laya']['covered']} segments, "
    f"{c['laya']['clear']} unambiguous frozen Astra-reviewed labels, "
    f"{c['laya']['facts']['reference']} positive fact/task references and "
    f"{c['laya']['tasks']['reference']} task references. These are model-reviewed labels, not human gold. "
    'The first four sorted heldout windows were chosen before reading local predictions. '
    'The sample is too small and too dominated by non-actionable messages to establish production accuracy.', '',
    'The original frozen Jev/Gemini question, options and full state are reused. '
    'Laya receives one question per request to bound memory, with max_len=8192. '
    'The runner checks the complete state plus an overestimate of the question budget before inference; '
    'no conversation state is intentionally truncated. Gemini and Jev results are saved historical outputs. '
    'This tests extractive message classification, not richer production fact synthesis. '
    'Precision and recall credit a prediction only when its exact category matches the reference, '
    'using the same scorer as the earlier benchmarks.', '',
    '| Metric | Local Laya | Saved Jev | Saved Gemini 3.7 |',
    '|---|---:|---:|---:|',
]
for label, getter in [
    ('Exact category agreement', lambda x: x['agreement']),
    ('Fact/task precision', lambda x: x['facts']['precision']),
    ('Fact/task recall', lambda x: x['facts']['recall']),
]:
    lines.append('| ' + label + ' | ' + ' | '.join(f'{getter(c[m]):.1%}' for m in ['laya', 'jev', 'gemini']) + ' |')
lines += [
    f"| Median total time per window | {c['layaMedianWindowMS']/1000:.2f} s | {c['jevSavedMedianWindowMS']/1000:.2f} s | {c['geminiSavedMedianWindowMS']/1000:.2f} s |", '',
    'Timing is not a controlled same-day speed comparison: Laya uses sequential per-message '
    'requests while the saved cloud runs batched a whole window. It describes this conservative '
    'local runner, not Laya’s best possible batching performance.', '',
    '## Decision', '',
    'Do not switch Pidgy’s production decisions or fact extraction to this checkpoint from this pilot. '
    'The server runs successfully, but the unmodified Pidgy prompts do not meet the quality bar. '
    'Before product integration, evaluate task-specific prompts or fine-tuning on separate training '
    'data and hold out new conversations for acceptance. Laya is a decision model and cannot replace '
    'the text generator for summaries or Ask Pidgy.', '',
    'Pidgy’s Swift TypeSafeClient currently pins the cloud URL and `jev-1.13.0` response model. '
    'The SDK server returns `laya-rl-agent` with the actual checkpoint in `routing.model`; '
    'Unsloth documents a different response model name. A real integration must handle this '
    'explicitly, avoid applying Jev pricing to local calls, bound context, and independently '
    'validate probability thresholds. No endpoint rewrite was silently applied to the app.', '',
    '## Reproduce', '',
    '```sh', 'sh tools/run_laya_local.sh', '# In a second terminal:',
    'Build/Laya/.venv/bin/python tools/laya_local_eval.py --windows 4',
    'python3 tools/report_laya_local_eval.py', '```', '',
    'The server is foreground-only and binds to loopback. Stop it with Ctrl-C in its terminal. '
    'Dependencies, results and logs live in ignored `Build/Laya/`; model weights use the Hugging Face cache. '
    'No service or login item is installed. Re-running the evaluation overwrites its local pilot artifacts.', '',
    'Sources: [Unsloth integration guide](https://unsloth.ai/docs/models/decision-laya), '
    '[official Laya implementation and context limits](https://github.com/NandhaKishorM/laya).', '',
]
path = ROOT / 'docs/laya-local-evaluation.md'
path.write_text('\n'.join(lines))
print(path)
