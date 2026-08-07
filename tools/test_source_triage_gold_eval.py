import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.source_triage_gold_eval import evaluate, load_fixture, resolve_message


class SourceTriageGoldEvalTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(
            """
            CREATE TABLE messages (
                id INTEGER, chat_id INTEGER, date REAL, source TEXT,
                external_id TEXT, PRIMARY KEY(id, chat_id)
            );
            CREATE TABLE id_map (int_id INTEGER, source TEXT, native_id TEXT);
            CREATE TABLE facts (
                id INTEGER PRIMARY KEY, predicate TEXT, loop_kind TEXT,
                action TEXT, subject_entity TEXT, confidence REAL,
                valid_from REAL, invalid_at REAL,
                source_chat_id INTEGER, source_message_id INTEGER
            );
            """
        )

    def tearDown(self):
        self.db.close()

    def test_resolves_gmail_by_external_id(self):
        self.db.execute("INSERT INTO messages VALUES (1, 10, 1, 'gmail:a@example.com', 'gmail-id')")
        case = {
            "source": "gmail", "account": "a@example.com",
            "message": {"externalId": "gmail-id"},
        }
        self.assertEqual(resolve_message(self.db, case).message_id, 1)

    def test_resolves_legacy_slack_through_id_map(self):
        self.db.execute("INSERT INTO messages VALUES (2, 20, 1, 'slack:T1', NULL)")
        self.db.execute("INSERT INTO id_map VALUES (2, 'slack:T1', 'msg:C1:123.456')")
        case = {
            "source": "slack", "account": "T1",
            "message": {"conversationExternalId": "C1", "externalId": "123.456"},
        }
        self.assertEqual(resolve_message(self.db, case).chat_id, 20)

    def test_missing_noise_is_correct_but_missing_task_is_false_negative(self):
        cases = [
            self.case("noise", "ignore", "missing-noise"),
            self.case("task", "task", "missing-task"),
        ]
        report = evaluate(self.db, cases)
        self.assertEqual(report["accuracy"], 0.5)
        self.assertEqual(report["ingestionCoverage"], 0)
        self.assertEqual(report["actionable"]["fn"], 1)
        self.assertEqual(report["perLabel"]["task"]["support"], 1)
        self.assertIn("gmail", report["bySource"])

    def test_open_fact_routes_task_and_invalidated_fact_does_not(self):
        self.db.executemany(
            "INSERT INTO messages VALUES (?, ?, 1, 'gmail:a@example.com', ?)",
            [(1, 10, "open"), (2, 20, "closed")],
        )
        self.db.executemany(
            "INSERT INTO facts VALUES (?, 'i_owe', 'action', 'Do work', 'Me', .9, 1, ?, ?, ?)",
            [(1, None, 10, 1), (2, 2, 20, 2)],
        )
        cases = [self.case("open", "task", "open"), self.case("closed", "ignore", "closed")]
        report = evaluate(self.db, cases)
        self.assertEqual(report["accuracy"], 1)

    def test_fixture_requires_approved_cases_by_default(self):
        payload = {
            "schemaVersion": 1,
            "cases": [self.case("x", "ignore", "x", review="provisional")],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(payload))
            with self.assertRaises(ValueError):
                load_fixture(path)
            _, selected = load_fixture(path, include_provisional=True)
            self.assertEqual(len(selected), 1)

    @staticmethod
    def case(case_id, label, external_id, review="approved"):
        return {
            "id": case_id,
            "source": "gmail",
            "account": "a@example.com",
            "message": {"externalId": external_id},
            "gold": {"label": label},
            "review": {"status": review},
        }


if __name__ == "__main__":
    unittest.main()
