import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("import_recipes", ROOT / "Scripts/import-recipes.py")
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class RecipeImportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "upstream"
        self.repo.mkdir()
        self.git("init", "-q")
        self.games = self.repo / "db/games"
        self.declarations = self.repo / "recipes/games"
        self.games.mkdir(parents=True)
        self.declarations.mkdir(parents=True)
        (self.declarations / ".keep").touch()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", self.repo, *args], text=True).strip()

    def game(self, slug, app_id, **changes):
        game = {"id": slug, "title": slug.title(), "steam_appid": app_id, "status": "verified-local",
                "renderer": None, **changes}
        (self.games / (slug + ".json")).write_text(json.dumps(game))

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_license_boundary_pinned_objects_and_game_kind(self):
        self.game("allowed", 101)
        (self.declarations / "wrong.json").write_text('{"id":"wrong","kind":"launcher"}')
        for path in ("db/derived/prediction.json", "db/games/nested/ignored.json", "recipes/tweaks/tweak.json"):
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("invalid JSON; reading this would fail")
        (self.games / "linked.json").symlink_to("../derived/prediction.json")
        pin = self.commit()
        self.game("allowed", 404)
        games, declarations = importer.read_sources(self.repo, pin)
        self.assertEqual({slug: g["steam_appid"] for slug, g in games.items()}, {"allowed": 101})
        self.assertEqual(declarations, {})

    def test_rejects_mislabeled_game(self):
        (self.games / "one.json").write_text('{"id":"two"}')
        with self.assertRaisesRegex(ValueError, "id must match"):
            importer.read_sources(self.repo, self.commit())

    def test_only_portable_per_executable_display_settings_transfer(self):
        step = {"key": r"HKCU\Software\Wine\AppDefaults\game.exe\Direct3D",
                "name": "VideoMemorySize", "valueType": "REG_SZ", "data": "2047"}
        self.assertEqual(importer.display_setting(step), step)
        for change in ({"key": r"HKCU\Software\Example"}, {"name": "other"}, {"valueType": "REG_BINARY"}):
            self.assertIsNone(importer.display_setting({**step, **change}))

    def test_blocked_unlaunchable_and_opt_in_settings(self):
        game = {"id": "test", "title": "Test", "status": "community", "steam_appid": 1}
        for change in ({"steam_appid": None}, {"steam_appid": True}, {"status": "blocked-publisher"},
                       {"status": "blocked-anticheat"}, {"anticheat": {"macVerdict": "blocked"}},
                       {"renderer": "unsupported"}):
            with self.subTest(change=change):
                self.assertIsNone(importer.candidate({**game, **change}, None, "pin"))
        merged = importer.candidate(game, {"renderer": "dxvk", "optIn": True, "steps": [
            {"type": "file", "data": "ignored"}]}, "pin")
        self.assertEqual(merged["renderer"], "dxmt")
        self.assertTrue(all(step["type"] == "note" for step in merged["steps"]))

    def test_import_validation_preservation_embedding_and_rerun(self):
        root = self.root / "destination"
        recipes = root / "Data/recipes"
        recipes.mkdir(parents=True)
        scripts = root / "Scripts"
        scripts.mkdir()
        for name in ("engines", "anticheat", "optional"):
            shutil.copytree(ROOT / "Data" / name, root / "Data" / name)
        (root / "Sources/GamePortKit/Generated").mkdir(parents=True)
        (root / "Tools/kosmickrisp-shim").mkdir(parents=True)
        shutil.copy(ROOT / "Tools/kosmickrisp-shim/shim.c", root / "Tools/kosmickrisp-shim")
        shutil.copy(ROOT / "Scripts/embed-data.py", scripts)
        original = (ROOT / "Data/recipes/elden-ring.json").read_bytes()
        (recipes / "elden-ring.json").write_bytes(original)
        self.game("elden-ring", 456)
        self.game("alias", 1245620)
        self.game("fresh", 789, knownIssues=[{"symptom": "Window flickers"}])
        (self.declarations / "fresh.json").write_text(json.dumps({
            "kind": "game", "id": "fresh", "renderer": "dxvk", "steps": [
                {"type": "environment", "name": "ROSETTA_ADVERTISE_AVX", "value": "1"}]}))
        pin = self.commit()

        def run():
            with tempfile.TemporaryDirectory(dir=root) as temp:
                importer.run(self.repo, pin, root, Path(temp))

        (recipes / "invalid.json").write_text('{"schema":100}')
        with self.assertRaises(subprocess.CalledProcessError):
            run()
        self.assertFalse((recipes / "hbdb-fresh.json").exists())
        (recipes / "invalid.json").unlink()
        run()
        imported = recipes / "hbdb-fresh.json"
        bundled = root / "Sources/GamePortKit/Generated/BundledData.swift"
        first = imported.read_bytes(), bundled.read_bytes()
        self.assertIn(b"hbdb-fresh", first[1])
        row = json.loads(first[0])
        self.assertEqual((row["renderer"], row["status"], row["steamAppID"]), ("dxvk", "community", 789))
        self.assertTrue(row["advertiseAVX"])
        self.assertEqual(row["knownIssues"], [{"symptom": "Window flickers"}])
        self.assertIn(pin, row["source"])
        run()
        self.assertEqual(first, (imported.read_bytes(), bundled.read_bytes()))
        self.assertEqual((recipes / "elden-ring.json").read_bytes(), original)
        self.assertEqual(sorted(p.name for p in recipes.iterdir()), ["elden-ring.json", "hbdb-fresh.json"])


if __name__ == "__main__":
    unittest.main()
