#!/usr/bin/env python3
import argparse
import json
import re
import sqlite3
from collections import Counter
from pathlib import Path
from typing import Any, Optional


DEFAULT_DB = Path("/Users/pratyushrungta/Library/Application Support/Pidgy/pidgy.db")

STOP_WORDS = {
    "a", "about", "after", "all", "also", "and", "are", "as", "at", "be", "been", "before",
    "bro", "but", "by", "can", "could", "day", "days", "did", "do", "does", "doing", "done",
    "dont", "for", "from", "get", "give", "going", "good", "got", "guys", "had", "has", "have",
    "he", "her", "here", "him", "his", "how", "i", "if", "im", "in", "into", "is", "it", "its",
    "just", "know", "let", "lets", "like", "make", "me", "more", "my", "need", "not", "now", "of",
    "ok", "okay", "on", "one", "only", "or", "our", "out", "please", "right", "same", "so", "some",
    "still", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "to",
    "today", "too", "up", "use", "very", "want", "was", "we", "well", "what", "when", "where", "which",
    "who", "why", "will", "with", "would", "yeah", "yes", "yess", "you", "your"
}

BAD_GRAMS = {
    "let know", "right now", "few things", "how can", "you can", "days now",
    "get started", "first first", "view email", "join meeting", "test first"
}
BAD_TOKENS = {
    "http", "https", "www", "com", "view", "join", "email", "link", "status",
    "maps", "apple", "app", "goo"
}


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def tokenize(text: str) -> list[str]:
    cleaned = re.sub(r"https?://\\S+", " ", normalize(text))
    cleaned = re.sub(r"[^a-z0-9 ]+", " ", cleaned)
    return [token for token in cleaned.split() if len(token) >= 3 and token not in STOP_WORDS and not token.isdigit()]


def extract_ngrams(tokens: list[str], sizes: tuple[int, ...] = (2, 3)) -> Counter[str]:
    grams: Counter[str] = Counter()
    for size in sizes:
        for index in range(len(tokens) - size + 1):
            gram_tokens = tokens[index:index + size]
            if len(set(gram_tokens)) == 1:
                continue
            if any(token in BAD_TOKENS for token in gram_tokens):
                continue
            gram = " ".join(gram_tokens)
            if gram in BAD_GRAMS:
                continue
            grams[gram] += 1
    return grams


def prompt_templates(display_name: Optional[str], topic: str) -> list[str]:
    prompts = [
        f"What's latest with {topic}?",
        f"Show me discussions about {topic}.",
    ]
    if display_name and display_name.lower() not in topic:
        prompts.append(f"What's happening in {display_name} around {topic}?")
    return prompts


def main() -> int:
    parser = argparse.ArgumentParser(description="Mine natural topic-search prompts from the local Pidgy corpus.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--chat-limit", type=int, default=15)
    parser.add_argument("--messages-per-chat", type=int, default=120)
    parser.add_argument("--min-chat-messages", type=int, default=300)
    parser.add_argument("--min-gram-count", type=int, default=3)
    args = parser.parse_args()

    if not args.db.exists():
        raise SystemExit(f"DB not found: {args.db}")

    with sqlite3.connect(args.db) as conn:
        conn.row_factory = sqlite3.Row
        chat_rows = conn.execute(
            """
            SELECT
              m.chat_id,
              count(*) AS message_count,
              max(m.date) AS last_date,
              n.display_name
            FROM messages AS m
            LEFT JOIN nodes AS n ON n.entity_id = m.chat_id
            WHERE coalesce(m.text_content, '') <> ''
            GROUP BY m.chat_id
            HAVING count(*) >= ?
            ORDER BY last_date DESC
            LIMIT ?
            """,
            (args.min_chat_messages, args.chat_limit),
        ).fetchall()

        report: list[dict[str, Any]] = []
        for chat in chat_rows:
            messages = conn.execute(
                """
                SELECT coalesce(text_content, '') AS text_content
                FROM messages
                WHERE chat_id = ? AND length(coalesce(text_content, '')) >= 120
                ORDER BY date DESC
                LIMIT ?
                """,
                (chat["chat_id"], args.messages_per_chat),
            ).fetchall()

            grams: Counter[str] = Counter()
            for row in messages:
                grams.update(extract_ngrams(tokenize(row["text_content"])))

            candidates = [
                {"topic": gram, "count": count, "suggestedQueries": prompt_templates(chat["display_name"], gram)}
                for gram, count in grams.most_common(10)
                if count >= args.min_gram_count
            ]

            if not candidates:
                continue

            report.append(
                {
                    "chatId": int(chat["chat_id"]),
                    "displayName": chat["display_name"],
                    "messageCount": int(chat["message_count"]),
                    "topics": candidates[:6],
                }
            )

    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
