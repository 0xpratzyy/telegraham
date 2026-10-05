#!/usr/bin/env python3
"""One frozen validation comparison of four completed large-development candidates.

Validation selects among fixed candidates. This script does not tune prompts or
open the final test split.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import laya_prompt_search as research

CANDIDATES = [('english', 'nli'), ('typed-decisions', 'balanced_options'),
              ('multilingual', 'durable_options'), ('multilingual', 'balanced_options')]


def main():
    manifest, _, _ = research.prepare()
    source = pathlib.Path(research.__file__)
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    candidates = []
    for checkpoint, variant in CANDIDATES:
        matches = [p for p in research.OUT.glob('*/development-summary.json')
                   if (lambda c: c['checkpoint'] == checkpoint and c['variant'] == variant)(json.loads(p.read_text())['config'])]
        assert len(matches) == 1, 'Resolve duplicate/missing development evidence before validation'
        evidence = json.loads(matches[0].read_text())
        assert evidence['total'] == len(manifest['splits']['development'])
        assert evidence['config']['questions'] == research.prompt(variant), 'Prompt changed after development evaluation'
        candidates.append({'checkpoint': checkpoint, 'variant': variant, 'maxLen': 8192,
                           'developmentRun': matches[0].parent.name, 'developmentConfig': evidence['config']})
    slate = {'splitSHA256': research.sha(manifest), 'runnerSourceSHA256': source_sha, 'candidates': candidates,
             'method': 'Frozen before validation. Four completed large-development candidates; unchanged question definitions. '
                       'Choose among these candidates only. No prompt changes using validation labels; final test remains unopened.'}
    path = research.OUT / 'validation-slate.json'
    if path.exists():
        assert json.loads(path.read_text()) == slate, 'Frozen validation slate changed'
    else:
        research.save(path, slate)
    results = []
    for candidate in candidates:
        assert hashlib.sha256(source.read_bytes()).hexdigest() == source_sha, 'Runner changed during validation'
        checkpoint, variant = candidate['checkpoint'], candidate['variant']
        print('VALIDATE', checkpoint, variant, '1285 messages', flush=True)
        with (research.OUT / ('validation-' + checkpoint + '-' + variant + '.log')).open('a') as log:
            subprocess.run([sys.executable, str(source), '--checkpoint', checkpoint, '--variant', variant,
                            '--split', 'validation', '--max-len', '8192'], cwd=research.ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        matching = [p for p in research.OUT.glob('*/validation-summary.json')
                    if (lambda c: c['checkpoint'] == checkpoint and c['variant'] == variant and c['sourceSHA256'] == source_sha)(json.loads(p.read_text())['config'])]
        assert len(matching) == 1
        summary = json.loads(matching[0].read_text())
        local, baseline = summary['laya'], summary['gemini']
        checks = {'agreement': local['agreement'] >= baseline['agreement'],
                  'factTaskF1': local['facts']['f1'] > baseline['facts']['f1'],
                  'taskF1': local['tasks']['f1'] >= baseline['tasks']['f1']}
        results.append({'run': matching[0].parent.name, 'summary': summary, 'winGate': checks,
                        'passesAll': all(checks.values()),
                        'minimumRatioToGemini': min(local['agreement']/baseline['agreement'],
                                                   local['facts']['f1']/baseline['facts']['f1'],
                                                   local['tasks']['f1']/baseline['tasks']['f1'])})
        print('DONE', checkpoint, variant, 'facts F1', round(local['facts']['f1'], 4), 'tasks F1', round(local['tasks']['f1'], 4), flush=True)
    results.sort(key=lambda row: row['minimumRatioToGemini'], reverse=True)
    report = {'slate': slate, 'results': results,
              'anyCandidatePassesValidationGate': any(row['passesAll'] for row in results),
              'finalTestOpened': False}
    research.save(research.OUT / 'validation-comparison.json', report)
    subprocess.run([sys.executable, str(research.ROOT / 'tools/report_laya_prompt_search.py')],
                   cwd=research.ROOT, stdout=subprocess.DEVNULL, check=True)
    print('VALIDATION COMPLETE. Final test unopened.', flush=True)


if __name__ == '__main__':
    main()
