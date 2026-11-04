import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from update_alt_store import BUNDLE_ID, update_json_file_release


class AltStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "alt_store.json"
        self.path.write_text(json.dumps({
            "apps": [{"bundleIdentifier": "com.github.wgh136.venera", "versions": [{"version": "1.6.3"}]}],
            "news": [{"identifier": "upstream-news"}],
        }))
        self.release = {
            "tag_name": "v2.6.1", "published_at": "2026-10-16T01:02:03Z",
            "body": "# Update\n**Import** fix", "draft": False, "prerelease": False,
            "assets": [{"name": "venera-prime-ios-2.6.1+261.ipa", "size": 12345,
                        "browser_download_url": "https://example.test/prime.ipa"}],
        }

    def test_prime_bundle_migration_and_idempotency(self):
        self.assertTrue(update_json_file_release(self.path, self.release))
        data = json.loads(self.path.read_text())
        app = data["apps"][0]
        self.assertEqual(app["bundleIdentifier"], BUNDLE_ID)
        self.assertEqual([entry["version"] for entry in app["versions"]], ["2.6.1"])
        self.assertEqual(app["versions"][0]["buildVersion"], "261")
        self.assertEqual(app["size"], 12345)
        self.assertEqual(data["news"][0]["appID"], BUNDLE_ID)
        self.assertFalse(update_json_file_release(self.path, self.release))

    def test_drafts_prereleases_and_incomplete_release_do_not_damage_feed(self):
        original = self.path.read_bytes()
        for flag in ["draft", "prerelease"]:
            release = dict(self.release, **{flag: True})
            self.assertFalse(update_json_file_release(self.path, release))
            self.assertEqual(self.path.read_bytes(), original)
        for assets in [[], self.release["assets"] * 2, [{**self.release["assets"][0], "size": 0}]]:
            with self.assertRaises(ValueError):
                update_json_file_release(self.path, dict(self.release, assets=assets))
            self.assertEqual(self.path.read_bytes(), original)

    def test_actual_build_number_and_version_order(self):
        newer = copy.deepcopy(self.release)
        newer["tag_name"] = "v2.10.0"
        newer["assets"][0]["name"] = "venera-prime-ios-2.10.0+900.ipa"
        update_json_file_release(self.path, newer)
        update_json_file_release(self.path, self.release)
        app = json.loads(self.path.read_text())["apps"][0]
        self.assertEqual(app["version"], "2.10.0")
        self.assertEqual(app["versions"][0]["buildVersion"], "900")
        self.assertEqual([entry["version"] for entry in app["versions"]], ["2.10.0", "2.6.1"])


if __name__ == "__main__":
    unittest.main()
