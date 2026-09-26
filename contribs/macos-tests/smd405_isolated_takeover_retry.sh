#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
driver=${script_dir}/smd405_isolated_takeover_driver.sh
run_log=/private/tmp/smd405-retry-$(date '+%Y%m%dT%H%M%S').log

SMD405_ISOLATED_TAKEOVER_CONFIRMED=YES \
	/bin/sh "$driver" >"$run_log" 2>&1
run_rc=$?

run_dir=$(sed -n 's/.*run_dir=\([^ ]*\).*/\1/p' "$run_log" | tail -n 1)
printf 'run_rc=%s\nrun_log=%s\nrun_dir=%s\n' \
	"$run_rc" "$run_log" "$run_dir"
cat "$run_log"

if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
	if [ "$run_rc" -eq 0 ]; then
		for artifact in \
			"${run_dir}/result.env" \
			"${run_dir}/primary-result.env" \
			"${run_dir}/backup-result.env"; do
			[ -f "$artifact" ] || continue
			printf '\n=== %s ===\n' "${artifact##*/}"
			tail -n 30 "$artifact"
		done
	else
		for artifact in "${run_dir}"/*.env "${run_dir}"/*.txt; do
			[ -f "$artifact" ] || continue
			printf '\n=== %s ===\n' "${artifact##*/}"
			tail -n 30 "$artifact"
		done
	fi
fi

exit "$run_rc"
