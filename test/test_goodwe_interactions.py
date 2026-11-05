"""Evidence-index checks: retain unknown packets and avoid false reply matches."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("goodwe_interactions", ROOT / "tools/goodwe_interactions.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GoodWeInteractionsTest(unittest.TestCase):
    def index(self, rows, actions=()):
        with tempfile.TemporaryDirectory() as directory:
            wire, ui = Path(directory) / "wire.jsonl", Path(directory) / "actions.jsonl"
            wire.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            ui.write_text("\n".join(json.dumps(row) for row in actions), encoding="utf-8")
            return module.report(wire, ui)

    def test_real_module_version_and_unknown_request(self):
        request, response = "5a5a0101000004d0", "5a5a0181000956312e312e332e3134a199"
        rows = [dict(time_ns=i, direction=direction, peer=["192.0.2.5", 8899], data=data)
                for i, (direction, data) in enumerate((("app", request), ("upstream-tx", request),
                                                       ("upstream-rx", response), ("app", "deadbeef"),
                                                       ("withheld", "deadbeef")), 1)]
        result = self.index(rows, [dict(time_ns=0, action="tap", label="WLAN/LAN")])
        self.assertEqual(result["event_count"], 5)
        self.assertEqual(result["unique_requests"], 2)
        first, unknown = result["interactions"]
        self.assertTrue(first["response_candidates"][response]["classification"]["valid"])
        self.assertEqual(first["action_labels"], ["WLAN/LAN"])
        self.assertEqual(unknown["classification"]["protocol"], "unclassified")
        self.assertEqual(unknown["withheld"], 1)
        self.assertEqual(result["events"][3]["data"], "deadbeef")

    def test_overlapping_requests_are_not_paired(self):
        request = "f703750600016a91"
        rows = [dict(time_ns=i, direction=direction, peer=["192.0.2.5", 8899], data=data)
                for i, (direction, data) in enumerate((("app", request), ("upstream-tx", request),
                                                       ("app", request), ("upstream-tx", request),
                                                       ("upstream-rx", "aa55f703020001b191")), 1)]
        result = self.index(rows)
        self.assertEqual(result["interactions"][0]["response_candidates"], {})
        self.assertEqual(result["unmatched_responses"][0]["pending_count"], 2)


if __name__ == "__main__":
    unittest.main()
