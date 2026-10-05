#!/usr/bin/env python3
"""Rank development screens with the full development class prevalence.

These importance-weighted estimates select a larger experiment; they are not
substitutes for actually running it. Frozen screen keys are not changed.
"""
import collections
import json
import laya_prompt_search as research


def main():
    manifest, _, labels = research.prepare()
    clear = lambda k: (labels[k]['confidence'] != 'low' and len(labels[k]['acceptableCategories']) == 1
                       and labels[k]['category'] != 'complex')
    development = [k for k in manifest['splits']['development'] if clear(k)]
    screen = [k for k in manifest['splits']['screen'] if clear(k)]
    population = collections.Counter(labels[k]['category'] for k in development)
    sample = collections.Counter(labels[k]['category'] for k in screen)
    assert all(sample[c] for c in population)
    weights = {k: population[labels[k]['category']] / sample[labels[k]['category']] for k in screen}
    results = []
    for path in research.OUT.glob('*/screen-summary.json'):
        summary = json.loads(path.read_text())
        predictions = {row['key']: row['choice'] for line in path.with_name('screen.jsonl').read_text().splitlines()
                       for row in [json.loads(line)]}
        assert set(predictions) == set(manifest['splits']['screen'])
        estimate = {'agreement': sum(weights[k] for k in screen if predictions[k] == labels[k]['category']) / len(development)}
        for name, categories in [('facts', {'fact', 'reply', 'action', 'owes'}), ('tasks', {'reply', 'action', 'owes'})]:
            predicted = sum(weights[k] for k in screen if predictions[k] in categories)
            reference = sum(weights[k] for k in screen if labels[k]['category'] in categories)
            correct = sum(weights[k] for k in screen if predictions[k] in categories and predictions[k] == labels[k]['category'])
            precision = correct / max(1, predicted)
            recall = correct / max(1, reference)
            estimate[name] = {'precision': precision, 'recall': recall, 'f1': 2*precision*recall/max(1e-12, precision+recall)}
        results.append({'run': path.parent.name, 'config': summary['config'], 'estimatedDevelopment': estimate,
                        'screen': summary['laya']})
    results.sort(key=lambda row: (row['estimatedDevelopment']['facts']['f1'], row['estimatedDevelopment']['tasks']['f1']), reverse=True)
    baseline = research.baseline('gemini', set(manifest['splits']['development']), labels)
    for row in results:
        e = row['estimatedDevelopment']
        row['minimumRatioToGemini'] = min(e['agreement'] / baseline['agreement'],
                                         e['facts']['f1'] / baseline['facts']['f1'],
                                         e['tasks']['f1'] / baseline['tasks']['f1'])
    joint = sorted(results, key=lambda row: (row['minimumRatioToGemini'], row['estimatedDevelopment']['facts']['f1']), reverse=True)
    report = {'method': 'Importance-weight each clear screen reference category to its frequency in the complete development set. '
                        'Development-only selection estimate, not a measured full-development result or a test-set score.',
              'developmentClear': len(development), 'screenClear': len(screen), 'results': results,
              'jointSelectionMethod': 'Rank by the weakest estimated ratio to Gemini across agreement, fact/task F1, and task F1. This prevents a fact-only gain from hiding a task regression.',
              'jointRankedRuns': [row['run'] for row in joint]}
    research.save(research.OUT / 'weighted-screen-selection.json', report)
    for row in results:
        e = row['estimatedDevelopment']
        print(row['config']['checkpoint'], row['config']['variant'],
              'estimated fact/task F1', round(100*e['facts']['f1'], 1), 'task F1', round(100*e['tasks']['f1'], 1))


if __name__ == '__main__':
    main()
