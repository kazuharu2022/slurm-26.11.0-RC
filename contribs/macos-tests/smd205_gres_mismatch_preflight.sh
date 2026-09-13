#!/bin/sh

set -u

if [ "${SMD205_GRES_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD205_GRES_PREFLIGHT_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd205-preflight-${run_stamp}
candidate_dir=${run_dir}/candidate

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	/usr/bin/awk -v key="${field}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this preflight is for the macOS worker'

for required_file in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" \
	"$squeue" "$pid_file" "$plist"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/grep /usr/bin/id \
	/usr/bin/shasum /usr/bin/uname /bin/cat /bin/cp /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0755 "$candidate_dir" || fail 'cannot create candidate directory'
/usr/bin/printf 'run_dir=%s mode=READ_ONLY_PRODUCTION\n' "$run_dir"

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || \
	fail 'controller node record lacks gpu:apple:1'

pid=$(/bin/cat "$pid_file")
case "$pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$pid" ;;
esac
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail "slurmd pid=$pid is not running"
/bin/launchctl print "$service_target" >"${run_dir}/launchd.txt" 2>&1 || \
	fail "launchd service is not loaded: $service_target"
launchd_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' "${run_dir}/launchd.txt")
[ "$launchd_pid" = "$pid" ] || \
	fail "launchd and pidfile identity mismatch launchd=$launchd_pid pidfile=$pid"
/bin/ps -p "$pid" -o pid=,ppid=,lstart=,state=,command= >"${run_dir}/slurmd-before.txt" || \
	fail 'cannot inspect slurmd process'

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	>"${run_dir}/production-before.sha256"
/bin/cp -p "$slurm_conf" "${run_dir}/slurm.conf.production-copy" || \
	fail 'cannot copy slurm.conf evidence'
/bin/cp -p "$gres_conf" "${run_dir}/gres.conf.production-copy" || \
	fail 'cannot copy gres.conf evidence'

SLURM_CONF="$slurm_conf" "$slurmd" -G -f "$slurm_conf" \
	>"${run_dir}/production-gres.stdout" \
	2>"${run_dir}/production-gres.stderr" || fail 'production slurmd -G failed'
/usr/bin/grep -Eq \
	'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
	"${run_dir}/production-gres.stderr" || \
	fail 'production slurmd -G does not report gpu:apple count 1'

/bin/cp -p "$slurm_conf" "${candidate_dir}/slurm.conf" || \
	fail 'cannot create candidate slurm.conf'
/usr/bin/printf '%s\n' \
	'# SMD-205 preflight: intentionally no GPU device record' \
	>"${candidate_dir}/gres.conf" || fail 'cannot create candidate gres.conf'

SLURM_CONF="${candidate_dir}/slurm.conf" \
	SLURM_SACK_KEY="$slurm_key" \
	"$slurmd" -G -f "${candidate_dir}/slurm.conf" \
	>"${run_dir}/candidate-gres.stdout" \
	2>"${run_dir}/candidate-gres.stderr" || fail 'candidate slurmd -G failed'
if /usr/bin/grep -Eq \
	'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
	"${run_dir}/candidate-gres.stderr"; then
	fail 'candidate unexpectedly still reports gpu:apple count 1'
fi
/usr/bin/grep -Fq 'Ignoring file-less GPU gpu:apple' \
	"${run_dir}/candidate-gres.stderr" || \
	fail 'candidate did not expose the expected missing-device condition'

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	>"${run_dir}/production-after.sha256"
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production file hash changed during preflight'
"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || \
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs after preflight'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed during preflight'

/usr/bin/printf '%s\n' \
	"production_gres=PASS gpu:apple:1 File=/dev/null" \
	"candidate_missing_device=PASS expected_reported_count=0 configured_count=1" \
	"production_unchanged=PASS slurmd_pid=$pid node_state=IDLE" \
	"SMD205_PREFLIGHT_COMPLETE run_dir=$run_dir"
