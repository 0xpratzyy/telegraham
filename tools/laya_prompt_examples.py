"""Development-only examples for a local few-shot prompt experiment.

Each target excludes its entire conversation and exact duplicate text. Validation
and test labels are never used to build the example bank.
"""
import collections
import hashlib
import json
import math
import re


def words(text):
    return set(re.findall(r'[^\W_]+', text.casefold()))


class Examples:
    def __init__(self, manifest, samples, labels):
        self.bank = []
        for key in manifest['splits']['development']:
            label = labels[key]
            message = samples[key]['message']
            text = message['text'].strip()
            if (label['confidence'] == 'low' or len(label['acceptableCategories']) != 1
                    or label['category'] == 'complex' or not text or len(text) > 80):
                continue
            self.bank.append({'key': key, 'text': text, 'category': label['category'],
                              'outgoing': message['outgoing'], 'chat': (message['source'], message['chat'])})
        self.sha = hashlib.sha256(json.dumps(self.bank, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        self.tokens = [words(row['text']) for row in self.bank]
        counts = collections.Counter(token for tokens in self.tokens for token in tokens)
        self.idf = {token: math.log(1 + len(self.bank) / count) for token, count in counts.items()}

    def question(self, sample, base, tokenizer):
        target = sample['message']
        query = words(target['text'])
        chat = (target['source'], target['chat'])
        selected = {}
        for row, tokens in zip(self.bank, self.tokens):
            if row['chat'] == chat or row['outgoing'] != target['outgoing'] or tokens == query:
                continue
            overlap = tokens & query
            if not overlap:
                continue
            score = sum(self.idf[token] for token in overlap) / math.sqrt(max(1, len(tokens) * len(query)))
            category = row['category']
            if category not in selected or score > selected[category][0]:
                selected[category] = (score, row)
        short = {'none': 'Nothing durable to save.', 'fact': 'Save a lasting fact.',
                 'reply': 'ME must answer.', 'action': 'ME must do work.', 'owes': 'Someone owes ME.'}
        criteria = dict(base)
        used = []
        for category, (_, row) in selected.items():
            description = short[category] + ' Example: ' + json.dumps(row['text'], ensure_ascii=False)
            # The SDK caps each choice at 48 tokens. Never silently crop an example.
            if len(tokenizer.encode(category + ': ' + description, add_special_tokens=False)) <= 47:
                criteria[category] = description
                used.append(row['key'])
        return {'category': {'type': 'choice', 'instructions':
                'Classify only TARGET. ME is the app owner. Other messages are context. '
                'Each option may show an example from a DIFFERENT conversation with the same sender direction. '
                'Examples illustrate categories; do not extract them. '
                'A resolved request needs no action. Unclear ownership or multiple useful items are complex.',
                'criteria': criteria}}, used
