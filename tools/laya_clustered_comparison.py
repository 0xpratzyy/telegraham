#!/usr/bin/env python3
"""Paired conversation-bootstrap intervals for a completed development run."""
import argparse
import collections
import json
import pathlib
import numpy as np
import laya_prompt_search as research


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest, samples, labels = research.prepare()
    path = args.run / 'development.jsonl'
    local_rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(local_rows) == len({row['key'] for row in local_rows}), 'Duplicate prediction rows'
    local = {row['key']: row['choice'] for row in local_rows}
    assert set(local) == set(manifest['splits']['development']), 'Requires complete development predictions'
    config = json.loads((args.run / 'config.json').read_text())
    assert all(row['configHash'] == research.sha(config) for row in local_rows)
    gemini = {}
    for line in (research.old.BASE / 'results.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row['model'] == 'gemini' and 'error' not in row:
            gemini.update({answer['key']: answer['choice'] for answer in row['answers']})
    keys = sorted(k for k in local if labels[k]['confidence'] != 'low'
                  and len(labels[k]['acceptableCategories']) == 1 and labels[k]['category'] != 'complex')
    groups = collections.defaultdict(list)
    for key in keys:
        m = samples[key]['message']
        groups[(m['source'], m['chat'])].append(key)
    positive = {'fact', 'reply', 'action', 'owes'}
    tasks = positive - {'fact'}
    counts = np.zeros((2, len(groups), 8), dtype=np.float64)
    for group_index, group in enumerate(groups.values()):
        for model_index, predictions in enumerate([local, gemini]):
            for key in group:
                truth, predicted = labels[key]['category'], predictions[key]
                correct = truth == predicted
                counts[model_index, group_index] += [1, correct, predicted in positive, truth in positive,
                                                     correct and truth in positive, predicted in tasks,
                                                     truth in tasks, correct and truth in tasks]

    def metrics(c):
        return np.stack([c[..., 1] / np.maximum(1, c[..., 0]),
                         2*c[..., 4] / np.maximum(1, c[..., 2] + c[..., 3]),
                         2*c[..., 7] / np.maximum(1, c[..., 5] + c[..., 6])], axis=-1)

    point = metrics(counts.sum(axis=1))
    rng = np.random.default_rng(20260928)
    indices = rng.integers(0, len(groups), size=(2000, len(groups)))
    sampled = metrics(counts[:, indices, :].sum(axis=2))
    delta = sampled[0] - sampled[1]
    intervals = {}
    for i, name in enumerate(['agreement', 'factTaskF1', 'taskF1']):
        intervals[name] = {'laya': float(point[0, i]), 'gemini': float(point[1, i]),
                           'delta': float(point[0, i] - point[1, i]),
                           'delta95PercentileInterval': np.percentile(delta[:, i], [2.5, 97.5]).tolist()}
    report = {'sourceConfigHash': research.sha(config), 'split': 'development',
              'messages': len(local), 'clearLabels': len(keys), 'conversations': len(groups),
              'bootstrapReplicates': 2000, 'metrics': intervals,
              'method': 'Paired bootstrap of complete conversations with replacement. Descriptive development intervals only; '
                        'they do not correct for prompt selection or establish a held-out test win.'}
    research.save(args.run / 'development-clustered-comparison.json', report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
