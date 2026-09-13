#!/bin/sh

set -eu

case_name=$1
probe=$2

/usr/bin/printf 'case=%s\n' "$case_name"
exec "$probe" job
