#!/usr/bin/env python3
"""Import Steam games from the CC0 portion of highball-db and re-embed the catalog.

Run python3 Scripts/import-recipes.py [local-highball-db-git-repository].
Both modes read the same pinned Git objects, never local working-tree changes.
"""
import argparse
import fcntl
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

COMMIT = "44de5600ef86d7e98d5a4b6f7c5e5cc8f36e23b7"
UPSTREAM = "https://github.com/gauthierpiarrette/highball-db"
ROOT = Path(__file__).resolve().parents[1]
PATHS = ("db/games", "recipes/games")
RENDERERS = {"dxmt", "dxvk", "d3dmetal", "wined3d"}


def display_setting(step):
    key = step["key"].replace("\\\\", "\\")
    parts = key.split("\\")
    if len(parts) != 6 or parts[:4] != ["HKCU", "Software", "Wine", "AppDefaults"]:
        return None
    if not re.fullmatch(r"[\w .-]+\.exe", parts[4], flags=re.IGNORECASE):
        return None
    if (parts[5], step["name"], step.get("valueType")) in {
        ("Direct3D", "VideoMemorySize", "REG_SZ"), ("X11 Driver", "EmulateModeset", "REG_SZ")
    }:
        return {**step, "key": key}
    return None


def fetch(repo):
    subprocess.run(["git", "init", "--quiet", repo], check=True)
    git = ["git", "-C", repo]
    subprocess.run([*git, "remote", "add", "origin", UPSTREAM + ".git"], check=True)
    subprocess.run([*git, "fetch", "--quiet", "--depth=1", "--filter=blob:none", "origin", COMMIT], check=True)
    # Materialize the two CC0 directories in a single batch on partial-clone servers.
    subprocess.run([*git, "sparse-checkout", "set", "--no-cone",
                    *["/" + directory + "/*.json" for directory in PATHS]], check=True)
    subprocess.run([*git, "checkout", "--quiet", "--detach", COMMIT], check=True)


def read_sources(repo, commit):
    archive = subprocess.check_output(["git", "-C", repo, "archive", commit, "--", *PATHS])
    games, recipes = {}, {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar:
            match = re.fullmatch(r"(db/games|recipes/games)/([a-zA-Z0-9._-]+)\.json", member.name)
            if not match or not member.isfile():
                continue
            directory, slug = match.groups()
            item = json.load(tar.extractfile(member))
            if item.get("id") != slug or slug in {".", ".."}:
                raise ValueError(f"{member.name}: id must match filename")
            if directory == "db/games":
                games[slug] = item
            elif item.get("kind") == "game":
                recipes[slug] = item
    if not games:
        raise ValueError("no curated game records in pinned source")
    return games, recipes


def candidate(game, recipe, commit):
    # The launcher needs a Steam app ID. A blocked title must never become a community recipe.
    if game["status"] not in {"community", "reported-upstream", "verified-local"}:
        return None
    app_id = game.get("steam_appid")
    if type(app_id) is not int or app_id <= 0 or (game.get("anticheat") or {}).get("macVerdict") == "blocked":
        return None

    slug = game["id"]
    base = f"{UPSTREAM}/blob/{commit}"
    source = f"{base}/db/games/{slug}.json"
    renderer = game.get("renderer")
    steps = []
    notes = []
    if recipe:
        source += f" + {base}/recipes/games/{slug}.json"
        # Highball-specific file/engine tweaks and optional setup are not portable. Only
        # carry portable Wine settings from required steps; link the original for context.
        if recipe.get("optIn"):
            notes.append("The upstream recipe has optional settings; see its source for details.")
        else:
            renderer = recipe.get("renderer") or renderer
            for step in recipe["steps"]:
                kind = step["type"]
                if kind == "renderer" and step["renderer"] in RENDERERS or kind == "sync":
                    steps.append(step)
                elif kind == "environment" and step["name"] == "ROSETTA_ADVERTISE_AVX":
                    steps.append(step)
                elif kind == "registry":
                    setting = display_setting(step)
                    if setting:
                        steps.append(setting)
            if any(step["type"] not in {"renderer", "sync", "note"} for step in recipe["steps"]):
                notes.append("See the upstream recipe for its full Highball setup.")
        extra = [name for name in recipe.get("requires", []) if name != "steam"]
        if extra:
            notes.append("Upstream prerequisites: " + ", ".join(extra) + ".")
    if renderer is None:
        renderer = "dxmt"
        notes.append("The upstream record does not specify a renderer. DXMT is the starting default.")
    elif renderer not in RENDERERS:
        return None
    # Keep reported symptoms. Highball's proposed fixes can depend on its engine,
    # launcher helpers, or anti-cheat policy; the pinned source retains that context.
    issues = [] if game.get("anticheat") else [
        {"symptom": issue["symptom"]} for issue in game.get("knownIssues") or []
    ]
    return {"id": slug, "title": game["title"], "steamAppID": app_id, "renderer": renderer, "knownIssues": issues,
            "steps": steps + [{"type": "note", "text": note} for note in notes], "source": source + " (CC0-1.0)"}


def run(repo, commit, root, staging):
    games, recipes = read_sources(repo, commit)
    entries = [candidate(games[slug], recipes.get(slug), commit) for slug in sorted(games)]
    batch = staging / "batch.json"
    batch.write_text(json.dumps([entry for entry in entries if entry]), encoding="utf-8")
    output = staging / "new"
    output.mkdir()
    destination = root / "Data/recipes"
    # Serialize imports and use exclusive links so existing files cannot be replaced.
    directory_fd = os.open(destination, os.O_RDONLY)
    try:
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
        subprocess.run(["swift", "run", "--package-path", ROOT, "import-recipes", destination, batch, output], check=True)
        added = []
        try:
            for path in sorted(output.glob("*.json")):
                target = destination / path.name
                # Follow the same human-readable JSON layout as the maintained recipes.
                recipe = json.loads(path.read_bytes())
                path.write_text(json.dumps(recipe, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                os.link(path, target)
                added.append(target)
            subprocess.run([sys.executable, root / "Scripts/embed-data.py"], check=True)
        except BaseException:
            for path in added:
                path.unlink()
            raise
    finally:
        os.close(directory_fd)
    print(f"Added {len(added)} community recipes; preserved existing recipes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path, nargs="?")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(dir=ROOT / "Data") as temporary:
        staging = Path(temporary)
        repo = args.repository
        if repo is None:
            repo = staging / "upstream"
            fetch(repo)
        run(repo, COMMIT, ROOT, staging)


if __name__ == "__main__":
    main()
