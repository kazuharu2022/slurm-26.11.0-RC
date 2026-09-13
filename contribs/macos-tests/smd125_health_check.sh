#!/bin/sh

set -u

hook_dir=${0%/*}
run_dir=${hook_dir%/*}
mode=$(/bin/cat "${run_dir}/mode")
event_log=${run_dir}/health-events.log
scontrol=/opt/slurm/26.11.0/bin/scontrol
slurm_conf=/opt/slurm/26.11.0/etc/slurm.conf
node_name=${SLURMD_NODENAME:-}
node_health=${SLURM_NODE_IS_HEALTHY-unset}
pid=$$
pgid=$(/bin/ps -o pgid= -p "$pid" | /usr/bin/tr -d ' ')

[ "$node_name" = PC-210 ] || exit 65
case "$mode" in
success|nonzero|timeout) ;;
*) exit 65 ;;
esac
case "$pgid" in
''|*[!0-9]*) exit 65 ;;
esac

/usr/bin/printf 'event=health_begin mode=%s node=%s node_health=%s epoch=%s euid=%s egid=%s pid=%s pgid=%s\n' \
	"$mode" "$node_name" "$node_health" "$(/bin/date '+%s')" \
	"$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$pid" "$pgid" >>"$event_log"

if [ "$mode" = success ]; then
	/usr/bin/printf 'event=health_success mode=%s node=%s epoch=%s exit_code=0\n' \
		"$mode" "$node_name" "$(/bin/date '+%s')" >>"$event_log"
	exit 0
fi

reason=SMD125_health_${mode}
SLURM_CONF="$slurm_conf" "$scontrol" update \
	NodeName="$node_name" State=DRAIN Reason="$reason" \
	>"${run_dir}/health-${mode}-drain.out" \
	2>"${run_dir}/health-${mode}-drain.err"
drain_rc=$?
/usr/bin/printf 'event=health_drain mode=%s node=%s epoch=%s scontrol_rc=%s reason=%s\n' \
	"$mode" "$node_name" "$(/bin/date '+%s')" "$drain_rc" "$reason" >>"$event_log"
[ "$drain_rc" -eq 0 ] || exit 66

if [ "$mode" = nonzero ]; then
	/usr/bin/printf 'event=health_nonzero mode=%s node=%s epoch=%s exit_code=42\n' \
		"$mode" "$node_name" "$(/bin/date '+%s')" >>"$event_log"
	exit 42
fi

/usr/bin/printf 'event=health_timeout_begin mode=%s node=%s epoch=%s pid=%s pgid=%s\n' \
	"$mode" "$node_name" "$(/bin/date '+%s')" "$pid" "$pgid" >>"$event_log"
while :; do
	/bin/sleep 1
done
