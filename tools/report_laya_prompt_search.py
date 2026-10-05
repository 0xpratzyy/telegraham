#!/usr/bin/env python3
"""Summarize completed local prompt runs without reading held-out examples."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'Build/Laya/prompt-search'
split = json.loads((OUT / 'split.json').read_text())
rows = []
for path in OUT.glob('*/*-summary.json'):
    d = json.loads(path.read_text())
    rows.append((path, d))
rows.sort(key=lambda pair: (pair[1]['split'], -pair[1]['laya']['facts']['f1']))
lines = ['# Laya prompt research', '',
         'Status: active research. No production provider changes. No test-set win has been established.', '',
         '## Frozen evaluation design', '',
         '- 7,789 messages with existing independent Astra review; labels are not human gold.',
         '- Conversation-disjoint development: 5,274; validation: 1,285; untouched test: 1,230.',
         '- Initial screen: 513 development messages, deliberately balanced by reviewed category. '
         'Its percentages are not estimates of normal app traffic.',
         '- Prompt tuning uses development data. Validation selects candidates. The test set '
         'requires a frozen prompt/config and is not used for tuning.',
         '- Gemini is the saved 3.7 benchmark on the identical message keys. No new cloud calls.',
         '- Larger-run candidates are now ranked using development class prevalence to weight the balanced screen. '
         'These weighted screen scores are selection estimates only; measured full-development results remain separate. '
         'The frozen screen and held-out partitions are unchanged.',
         '- Required test win: category agreement at least Gemini, fact/task F1 strictly higher, '
         'and task F1 at least Gemini. Report precision, recall and uncertainty too.', '',
         '## Completed runs', '',
         '| Split | Checkpoint / prompt | Messages | Agreement | Fact/task F1 | Task F1 | ms/message | Potential truncations |',
         '|---|---|---:|---:|---:|---:|---:|---:|']
seen = set()
for path, d in rows:
    s = d['laya']; c = d['config']; b = d['gemini']
    group = (d['split'], d['total'])
    if group not in seen:
        seen.add(group)
        lines.append(f"| {d['split']} | **Saved Gemini 3.7** | {d['total']} | {b['agreement']:.1%} | {b['facts']['f1']:.1%} | {b['tasks']['f1']:.1%} | historical | n/a |")
    lines.append(f"| {d['split']} | {c['checkpoint']} / {c['variant']} | {d['total']} | {s['agreement']:.1%} | {s['facts']['f1']:.1%} | {s['tasks']['f1']:.1%} | {d['medianAmortizedMS']:.1f} | {d['potentiallyTruncatedStates']} |")
lines += ['', 'Scores include every unambiguous reference label, with no confidence-based removal from the denominator. '
          'The exact correct category is required for precision/recall credit; predicting none everywhere cannot pass the win gate. '
          'The all-reviewed acceptable-category score is also saved in each JSON summary.', '',
          'Latency is native MPS inference amortized per message, not HTTP response time. '
          'Quoted-target, perspective and retrieved-example runs use individual requests; other runs use batches. '
          'Prompt variants have different question counts and context lengths. Potential truncation counts '
          'are conservative bounds; a winner must be checked for actual lost context before claiming a win.', '',
          '## Development score adjustments', '',
          'These experiments adjust class decision scores; they do not change the prompt or produce calibrated confidence. '
          'Offsets or thresholds are fitted on one set of development conversations and selected on another. '
          'Both sets remain development data; these are not held-out validation or test results.', '',
          '| Checkpoint / prompt / adjustment | Development messages scored | Raw fact/task F1 | Adjusted fact/task F1 | Raw task F1 | Adjusted task F1 |',
          '|---|---:|---:|---:|---:|---:|']
for path in sorted(list(OUT.glob('*/development-score-offsets.json')) + list(OUT.glob('*/development-score-thresholds.json'))):
    d = json.loads(path.read_text())
    c = json.loads((path.parent / 'config.json').read_text())
    raw = d['rawAllDevelopment']; adjusted = d['adjustedAllDevelopment']
    method = 'offsets' if 'offsets' in path.name else 'thresholds'
    lines.append(f"| {c['checkpoint']} / {c['variant']} / {method} | {d['fitCount'] + d['internalSelectionCount']} clear labels | {raw['facts']['f1']:.1%} | {adjusted['facts']['f1']:.1%} | {raw['tasks']['f1']:.1%} | {adjusted['tasks']['f1']:.1%} |")
large_runs = [(path, d) for path, d in rows if d['split'] == 'development']
if large_runs:
    lines += ['', '## Limits of filtering the existing predictions', '',
              'These are theoretical upper bounds, not measured results: imagine keeping every correctly classified positive '
              'and removing every other positive prediction. Filtering cannot recover missed items or change their category. '
              'The bound is 2 × correct / (reference + correct).', '',
              '| Run | Maximum fact/task F1 with perfect filtering | Maximum task F1 with perfect filtering |',
              '|---|---:|---:|']
    all_task_bounds_below = True
    for path, d in large_runs:
        c = d['config']; s = d['laya']
        bounds = {name: 2*s[name]['correct']/max(1, s[name]['reference']+s[name]['correct']) for name in ['facts', 'tasks']}
        all_task_bounds_below &= bounds['tasks'] < d['gemini']['tasks']['f1']
        lines.append(f"| {c['checkpoint']} / {c['variant']} | {bounds['facts']:.2%} | {bounds['tasks']:.2%} |")
    if all_task_bounds_below:
        lines += ['', 'Filtering alone cannot close the task-quality gap in the runs shown. '
                  'Further progress must also improve which messages are classified correctly.', '']
lines += ['', '## Conversation-level uncertainty', '',
          'Paired bootstrap intervals resample whole development conversations (2,000 replicates). '
          'They describe development variability, do not correct for prompt selection, and are not test-set evidence.', '',
          '| Checkpoint / prompt | Conversations | Fact/task F1 difference vs Gemini | 95% interval, percentage points |',
          '|---|---:|---:|---:|']
for path in sorted(OUT.glob('*/development-clustered-comparison.json')):
    d = json.loads(path.read_text())
    c = json.loads((path.parent / 'config.json').read_text())
    metric = d['metrics']['factTaskF1']
    low, high = metric['delta95PercentileInterval']
    lines.append(f"| {c['checkpoint']} / {c['variant']} | {d['conversations']} | {metric['delta']*100:+.1f} pp | [{low*100:+.1f}, {high*100:+.1f}] |")
lines += ['', '## Files', '',
          '- Runner: `tools/laya_prompt_search.py`',
          '- Split, raw predictions, exact prompts, package versions and model revision: ignored `Build/Laya/prompt-search/`.',
          '- Every newer run directory includes a copy of its runner and a config hash; results resume only under an identical config.',
          '- Refresh this report: `python3 tools/report_laya_prompt_search.py`.', '',
          'All inference runs locally. This experiment measures bounded-window extraction, not summary-writing or whole-app quality.', '']
target = ROOT / 'docs/laya-prompt-research.md'
target.write_text('\n'.join(lines))
print('\n'.join(lines))
