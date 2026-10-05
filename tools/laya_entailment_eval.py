#!/usr/bin/env python3
"""Evaluate premise/hypothesis prompts, matching the public Laya XNLI input shape.

Reference: https://github.com/NandhaKishorM/laya/blob/main/research/scripts/build_benchmark_nb.py
No training, cloud calls, validation, or test-set access.
"""
import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import pathlib
import statistics
import subprocess
import time
import laya_prompt_search as research
SOURCE_BYTES = pathlib.Path(__file__).read_bytes()
RESEARCH_SOURCE_BYTES = pathlib.Path(research.__file__).read_bytes()

HYPOTHESES = {
    'noise': 'The speaker is making casual conversation or acknowledging something.',
    'information': 'The speaker communicates a concrete fact or decision worth remembering.',
    'question': 'The speaker wants someone to answer a question.',
    'request': 'The speaker wants someone else to perform work or provide a deliverable.',
    'promise': 'The speaker commits to performing work or providing a deliverable.',
}
CONTEXT_HYPOTHESES = {
    'fact': 'The TARGET message establishes one concrete lasting fact or decision worth remembering.',
    'reply': 'At the end of these messages, ME still owes someone a quick answer or confirmation because of TARGET.',
    'action': 'At the end of these messages, ME still owes someone concrete work or a deliverable because of TARGET.',
    'owes': 'At the end of these messages, another person still owes ME an answer, work or a deliverable because of TARGET.',
}
QUESTIONS = {'relation': {'type': 'choice',
    'instructions': 'What is the relationship between `premise` and `hypothesis`?',
    'criteria': {'entailment': 'The premise supports the hypothesis.',
                 'neutral': 'There is insufficient evidence either way.',
                 'contradiction': 'The premise contradicts the hypothesis.'}}}


def decisions(results, samples, keys, hypotheses, direct=False):
    rows = []
    for i, key in enumerate(keys):
        answers = {name: results[i*len(hypotheses)+j]['answers']['relation']
                   for j, name in enumerate(hypotheses)}
        eligible = [name for name, answer in answers.items() if answer['choice'] == 'entailment']
        content = max(eligible, key=lambda name: answers[name]['probabilities']['entailment']) if eligible else ('none' if direct else 'noise')
        choice = content if direct else research.assemble({'content': {'choice': content}}, samples[key], 'raw_content')
        rows.append({'key': key, 'choice': choice, 'answers': answers})
    return rows


