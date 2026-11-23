#!/usr/bin/env python3
"""Update the bundled recipes from other players' anonymous reports, for a reviewed pull request.

Run: python3 Scripts/community-recipes.py [--feed URL-or-file] [--summary FILE] [--no-embed]

Reads the community results (GET /v1/verdicts.json) and, for recipes that are not verified or
blocked, changes only:
- the renderer, when another one works on enough Macs (the same rule as CommunityAdvice in
  Sources/GamePortKit/Community.swift: at least MIN_MACS different Macs, at least MIN_WORK_RATE of
  the reports work, Rosetta engines with MoltenVK only, never D3DMetal, which needs Apple's licence);
- the status, from untested to community, once a setup works on enough Macs;
- one "Community reports" note saying what the reports show.
Nothing else in a recipe ever comes from reports. A person reviews every change before it ships.
"""
import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FEED = "https://gameport-telemetry.gameportapp.workers.dev/v1/verdicts.json"
# Keep in sync with CommunityAdvice in Sources/GamePortKit/Community.swift.
MIN_MACS = 3
MIN_WORK_RATE = 0.8
MAX_FAILING_WORK_RATE = 0.2
NOTE_PREFIX = "Community reports"
RENDERER_NAMES = {"dxmt": "DXMT", "dxvk": "DXVK", "d3dmetal": "D3DMetal", "wined3d": "WineD3D"}
TUNABLE = {"community", "untested"}


def load_feed(source):
    if source.startswith("https://"):
        request = urllib.request.Request(source, headers={"User-Agent": "GamePort-recipes/1"})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    if "://" in source:
        sys.exit("the feed must be an https:// URL or a file")
    return json.loads(Path(source).read_text(encoding="utf-8"))


def tally(rows):
    macs = sum(r.get("installs") or r["reports"] for r in rows)
    reports = sum(r["reports"] for r in rows)
    works = sum(r["works"] for r in rows)
    return {"macs": macs, "reports": reports, "works": works, "rate": works / reports if reports else 0.0}


def qualifies(t):
    return t["macs"] >= MIN_MACS and t["rate"] >= MIN_WORK_RATE


def failing(t):
    return t["macs"] >= MIN_MACS and t["rate"] <= MAX_FAILING_WORK_RATE


def advice(rows):
    """What the reports for one game say: the best renderer and whether the Bridge fails."""
    usable = [r for r in rows if r.get("engineArch") == "x86_64" and r.get("vulkanDriver") == "moltenvk"]
    by_renderer = {}
    for r in usable:
        if r.get("renderer") in RENDERER_NAMES and r["renderer"] != "d3dmetal":
            by_renderer.setdefault(r["renderer"], []).append(r)
    candidates = [(renderer, tally(group)) for renderer, group in by_renderer.items()]
    candidates = [(renderer, t) for renderer, t in candidates if qualifies(t)]
    best = max(candidates, key=lambda c: (c[1]["macs"], c[1]["rate"], c[0]), default=None)
    bridge = [r for r in usable if r.get("launchMethod") == "bridge"]
    steam = [r for r in usable if (r.get("launchMethod") or "windowsSteam") == "windowsSteam"]
    prefers_steam = bool(bridge and steam and failing(tally(bridge)) and qualifies(tally(steam)))
    if best is None and not prefers_steam:
        return None
    return {"renderer": best[0] if best else None, "tally": best[1] if best else None,
            "prefersWindowsSteam": prefers_steam}


def note_for(a):
    parts = []
    if a["renderer"]:
        t = a["tally"]
        parts.append(f"{RENDERER_NAMES[a['renderer']]} works on {t['macs']} Macs ({round(t['rate'] * 100)}% of reports)")
    if a["prefersWindowsSteam"]:
        parts.append("the Steam Bridge fails for most players while Windows Steam works")
    return "; ".join(parts) + "."


def dated(text, day):
    return f"{NOTE_PREFIX} ({day}): {text}"


def undated(note):
    """The note's text without its prefix and date, to tell real changes from a new date."""
    if not note.startswith(NOTE_PREFIX):
        return None
    _, _, rest = note.partition("): ")
    return rest


def update(recipe, a, day):
    """Returns the changed recipe and a list of what changed, or (None, []) when nothing did."""
    if recipe.get("status") not in TUNABLE or a is None:
        return None, []
    changed = dict(recipe)
    changes = []
    if a["renderer"] and a["renderer"] != recipe["renderer"]:
        changed["renderer"] = a["renderer"]
        changes.append(f"renderer {recipe['renderer']} → {a['renderer']}")
    if a["renderer"] and recipe["status"] == "untested":
        changed["status"] = "community"
        changes.append("status untested → community")
    text = note_for(a)
    notes = list(recipe.get("notes", []))
    old = next((i for i, n in enumerate(notes) if undated(n) is not None), None)
    if old is None:
        notes.append(dated(text, day))
        changes.append("note added")
    elif undated(notes[old]) != text:
        notes[old] = dated(text, day)
        changes.append("note updated")
    changed["notes"] = notes
    if not changes:
        return None, []
    return changed, changes


def run(feed, recipes_dir, day):
    by_app = {}
    for row in feed.get("verdicts", []):
        if isinstance(row.get("steamAppID"), int):
            by_app.setdefault(row["steamAppID"], []).append(row)
    summary = []
    for path in sorted(recipes_dir.glob("*.json")):
        recipe = json.loads(path.read_text(encoding="utf-8"))
        rows = by_app.get(recipe.get("steamAppID"))
        if not rows:
            continue
        changed, changes = update(recipe, advice(rows), day)
        if changed is None:
            continue
        path.write_text(json.dumps(changed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        summary.append(f"- **{recipe['title']}** (`{recipe['id']}`): " + ", ".join(changes) + f". {note_for(advice(rows))}")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", default=FEED, help="https URL or local JSON file of /v1/verdicts.json")
    parser.add_argument("--recipes", default=str(ROOT / "Data/recipes"))
    parser.add_argument("--summary", help="write a Markdown list of the changes here (for the pull request)")
    parser.add_argument("--no-embed", action="store_true", help="do not re-run Scripts/embed-data.py")
    parser.add_argument("--today", default=date.today().isoformat())
    args = parser.parse_args()

    summary = run(load_feed(args.feed), Path(args.recipes), args.today)
    if args.summary:
        Path(args.summary).write_text("\n".join(summary) + ("\n" if summary else ""), encoding="utf-8")
    if summary and not args.no_embed:
        subprocess.run([sys.executable, str(ROOT / "Scripts/embed-data.py")], check=True)
    print(f"{len(summary)} recipe(s) changed")
    for line in summary:
        print(line)


if __name__ == "__main__":
    main()
