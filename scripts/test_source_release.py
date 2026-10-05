import tempfile
import unittest
from pathlib import Path
from scan_secrets import findings
from prepare_open_source import selected, export

class SourceReleaseTests(unittest.TestCase):
    def testSecretsAreReportedWithoutCredentialContent(self):
        secret = 'sk-' + 'q' * 45
        matches = findings(secret.encode(), 'Sources/key.swift')
        self.assertEqual(matches, [(1, 'provider key')])
        self.assertNotIn(secret, repr(matches))
        self.assertTrue(findings(b'-----BEGIN ' + b'PRIVATE KEY-----', 'key.pem'))
        self.assertTrue(findings(('AIza' + 'a' * 35).encode(), 'key.swift'))

    def testExportIncludesSourceButExcludesPrivateDataHistoryAndSymlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'; root.mkdir()
            for name in ['Sources/App.swift', 'Config/BetaSecrets.local.xcconfig', '.git/config',
                         'docs/archive/private.md', 'evals/summary_oracle_v3.json', 'tools/WhatsAppBridge/bin/binary',
                         'Sources/private.db', 'output/private.json', 'README.md']:
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('sample')
            (root / 'Sources/link').symlink_to(root / '.git/config')
            self.assertEqual([str(p) for p in selected(root)], ['README.md', 'Sources/App.swift'])
            destination = Path(directory) / 'public'
            archive, count = export(root, destination)
            self.assertTrue(archive.exists()); self.assertEqual(count, 2)
            self.assertFalse((destination / '.git').exists())
            self.assertTrue((destination / 'SOURCE_MANIFEST.json').exists())

    def testExportFailsClosedOnSecretAndNeverOverwritesExistingOutput(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'; (root / 'Sources').mkdir(parents=True)
            (root / 'Sources/key.swift').write_text('sk-' + 'z' * 45)
            destination = Path(directory) / 'public'
            with self.assertRaises(ValueError): export(root, destination)
            self.assertFalse(destination.exists())
            destination.mkdir()
            with self.assertRaises(ValueError): export(root, destination)