def run(args, checkpoint):
    import torch
    from laya import Agent
    from laya.common import serialize_state
    torch.set_num_threads(4)
    manifest, samples, labels = research.prepare()
    keys = manifest['splits'][args.split]
    direct = args.variant == 'entailment_context'
    hypotheses = CONTEXT_HYPOTHESES if direct else HYPOTHESES
    batch_size = 1 if direct else 8
    chunk_size = 1 if direct else 16
    if direct:
        torch.mps.set_per_process_memory_fraction(0.30)
    config = {'variant': args.variant, 'checkpoint': checkpoint, 'modelRevision': research.REVISION,
              'maxLen': args.max_len, 'headMaxLen': 384, 'questions': QUESTIONS, 'hypotheses': hypotheses,
              'batchSize': batch_size, 'context': 'entire same-conversation window' if direct else 'target only',
              'chunkSize': chunk_size, 'clearMPSCacheAfterChunk': direct,
              'mpsMemoryFraction': 0.30 if direct else None,
              'policy': 'Highest entailment probability among hypotheses classified entailed; otherwise none.',
              'researchSourceSHA256': hashlib.sha256(RESEARCH_SOURCE_BYTES).hexdigest(),
              'stateFunctionVersion': 1, 'sourceSHA256': hashlib.sha256(SOURCE_BYTES).hexdigest()}
    digest = research.sha(config)
    directory = research.OUT / (checkpoint + '-' + args.variant + '-' + str(args.max_len) + '-' + digest[:10])
    directory.mkdir(exist_ok=True)
    research.save(directory / 'config.json', config)
    (directory / 'runner-source.py').write_bytes(SOURCE_BYTES)
    (directory / 'research-source.py').write_bytes(RESEARCH_SOURCE_BYTES)
    path = directory / (args.split + '.jsonl')
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    assert all(row['configHash'] == digest for row in rows)
    done = {row['key'] for row in rows}
    remaining = [key for key in keys if key not in done]
    if remaining:
        agent = Agent('convaiinnovations/laya', subfolder=None if checkpoint == 'english' else checkpoint,
                      device='mps', revision=research.REVISION)
        def states(selected):
            return [{'premise': ('ME is the app owner.\n' + research.state(samples[key], 'conversation') if direct else
                                 samples[key]['message']['text']), 'hypothesis': hypothesis}
                    for key in selected for hypothesis in hypotheses.values()]
        if batch_size > 1:
            probe = remaining[:8]
            single = agent.predict_batch(states(probe), QUESTIONS, batch_size=1, max_len=args.max_len, head_max_len=384)
            batch = agent.predict_batch(states(probe), QUESTIONS, batch_size=batch_size, max_len=args.max_len, head_max_len=384, sort_by_length=True)
            different = [a['key'] for a, b in zip(decisions(single, samples, probe, hypotheses, direct), decisions(batch, samples, probe, hypotheses, direct)) if a['choice'] != b['choice']]
            assert len(different) <= 1, 'Investigate batch instability'
            research.save(directory / (args.split + '-batch-parity.json'), {'samples': len(probe), 'differences': different})
            print(checkpoint, 'single/batch parity', len(probe)-len(different), '/', len(probe), flush=True)
        else:
            print(checkpoint, 'single-example inference; no batching parity comparison needed', flush=True)
        with path.open('a') as output:
            for offset in range(0, len(remaining), chunk_size):
                selected = remaining[offset:offset+chunk_size]
                batch_states = states(selected)
                counts = [len(agent.tok.encode(serialize_state(s), add_special_tokens=False)) for s in batch_states]
                start = time.perf_counter()
                answers = agent.predict_batch(batch_states, QUESTIONS, batch_size=batch_size, max_len=args.max_len,
                                              head_max_len=384, sort_by_length=True)
                if direct:
                    torch.mps.empty_cache()
                elapsed = (time.perf_counter()-start)*1000
                for i, row in enumerate(decisions(answers, samples, selected, hypotheses, direct)):
                    n = max(counts[i*len(hypotheses):(i+1)*len(hypotheses)])
                    row.update({'configHash': digest, 'msAmortized': elapsed/len(selected), 'stateTokens': n,
                                'mayTruncateState': n+388 > args.max_len, 'budgetAbstention': False})
                    output.write(json.dumps(row)+'\n'); rows.append(row)
                output.flush()
                if offset % 64 == 0:
                    print(checkpoint, args.split, offset+len(selected), '/', len(remaining), flush=True)
        research.save(directory / 'runtime.json', {'device': str(agent.device), 'revision': agent.revision,
                      'cpuFallbackCount': agent.cpu_fallback_count,
                      'packages': {name: importlib.metadata.version(name) for name in ['laya', 'torch', 'transformers']}})
        del agent
        gc.collect()
        torch.mps.empty_cache()
    assert len(rows) == len({row['key'] for row in rows}) and {row['key'] for row in rows} == set(keys)
    summary = {'config': config, 'split': args.split, 'total': len(keys),
               'laya': research.metrics(rows, labels, keys), 'gemini': research.baseline('gemini', set(keys), labels),
               'medianAmortizedMS': statistics.median(row['msAmortized'] for row in rows),
               'potentiallyTruncatedStates': sum(row['mayTruncateState'] for row in rows), 'budgetAbstentions': 0}
    research.save(directory / (args.split + '-summary.json'), summary)
    print(json.dumps(summary, indent=2), flush=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', choices=['english', 'multilingual', 'typed-decisions', 'all'], default='all')
    parser.add_argument('--variant', choices=['entailment', 'entailment_context'], default='entailment')
    parser.add_argument('--split', choices=['screen', 'development'], default='screen')
    parser.add_argument('--max-len', type=int, default=2048)
    parser.add_argument('--after-pid', type=int)
    args = parser.parse_args()
    if args.after_pid:
        while True:
            result = subprocess.run(['ps', '-p', str(args.after_pid), '-o', 'command='], capture_output=True, text=True)
            if result.returncode or 'laya_' not in result.stdout:
                break
            time.sleep(5)
    for checkpoint in (['english', 'multilingual'] if args.checkpoint == 'all' else [args.checkpoint]):
        run(args, checkpoint)


if __name__ == '__main__':
    main()
