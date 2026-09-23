#!/bin/bash
# 仓库根目录只做转发。macOS 在 mac/，Windows 在 win/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
    win|windows)
        shift
        exec cargo build --manifest-path "$ROOT/win/Cargo.toml" "$@"
        ;;
    mac|macos)
        shift
        exec "$ROOT/mac/build.sh" "$@"
        ;;
    *)
        exec "$ROOT/mac/build.sh" "$@"
        ;;
esac
