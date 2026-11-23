import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("community_recipes", ROOT / "Scripts/community-recipes.py")
community = importlib.util.module_from_spec(spec)
spec.loader.exec_module(community)


def row(renderer, macs, works, method="windowsSteam", arch="x86_64", vulkan="moltenvk", app=1):
    return {"steamAppID": app, "chip": "Apple M1", "ramGB": 16, "renderer": renderer, "vulkanDriver": vulkan,
            "engineArch": arch, "launchMethod": method, "reports": macs, "installs": macs, "works": works}


def recipe(status="community", renderer="dxvk", notes=None):
    return {"schema": 1, "id": "game", "title": "Game", "steamAppID": 1, "launch": "steam", "renderer": renderer,
            "sync": "msync", "advertiseAVX": False, "environment": {}, "launchArguments": [], "registry": [],
            "status": status, "notes": notes or ["Original note."], "knownIssues": []}


class CommunityRecipeTests(unittest.TestCase):
    def test_thresholds(self):
        self.assertIsNone(community.advice([row("dxmt", 2, 2)]))
        self.assertIsNone(community.advice([row("dxmt", 5, 3)]))
        self.assertEqual(community.advice([row("dxmt", 3, 3)])["renderer"], "dxmt")

    def test_never_d3dmetal_or_experimental(self):
        self.assertIsNone(community.advice([row("d3dmetal", 9, 9)]))
        self.assertIsNone(community.advice([row("dxmt", 9, 9, vulkan="kosmickrisp")]))
        self.assertIsNone(community.advice([row("dxmt", 9, 9, arch="arm64")]))

    def test_changes_renderer_status_and_note(self):
        changed, changes = community.update(recipe(status="untested"), community.advice([row("dxmt", 4, 4)]), "2026-11-23")
        self.assertEqual(changed["renderer"], "dxmt")
        self.assertEqual(changed["status"], "community")
        self.assertEqual(changed["notes"][0], "Original note.")
        self.assertEqual(changed["notes"][1], "Community reports (2026-11-23): DXMT works on 4 Macs (100% of reports).")
        self.assertEqual(len(changes), 3)

    def test_verified_and_blocked_recipes_never_change(self):
        a = community.advice([row("dxmt", 9, 9)])
        self.assertEqual(community.update(recipe(status="verified"), a, "2026-11-23"), (None, []))
        self.assertEqual(community.update(recipe(status="blocked"), a, "2026-11-23"), (None, []))

    def test_only_a_new_date_is_not_a_change(self):
        a = community.advice([row("dxvk", 4, 4)])
        note = "Community reports (2026-01-01): DXVK works on 4 Macs (100% of reports)."
        self.assertEqual(community.update(recipe(notes=["Original note.", note]), a, "2026-11-23"), (None, []))

    def test_bridge_failing_is_noted(self):
        a = community.advice([row("dxmt", 4, 0, method="bridge"), row("dxmt", 4, 4)])
        self.assertTrue(a["prefersWindowsSteam"])
        self.assertIn("Steam Bridge fails", community.note_for(a))

    def test_run_rewrites_only_changed_files_in_the_same_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "game.json").write_text(json.dumps(recipe(), indent=2) + "\n", encoding="utf-8")
            other = recipe(); other["id"] = "other"; other["steamAppID"] = 2
            other_text = json.dumps(other, indent=2) + "\n"
            (folder / "other.json").write_text(other_text, encoding="utf-8")
            summary = community.run({"verdicts": [row("dxmt", 3, 3)]}, folder, "2026-11-23")
            self.assertEqual(len(summary), 1)
            self.assertEqual(json.loads((folder / "game.json").read_text())["renderer"], "dxmt")
            self.assertEqual((folder / "other.json").read_text(), other_text)


if __name__ == "__main__":
    unittest.main()
