#!/usr/bin/env python3
"""Expand the highest prevalence-weighted development screen to the large split."""
import argparse
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'Build/Laya/prompt-search'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--after-pid', type=int)
    parser.add_argument('--selection', choices=['facts', 'joint'], default='facts')
    args = parser.parse_args()
    if args.after_pid:
        while True:
            check = subprocess.run(['ps', '-p', str(args.after_pid), '-o', 'command='], capture_output=True, text=True)
            if check.returncode or not any(name in check.stdout for name in ['laya_prompt_search.py', 'run_laya_prompt_round.py']):
                break
            time.sleep(5)
    subprocess.run([sys.executable, 'tools/laya_screen_selection.py'], cwd=ROOT, check=True)
    ranking = json.loads((OUT / 'weighted-screen-selection.json').read_text())
    selected = (ranking['results'][0] if args.selection == 'facts' else
                next(row for row in ranking['results'] if row['run'] == ranking['jointRankedRuns'][0]))
    selected['selectionPolicy'] = args.selection
    config = selected['config']
    (OUT / 'development-candidate-selection.json').write_text(json.dumps(selected, indent=2))
    history = OUT / 'development-selections'
    history.mkdir(exist_ok=True)
    (history / (str(time.time_ns()) + '.json')).write_text(json.dumps(selected, indent=2))
    print('EXPAND', config['checkpoint'], config['variant'], 'to 5274 development messages', flush=True)
    log = OUT / 'weighted-candidate-development.log'
    with log.open('a') as output:
        command = ([sys.executable, 'tools/laya_entailment_eval.py', '--variant', config['variant']] if config['variant'].startswith('entailment') else
                   [sys.executable, 'tools/laya_prompt_search.py', '--variant', config['variant']])
        subprocess.run(command + ['--checkpoint', config['checkpoint'], '--split', 'development', '--max-len', '8192'],
                       cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
    subprocess.run([sys.executable, 'tools/report_laya_prompt_search.py'], cwd=ROOT, stdout=subprocess.DEVNULL, check=True)
    print('LARGE DEVELOPMENT RUN COMPLETE. Validation/test untouched.', flush=True)


if __name__ == '__main__':
    main()
