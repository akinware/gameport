#!/bin/bash
# Renderer lab: runs the Unigine Heaven demo once per graphics path in the lab-heaven profile
# and saves Wine's log (DLL loads included), the Metal HUD's FPS log, thermal samples and screenshots
# for each, then summarises them into results.json (Scripts/lab-parse.py).
# Needs: gameport built (swift build), profile lab-heaven, Heaven installed at C:\Heaven in it.
# Usage: Scripts/lab-heaven.sh [seconds per run, default 300] [only these runs, e.g. d3d11-dxvk,d3d9-d9vk]
set -uo pipefail
cd "$(dirname "$0")/.."

GAMEPORT=".build/debug/gameport"
ID="lab-heaven"
HOME_DIR="${GAMEPORT_HOME:-$HOME/Library/Application Support/GamePort}"
PROFILE="$HOME_DIR/profiles/$ID/profile.json"
HEAVEN="$HOME_DIR/profiles/$ID/prefix/drive_c/Heaven"
LIMIT="${1:-300}"
ONLY="${2:-}"
SHOTS=(60 150 240)
OUT="$HOME_DIR/lab/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

[ -x "$GAMEPORT" ] || { echo "error: run swift build first"; exit 1; }
[ -f "$PROFILE" ] || { echo "error: profile $ID does not exist"; exit 1; }
[ -f "$HEAVEN/bin/Heaven.exe" ] || { echo "error: Heaven is not installed"; exit 1; }
cp "$PROFILE" "$OUT/profile.original.json"
# Put the profile back and stop Wine however the script ends (Ctrl-C, closed window, error).
trap 'cp "$OUT/profile.original.json" "$PROFILE"; "$GAMEPORT" stop "$ID" >/dev/null 2>&1; kill $(jobs -p) 2>/dev/null' EXIT

# Other GamePort profiles (e.g. a Steam left open) eat CPU and skew the numbers.
for p in "$HOME_DIR"/profiles/*/; do
    other=$(basename "$p")
    [ "$other" = "$ID" ] && continue
    "$GAMEPORT" stop "$other" >/dev/null 2>&1 && echo "• stopped $other (so it does not skew the measurement)"
done

# To prevent a blank fullscreen OpenGL display, run `gameport config lab-heaven opengl` before the benchmark.

# Sets the profile's renderer override, msync, the Metal HUD (on screen and logged) and DLL-load logging.
set_renderer() {
    python3 -I - "$PROFILE" "$1" <<'PY'
import json, sys
path, renderer = sys.argv[1], sys.argv[2]
p = json.load(open(path))
p["renderer"] = renderer
p["sync"] = "msync"
p["metalHUD"] = True
p["environment"] = {"WINEDEBUG": "fixme-all,+loaddll", "MTL_HUD_LOG_ENABLED": "1"}
json.dump(p, open(path, "w"), indent=2, sort_keys=True)
PY
}

# Heaven picks tessellation from an extern define; none means off. D3D9 has no tessellation at all,
# so d3d11-dxmt vs d3d9-d9vk compares equal workloads and d3d11-dxmt-tess shows what tessellation costs.
# The DXVK D3D11 crash (MoltenVK lacks pipeline-statistics queries) happens with Heaven's GPU monitor
# on or off, so the run stays in as a regression check for a patched DXVK.
# name             gameport-renderer  heaven-video_app  tessellation
CASES=(
    "d3d11-dxmt       dxmt     direct3d11  -"
    "d3d11-dxmt-tess  dxmt     direct3d11  TESSELLATION_NORMAL"
    "d3d11-dxvk       dxvk     direct3d11  -"
    "d3d9-d9vk        dxmt     direct3d9   -"
    "opengl           wined3d  opengl      -"
)

for c in "${CASES[@]}"; do
    read -r name renderer api tess <<<"$c"
    [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]] && continue
    defines="PHORONIX,RELEASE"; [ "$tess" != "-" ] && defines="$defines,$tess"
    echo "▶ $name ($renderer, $api, ${tess/-/tessellation off}) — at most $LIMIT s"
    set_renderer "$renderer"
    "$GAMEPORT" stop "$ID" >/dev/null 2>&1
    "$GAMEPORT" env "$ID" | grep -E '^(WINEDLL|WINEDEBUG|MTL_|WINEMSYNC|WINEESYNC)' >"$OUT/$name.env"
    # The Metal HUD logs once a second to the unified log, never to Wine's stdout.
    /usr/bin/log stream --style compact --predicate 'subsystem == "com.apple.metal.hud"' \
        >"$OUT/$name.syslog" 2>&1 &
    logger_pid=$!
    # A fanless Air throttles under sustained load; keep evidence of it next to the FPS.
    (while true; do date +%T; pmset -g therm; sleep 30; done) >"$OUT/$name.thermal" 2>&1 &
    thermal_pid=$!
    start=$(date +%s)
    "$GAMEPORT" run "$ID" start /wait /d 'C:\Heaven\bin' Heaven.exe \
        -video_app "$api" -data_path ../ -sound_app null \
        -engine_config ../data/heaven_4.0.cfg -system_script heaven/unigine.cpp \
        -video_mode -1 -video_fullscreen 0 -video_width 1280 -video_height 720 \
        -video_multisample 0 -extern_define "$defines" >"$OUT/$name.log" 2>&1 &
    pid=$!
    shot=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        elapsed=$(( $(date +%s) - start ))
        if [ "$shot" -lt "${#SHOTS[@]}" ] && [ "$elapsed" -ge "${SHOTS[$shot]}" ]; then
            screencapture -x "$OUT/$name-${SHOTS[$shot]}s.png" 2>/dev/null; shot=$((shot + 1))
        fi
        if [ "$elapsed" -ge "$LIMIT" ]; then
            echo "  time is up, stopping"; echo "GAMEPORT_LAB: timeout" >>"$OUT/$name.log"
            "$GAMEPORT" stop "$ID" >/dev/null 2>&1
            sleep 10; kill -9 "$pid" 2>/dev/null; break
        fi
    done
    wait "$pid" 2>/dev/null; status=$?
    kill "$logger_pid" "$thermal_pid" 2>/dev/null
    elapsed=$(( $(date +%s) - start ))
    echo "GAMEPORT_LAB: exit=$status seconds=$elapsed" >>"$OUT/$name.log"
    if [ "$elapsed" -lt 60 ]; then echo "  ✗ closed after $elapsed s (crash?)"; else echo "  ✓ ran for $elapsed s, ${shot} screenshots"; fi
done

find "$HOME_DIR/profiles/$ID" -newer "$OUT/profile.original.json" -iname '*log*.htm*' -exec cp {} "$OUT/" \; 2>/dev/null
python3 -I Scripts/lab-parse.py "$OUT"
echo "Done: $OUT"
