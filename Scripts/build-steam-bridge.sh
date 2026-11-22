#!/bin/bash
# Build GamePort's clean-room macOS Steamworks Bridge (steamclient64.dll + steamclient64.so + bridge_probe.exe).
# Bridges Windows Steamworks calls across Wine's unixlib boundary directly to native macOS steamclient.dylib.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/Tools/steam-bridge"
build_root="${GAMEPORT_BUILD:-$HOME/Downloads/gameport-build}"
out_dir="${GAMEPORT_HOME:-$HOME/Library/Application Support/GamePort}/tools/steam-bridge"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out_dir="$2"; shift 2 ;;
        *) echo "Usage: Scripts/build-steam-bridge.sh [--out <dir>]" >&2; exit 2 ;;
    esac
done

llvm="llvm-mingw-20261020-ucrt-macos-universal"
llvm_sha="e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e"

mingw_cc=""
if command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
    mingw_cc="$(command -v x86_64-w64-mingw32-clang)"
elif [[ -x "$build_root/$llvm/bin/x86_64-w64-mingw32-clang" ]]; then
    mingw_cc="$build_root/$llvm/bin/x86_64-w64-mingw32-clang"
else
    mkdir -p "$build_root/dl"
    archive="$build_root/dl/$llvm.tar.xz"
    if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$llvm_sha" ]]; then
        echo "Downloading pinned llvm-mingw ($llvm)..."
        tmp="$(mktemp "$build_root/dl/llvm.XXXXXXXX")"
        trap 'rm -f "$tmp"' EXIT
        curl --fail --location --retry 3 -o "$tmp" \
            "https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/$llvm.tar.xz"
        actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
        if [[ "$actual" != "$llvm_sha" ]]; then
            echo "SHA-256 mismatch for $llvm: expected $llvm_sha, got $actual" >&2
            exit 1
        fi
        mv "$tmp" "$archive"
        trap - EXIT
    fi
    echo "Extracting $llvm..."
    tar -xJf "$archive" -C "$build_root"
    mingw_cc="$build_root/$llvm/bin/x86_64-w64-mingw32-clang"
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/gp-steam-bridge.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/x86_64-unix" "$stage/x86_64-windows"

echo "Compiling macOS x86_64 Wine UnixLib (steamclient64.so)..."
/usr/bin/clang -arch x86_64 -shared -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min=13.0 \
    -I"$src" \
    "$src/unix_bridge.c" \
    -o "$stage/x86_64-unix/steamclient64.so"

echo "Compiling Windows x64 Wine Builtin DLL (steamclient64.dll)..."
"$mingw_cc" -shared -O2 -Wall -Wextra -Werror \
    -I"$src" \
    "$src/pe_bridge.c" \
    -o "$stage/x86_64-windows/steamclient64.dll"
python3 -I "$repo/Scripts/mark-wine-builtin.py" "$stage/x86_64-windows/steamclient64.dll"

echo "Compiling Windows x64 probe (bridge_probe.exe)..."
"$mingw_cc" -O2 -Wall -Wextra -Werror \
    -I"$src" \
    "$src/bridge_probe.c" \
    -o "$stage/bridge_probe.exe"

mkdir -p "$out_dir/x86_64-unix" "$out_dir/x86_64-windows"
cp "$stage/x86_64-unix/steamclient64.so" "$out_dir/x86_64-unix/steamclient64.so"
cp "$stage/x86_64-windows/steamclient64.dll" "$out_dir/x86_64-windows/steamclient64.dll"
cp "$stage/bridge_probe.exe" "$out_dir/bridge_probe.exe"

echo "Built GamePort Steam Bridge -> $out_dir"
ls -lh "$out_dir/x86_64-unix/steamclient64.so" "$out_dir/x86_64-windows/steamclient64.dll" "$out_dir/bridge_probe.exe"
