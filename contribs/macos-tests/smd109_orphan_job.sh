#!/bin/sh

set -u

fixture=${1:-}
record_dir=${2:-}
timeout=${3:-}

[ -x "$fixture" ] || exit 90
[ -d "$record_dir" ] || exit 91
case "$timeout" in
''|*[!0-9]*) exit 92 ;;
esac

exec "$fixture" "$record_dir" "$timeout"
