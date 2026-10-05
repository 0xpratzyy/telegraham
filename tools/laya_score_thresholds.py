#!/usr/bin/env python3
"""Fit absolute NLI decision thresholds using development conversations only.

These are decision rules, not calibrated confidence or prompt-only improvements.
"""
import argparse
import hashlib
import json
import pathlib
import numpy as np
import laya_prompt_search as research
from laya_score_offsets import metrics, objective


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest, samples, labels = research.prepare()
    config = json.loads((args.run / 'config.json').read_text())
    assert config['variant'] in ['nli', 'nli_context']
    rows = {row['key']: row for line in (args.run / 'development.jsonl').read_text().splitlines()
            for row in [json.loads(line)]}
    assert set(rows) == set(manifest['splits']['development'])
    assert all(row['configHash'] == research.sha(config) for row in rows.values())
    keys = sorted(k for k in rows if labels[k]['confidence'] != 'low'
                  and len(labels[k]['acceptableCategories']) == 1 and labels[k]['category'] != 'complex')
    names = ['information', 'question', 'request', 'promise']
    values = np.array([[rows[k]['answers'][name]['noul'] for name in names] for k in keys])
    assert np.isfinite(values).all() and ((values >= 0) & (values <= 1)).all()
    direction = np.array([int(samples[k]['message']['outgoing']) for k in keys])
    truth = np.array([research.KINDS.index(labels[k]['category']) for k in keys])
    raw = np.array([research.KINDS.index(rows[k]['choice']) for k in keys])
    # Category indices: none=0, fact=1, reply=2, action=3, owes=4.
    mapping = np.array([[1, 2, 3, 4], [1, 4, 4, 3]])[direction]
    fit = np.array([int(hashlib.sha256((samples[k]['message']['source'] + ':' +
                    samples[k]['message']['chat'] + ':offset-fit').encode()).hexdigest()[:8], 16) % 5 != 0
                    for k in keys])
    tune = ~fit
    assert fit.any() and tune.any()
    ids = np.arange(len(keys))

    def predict(thresholds):
        eligible = values >= thresholds[direction]
        best = np.where(eligible, values, -1).argmax(axis=1)
        return np.where(eligible.any(axis=1), mapping[ids, best], 0)

    def evaluate(thresholds, mask):
        return metrics(predict(thresholds)[mask], truth[mask])

    grid = [.3, .5, .6, .7, .8, .85, .9, .925, .95, .97, .98, .99, .995, .999, 1.001]
    candidates = []
    for initial in [.5, .8, .9, .97, .995]:
        current = np.full((2, 4), initial)
        for _ in range(4):
            changed = False
            for d in range(2):
                for column in range(4):
                    before = current[d, column]
                    best_score = objective(evaluate(current, fit))
                    best = before
                    for threshold in grid:
                        current[d, column] = threshold
                        score = objective(evaluate(current, fit))
                        if score > best_score:
                            best, best_score = threshold, score
                    current[d, column] = best
                    changed |= best != before
            if not changed:
                break
        candidates.append(current.copy())
    winner = max(candidates, key=lambda t: objective(evaluate(t, tune)))
    report = {
        'sourceConfigHash': research.sha(config), 'sourceRun': str(args.run),
        'method': 'Absolute positive-class thresholds fitted and selected within development conversations. '
                  'Among eligible classes select the largest raw NLI score; otherwise none. '
                  'A threshold above 1 disables a class. Scores are not calibrated probabilities. No validation/test selection.',
        'options': names, 'thresholdsByOutgoing': winner.tolist(),
        'fitCount': int(fit.sum()), 'internalSelectionCount': int(tune.sum()),
        'rawFit': metrics(raw[fit], truth[fit]), 'adjustedFit': evaluate(winner, fit),
        'rawInternalSelection': metrics(raw[tune], truth[tune]),
        'adjustedInternalSelection': evaluate(winner, tune),
        'rawAllDevelopment': metrics(raw, truth),
        'adjustedAllDevelopment': metrics(predict(winner), truth),
    }
    research.save(args.run / 'development-score-thresholds.json', report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
