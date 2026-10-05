#!/usr/bin/env python3
"""Run a finite local research round, then expand its best prompt to all development data."""
import argparse
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'Build/Laya/prompt-search'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--after-pid', type=int)
    parser.add_argument('--round', type=int, choices=[2, 3, 4, 5, 6, 7, 8, 9, 10], default=2)
    parser.add_argument('--screen-only', action='store_true')
    args = parser.parse_args()
    if args.after_pid:
        # Verify that the prior experiment really exists; never treat a log as a live job.
        while True:
            check = subprocess.run(['ps', '-p', str(args.after_pid), '-o', 'command='], capture_output=True, text=True)
            if check.returncode or not any(name in check.stdout for name in ['laya_prompt_search.py', 'run_laya_prompt_round.py']):
                break
            time.sleep(5)
    jobs = ([(checkpoint, variant) for checkpoint in ['typed-decisions', 'english']
             for variant in ['examples', 'nli']] if args.round == 2 else
            [('typed-decisions', 'quoted'), ('english', 'balanced_options'),
             ('typed-decisions', 'balanced_options')])
    if args.round == 4:
        jobs = [('english', 'workflow'), ('typed-decisions', 'workflow')]
    if args.round == 5:
        jobs = [('typed-decisions', 'gated'), ('english', 'gated'), ('typed-decisions', 'gated_context')]
    if args.round == 6:
        jobs = [('english', 'retrieved'), ('typed-decisions', 'retrieved')]
    if args.round == 7:
        jobs = [('english', 'perspective'), ('typed-decisions', 'perspective')]
    if args.round == 8:
        jobs = [('multilingual', 'raw_content'), ('multilingual', 'nli'), ('multilingual', 'balanced_options')]
    if args.round == 9:
        jobs = [('typed-decisions', variant) for variant in ['durable_options', 'explicit_options', 'strict_options']]
    if args.round == 10:
        jobs = [('multilingual', variant) for variant in ['durable_options', 'explicit_options', 'strict_options']]
    for checkpoint, variant in jobs:
        print('START', checkpoint, variant, 'screen', flush=True)
        log = OUT / f'round{args.round}-{checkpoint}-{variant}.log'
        with log.open('a') as out:
            subprocess.run([sys.executable, 'tools/laya_prompt_search.py', '--checkpoint', checkpoint,
                            '--variant', variant, '--split', 'screen', '--max-len',
                            '8192' if variant in ['quoted', 'retrieved', 'perspective'] else '2048'], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=True)
        subprocess.run([sys.executable, 'tools/report_laya_prompt_search.py'], cwd=ROOT, stdout=subprocess.DEVNULL, check=True)
        print('DONE', checkpoint, variant, flush=True)
    if args.screen_only:
        print('SCREEN ROUND COMPLETE; validation and test remain unopened', flush=True)
        return
    summaries = [(p, json.loads(p.read_text())) for p in OUT.glob('*/screen-summary.json')]
    path, best = max(summaries, key=lambda item: (item[1]['laya']['facts']['f1'], item[1]['laya']['tasks']['f1']))
    config = best['config']
    print('EXPAND', config['checkpoint'], config['variant'], '5274 development messages', flush=True)
    with (OUT / 'full-development.log').open('a') as out:
        subprocess.run([sys.executable, 'tools/laya_prompt_search.py', '--checkpoint', config['checkpoint'],
                        '--variant', config['variant'], '--split', 'development', '--max-len', '8192'],
                       cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=True)
    subprocess.run([sys.executable, 'tools/report_laya_prompt_search.py'], cwd=ROOT, stdout=subprocess.DEVNULL, check=True)
    print('ROUND COMPLETE; validation and test remain unopened', flush=True)


if __name__ == '__main__':
    main()
