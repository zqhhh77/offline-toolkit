#!/usr/bin/env bash
set -euo pipefail
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "$base" in
    *:*|*';'*) echo '部署目录不能包含冒号或分号' >&2; exit 1 ;;
esac
export LD_LIBRARY_PATH="$base/lib"
exec "$base/sbin/nginx" -p "$base/" "$@"
