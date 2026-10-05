#!/usr/bin/env python3
"""Development-only decision-score experiment, separate from prompt-only results.

Fits small class offsets, not model weights and not calibrated probabilities.
Validation and test labels are never read for selection by this tool.
"""
import argparse
import hashlib
import json
import pathlib
import numpy as np
import laya_prompt_search as research


def metrics(prediction, truth):
    exact = prediction == truth
    result = {'agreement': float(exact.mean())}
    for name, lower in [('facts', 1), ('tasks', 2)]:
        predicted = (prediction >= lower) & (prediction <= 4)
        reference = (truth >= lower) & (truth <= 4)
        correct = int((exact & predicted).sum())
        precision = correct / max(1, int(predicted.sum()))
        recall = correct / max(1, int(reference.sum()))
        result[name] = {'precision': precision, 'recall': recall,
                        'f1': 2*precision*recall/max(1e-12, precision+recall)}
    return result


def objective(m):
    return .45*m['facts']['f1'] + .35*m['tasks']['f1'] + .20*m['agreement']


def features(row):
    answers = row['answers']
    if 'salience' in answers:
        raise ValueError('Gated pipelines need joint gate/content tuning; do not silently ignore the gate')
    if 'content' in answers:
        return 'content', answers['content']['probabilities']
    if 'category' in answers:
        return 'category', answers['category']['probabilities']
    if all(a['type'] == 'noul' for a in answers.values()):
        return 'noul', {k: a['noul'] for k, a in answers.items()}
    if all(k.startswith('rotation') for k in answers):
        keys = list(next(iter(answers.values()))['probabilities'])
        mode = 'category' if 'none' in keys else 'content'
        return mode, {k: sum(a['probabilities'][k] for a in answers.values())/len(answers) for k in keys}
    raise ValueError('This pipeline does not have one comparable set of class scores')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest, samples, labels = research.prepare()
    rows = {r['key']: r for line in (args.run/'development.jsonl').read_text().splitlines() for r in [json.loads(line)]}
    assert set(rows) == set(manifest['splits']['development']), 'Requires complete development predictions'
    config = json.loads((args.run/'config.json').read_text())
    assert all(r['configHash'] == research.sha(config) for r in rows.values())
    keys = sorted(k for k in rows if labels[k]['confidence'] != 'low'
                  and len(labels[k]['acceptableCategories']) == 1 and labels[k]['category'] != 'complex')
    mode, first = features(rows[keys[0]])
    options = list(first)
    truth = np.array([research.KINDS.index(labels[k]['category']) for k in keys])
    direction = np.array([int(samples[k]['message']['outgoing']) for k in keys])
    values = np.array([[features(rows[k])[1][c] for c in options] for k in keys])
    values = np.clip(values, 1e-6, 1-1e-6)
    scores = np.log(values/(1-values)) if mode == 'noul' else np.log(values)
    mapping = np.empty((len(keys), len(options)), dtype=int)
    for j, name in enumerate(options):
        if mode == 'category':
            mapping[:, j] = research.KINDS.index(name)
        elif name in ['noise', 'information', 'complex']:
            mapping[:, j] = {'noise': 0, 'information': 1, 'complex': 5}[name]
        elif name == 'promise':
            mapping[:, j] = np.where(direction, 3, 4)
        elif name == 'request':
            mapping[:, j] = np.where(direction, 4, 3)
        elif name == 'question':
            mapping[:, j] = np.where(direction, 4, 2)
        else:
            raise ValueError(name)
    fit = np.array([int(hashlib.sha256((samples[k]['message']['source'] + ':' + samples[k]['message']['chat'] + ':offset-fit').encode()).hexdigest()[:8], 16) % 5 != 0 for k in keys])
    tune = ~fit
    assert fit.any() and tune.any()
    ids = np.arange(len(keys))
    def predict(offsets):
        return mapping[ids, np.argmax(scores + offsets[direction], axis=1)]
    def evaluate(offsets, mask):
        return metrics(predict(offsets)[mask], truth[mask])
    grid = [-4, -3, -2, -1.5, -1, -.5, 0, .5, 1, 1.5, 2, 3, 4]
    rng = np.random.default_rng(20260928)
    candidates = [np.zeros((2, len(options)))]
    anchor = options.index('none' if mode == 'category' else 'noise')
    for restart in range(6):
        current = np.zeros((2, len(options))) if restart == 0 else rng.uniform(-1, 1, (2, len(options)))
        current[:, anchor] = 0
        for _ in range(4):
            changed = False
            for direction_index in range(2):
                for column in range(len(options)):
                    if column == anchor:
                        continue
                    before = current[direction_index, column]
                    best = objective(evaluate(current, fit)) - .0002*float((current**2).sum())
                    choice = before
                    for value in grid:
                        current[direction_index, column] = value
                        score = objective(evaluate(current, fit)) - .0002*float((current**2).sum())
                        if score > best:
                            best, choice = score, value
                    current[direction_index, column] = choice
                    changed |= choice != before
            if not changed:
                break
        candidates.append(current.copy())
    winner = max(candidates, key=lambda x: objective(evaluate(x, tune)))
    zeros = np.zeros_like(winner)
    report = {'sourceConfigHash': research.sha(config), 'sourceRun': str(args.run), 'options': options,
              'offsetsByOutgoing': winner.tolist(), 'fitCount': int(fit.sum()), 'internalSelectionCount': int(tune.sum()),
              'method': 'Class score offsets fitted and selected only inside development conversations. These are decision adjustments, not calibrated confidence probabilities. No validation/test access.',
              'rawFit': evaluate(zeros, fit), 'adjustedFit': evaluate(winner, fit),
              'rawInternalSelection': evaluate(zeros, tune), 'adjustedInternalSelection': evaluate(winner, tune),
              'rawAllDevelopment': metrics(predict(zeros), truth), 'adjustedAllDevelopment': metrics(predict(winner), truth)}
    (args.run/'development-score-offsets.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
