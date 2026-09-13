#!/bin/sh

set -u

mode=${1:-}
prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
hook_name=smd404_configless_prolog.sh
hook_path=${prefix}/etc/${hook_name}
state_file=${prefix}/.smd404-configless-runtime.env
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
slurmd=${prefix}/sbin/slurmd
node_name=ubuntu
peer_node=PC-210
partition=pepilog
test_user=testuser
test_uid=3001
test_gid=3001
approved_conf_hash=56ab879e4ae3a845950e15d2665f33543c5108ecae9b2008ef886b600eff169f
approved_gres_hash=08d31ac718b61395b0a452bb6700c1143352357cf505b3791c0285f55f43f1d0
approved_slurmd_hash=2c445fdf614b0554aa76f7b0df272ec6c0ea8af456736b3fa66a28a41847ed14
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd404-controller-${mode}-${run_stamp}
success=0
config_installed=0
hook_installed=0
smoke_job=

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	awk -v key="${field}=" '
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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_nodes_idle()
{
	label=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/${label}-ubuntu.txt" 2>/dev/null || true
		"$scontrol" show node "$peer_node" >"${run_dir}/${label}-mac.txt" 2>/dev/null || true
		ubuntu_state=$(node_field State "${run_dir}/${label}-ubuntu.txt")
		mac_state=$(node_field State "${run_dir}/${label}-mac.txt")
		if [ "$ubuntu_state" = IDLE ] && [ "$mac_state" = IDLE ] &&
			[ -z "$("$squeue" -h -w "$node_name,$peer_node")" ]; then
			printf 'nodes_idle phase=%s wait_seconds=%s\n' "$label" "$attempt"
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		$5 == "ubuntu" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
			step_ok = 1
		}
		END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		accounting_complete "$job_id" "$file" && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cancel_if_active()
{
	[ -n "$smoke_job" ] || return 0
	state=$(queue_state "$smoke_job")
	[ -z "$state" ] || "$scancel" "$smoke_job" >/dev/null 2>&1 || true
}

write_hook()
{
	version=$1
	target=$2
	cat >"$target" <<EOF
#!/bin/sh
SMD404_HOOK_VERSION=${version}
if [ "\$(uname -s)" = Darwin ]; then
	printf 'version=%s job_id=%s node=PC-210 uid=%s gid=%s context=%s\\n' \\
		"\$SMD404_HOOK_VERSION" "\${SLURM_JOB_ID:-unknown}" \\
		"\$(id -u)" "\$(id -g)" "\${SLURM_SCRIPT_CONTEXT:-unknown}" \\
		>>/tmp/smd404-configless-hook-events.log
fi
exit 0
EOF
	chmod 0755 "$target"
}

atomic_install_conf()
{
	source=$1
	target=$2
	reference=$3
	tmp=${target}.smd404.$$
	uid=$(stat -c '%u' "$reference") || return 1
	gid=$(stat -c '%g' "$reference") || return 1
	file_mode=$(stat -c '%a' "$reference") || return 1
	install -o "$uid" -g "$gid" -m "$file_mode" "$source" "$tmp" || return 1
	mv -f "$tmp" "$target" || return 1
}

atomic_install_hook()
{
	source=$1
	tmp=${hook_path}.smd404.$$
	install -o root -g root -m 0755 "$source" "$tmp" || return 1
	mv -f "$tmp" "$hook_path" || return 1
}

write_state()
{
	phase=$1
	tmp=${state_file}.tmp.$$
	{
		printf 'controller_run_dir=%s\n' "$controller_run_dir"
		printf 'backup_conf=%s\n' "$backup_conf"
		printf 'before_hash=%s\n' "$before_hash"
		printf 'phase=%s\n' "$phase"
	} >"$tmp" || return 1
	chmod 0600 "$tmp" || return 1
	mv -f "$tmp" "$state_file" || return 1
}

load_state()
{
	[ -f "$state_file" ] || fail "missing active state file=$state_file"
	[ "$(stat -c '%U:%G:%a' "$state_file")" = root:root:600 ] ||
		fail 'state file owner or mode mismatch'
	# The file is created by this script as root with shell-safe values.
	. "$state_file"
	[ -n "${controller_run_dir:-}" ] || fail 'state lacks controller_run_dir'
	run_dir=$controller_run_dir
	[ -n "${backup_conf:-}" ] || fail 'state lacks backup_conf'
	[ -f "$backup_conf" ] || fail "missing backup=$backup_conf"
}

run_ubuntu_smoke()
{
	label=$1
	output_dir=${run_dir}/job-output
	mkdir -p "$output_dir" || return 1
	chown "${test_uid}:${test_gid}" "$output_dir" || return 1
	chmod 0700 "$output_dir" || return 1
	out=${output_dir}/${label}.out
	err=${output_dir}/${label}.err
	payload=${run_dir}/${label}.sh
	cat >"$payload" <<'EOF'
#!/bin/sh
printf 'node=%s arch=%s uid=%s gid=%s\n' \
	"$(hostname -s)" "$(uname -m)" "$(id -u)" "$(id -g)"
EOF
	chmod 0755 "$payload" || return 1
	smoke_job=$(sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--nodes=1 --ntasks=1 --time=00:01:00 --chdir=/tmp \
		--output="$out" --error="$err" "$payload") ||
		return 1
	smoke_job=$(printf '%s\n' "$smoke_job" | sed 's/;.*//')
	case "$smoke_job" in
	''|*[!0-9]*) return 1 ;;
	esac
	wait_job_gone "$smoke_job" || return 1
	wait_accounting "$smoke_job" "${run_dir}/${label}-accounting.txt" || return 1
	grep -Eq '^node=ubuntu2504 arch=x86_64 uid=3001 gid=3001$' "$out" || return 1
	printf 'ubuntu_smoke=PASS phase=%s job_id=%s\n' "$label" "$smoke_job"
	return 0
}

rollback_apply()
{
	printf 'rollback_begin run_dir=%s\n' "$run_dir" >&2
	cancel_if_active
	if [ "$config_installed" -eq 1 ] && [ -f "${run_dir}/slurm.conf.before" ]; then
		atomic_install_conf "${run_dir}/slurm.conf.before" "$slurm_conf" \
			"${run_dir}/slurm.conf.before" || true
	fi
	if [ "$hook_installed" -eq 1 ]; then
		rm -f "$hook_path"
	fi
	"$scontrol" reconfigure >/dev/null 2>&1 || true
	rm -f "$state_file"
	printf 'rollback_end\n' >&2
}

cleanup_apply()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		rollback_apply
		printf 'recovery: controller original config restore attempted; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$mode" = apply ] || [ "$mode" = update ] || [ "$mode" = restore ] || {
	printf 'usage: %s apply|update|restore\n' "$0" >&2
	exit 64
}
if [ "${SMD404_CONFIGLESS_CHANGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD404_CONFIGLESS_CHANGE_CONFIRMED=YES after approving SMD-404 runtime changes' >&2
	exit 64
fi
[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this control script is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"

for required in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$slurmd"; do
	[ -e "$required" ] || fail "missing $required"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done
[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
export SLURM_CONF="$slurm_conf"
printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"

case "$mode" in
apply)
	[ ! -e "$state_file" ] || fail "active SMD-404 state already exists=$state_file"
	[ ! -e "$hook_path" ] || fail "refusing to replace existing hook=$hook_path"
	[ "$(sha256sum "$slurm_conf" | awk '{ print $1 }')" = "$approved_conf_hash" ] ||
		fail 'slurm.conf changed after approved preflight'
	[ "$(sha256sum "${prefix}/etc/gres.conf" | awk '{ print $1 }')" = "$approved_gres_hash" ] ||
		fail 'gres.conf changed after approved preflight'
	[ "$(sha256sum "$slurmd" | awk '{ print $1 }')" = "$approved_slurmd_hash" ] ||
		fail 'Ubuntu slurmd changed after approved preflight'
	for setting in \
		'ProctrackType=proctrack/cgroup' \
		'TaskPlugin=task/affinity' \
		'JobAcctGatherType=jobacct_gather/cgroup'; do
		[ "$(grep -Fxc "$setting" "$slurm_conf")" -eq 1 ] ||
			fail "production setting mismatch=$setting"
	done
	[ "$(grep -Ec '^[[:space:]]*(Prolog|Epilog|TaskProlog|TaskEpilog)=' "$slurm_conf")" -eq 0 ] ||
		fail 'production config already has an active hook setting'
	wait_nodes_idle before || fail 'target nodes are not idle and unallocated'
	cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
	backup_conf=${run_dir}/slurm.conf.before
	before_hash=$(sha256sum "$slurm_conf" | awk '{ print $1 }')
	awk '
		/^[[:space:]]*ProctrackType=/ { next }
		/^[[:space:]]*TaskPlugin=/ { next }
		/^[[:space:]]*JobAcctGatherType=/ { next }
		{ print }
		END { print "Prolog=smd404_configless_prolog.sh" }
	' "$slurm_conf" >"${run_dir}/slurm.conf.portable" || fail 'cannot build portable config'
	write_hook 1 "${run_dir}/${hook_name}" || fail 'cannot build hook v1'
	"$slurmd" -C -N "$node_name" -f "${run_dir}/slurm.conf.portable" \
		>"${run_dir}/candidate-C.out" 2>"${run_dir}/candidate-C.err" ||
		fail 'portable config parse failed'
	trap cleanup_apply EXIT HUP INT TERM
	atomic_install_hook "${run_dir}/${hook_name}" ||
		fail 'cannot install hook v1'
	hook_installed=1
	atomic_install_conf "${run_dir}/slurm.conf.portable" "$slurm_conf" \
		"${run_dir}/slurm.conf.before" || fail 'cannot install portable config'
	config_installed=1
	controller_run_dir=$run_dir
	write_state APPLIED_V1 || fail 'cannot write state file'
	"$scontrol" reconfigure >"${run_dir}/reconfigure.out" \
		2>"${run_dir}/reconfigure.err" || fail 'controller reconfigure failed'
	wait_nodes_idle applied || fail 'nodes did not return IDLE after portable apply'
	"$scontrol" show config >"${run_dir}/controller-config-applied.txt" ||
		fail 'cannot read applied controller config'
	grep -Eq '^ProctrackType[[:space:]]*=[[:space:]]*proctrack/cgroup$' \
		"${run_dir}/controller-config-applied.txt" || fail 'Linux default proctrack is not cgroup'
	! grep -Eq '^TaskPlugin[[:space:]]*=[[:space:]]*task/affinity$' \
		"${run_dir}/controller-config-applied.txt" || fail 'task/affinity remained active'
	! grep -Eq '^JobAcctGatherType[[:space:]]*=[[:space:]]*jobacct_gather/cgroup$' \
		"${run_dir}/controller-config-applied.txt" || fail 'jobacct_gather/cgroup remained active'
	run_ubuntu_smoke portable-v1 || fail 'Ubuntu portable-profile smoke failed'
	success=1
	trap - EXIT HUP INT TERM
	printf 'SMD404_CONTROLLER_APPLY_COMPLETE phase=v1 smoke_job=%s backup=%s state=%s run_dir=%s\n' \
		"$smoke_job" "$backup_conf" "$state_file" "$run_dir"
	;;
update)
	load_state
	[ "${phase:-}" = APPLIED_V1 ] || fail "unexpected controller phase=${phase:-unset}"
	grep -Fqx 'Prolog=smd404_configless_prolog.sh' "$slurm_conf" ||
		fail 'portable Prolog setting is absent'
	write_hook 2 "${run_dir}/${hook_name}.v2" || fail 'cannot build hook v2'
	atomic_install_hook "${run_dir}/${hook_name}.v2" ||
		fail 'cannot install hook v2'
	"$scontrol" reconfigure >"${run_dir}/reconfigure-v2.out" \
		2>"${run_dir}/reconfigure-v2.err" ||
		fail 'controller hook-v2 reconfigure failed; portable v1 config remains active'
	wait_nodes_idle updated ||
		fail 'nodes did not become IDLE after hook update; portable config remains active'
	write_state APPLIED_V2 || fail 'cannot update state file'
	printf 'SMD404_CONTROLLER_UPDATE_COMPLETE hook_version=2 state=%s run_dir=%s\n' \
		"$state_file" "$run_dir"
	;;
restore)
	[ "${SMD404_MAC_LOCAL_RESTORED:-}" = YES ] ||
		fail 'set SMD404_MAC_LOCAL_RESTORED=YES only after the Mac driver reports local-mode restoration'
	load_state
	current_hash=$(sha256sum "$slurm_conf" | awk '{ print $1 }')
	atomic_install_conf "$backup_conf" "$slurm_conf" "$backup_conf" ||
		fail 'cannot restore original slurm.conf'
	rm -f "$hook_path" || fail 'cannot remove SMD-404 hook'
	"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
		2>"${run_dir}/reconfigure-restore.err" || fail 'controller restore reconfigure failed'
	wait_nodes_idle restored || fail 'nodes did not return IDLE after controller restore'
	[ "$(sha256sum "$slurm_conf" | awk '{ print $1 }')" = "$before_hash" ] ||
		fail 'restored slurm.conf hash mismatch'
	"$scontrol" show config >"${run_dir}/controller-config-restored.txt" ||
		fail 'cannot read restored controller config'
	for expected in \
		'ProctrackType[[:space:]]*=[[:space:]]*proctrack/cgroup' \
		'TaskPlugin[[:space:]]*=[[:space:]]*task/affinity' \
		'JobAcctGatherType[[:space:]]*=[[:space:]]*jobacct_gather/cgroup'; do
		grep -Eq "^${expected}$" "${run_dir}/controller-config-restored.txt" ||
			fail "restored controller setting mismatch=$expected"
	done
	run_ubuntu_smoke restored || fail 'Ubuntu restored-profile smoke failed'
	rm -f "$state_file"
	printf 'controller_hash portable=%s restored=%s\n' "$current_hash" "$before_hash"
	printf 'SMD404_CONTROLLER_RESTORE_COMPLETE smoke_job=%s original_hash=%s run_dir=%s\n' \
		"$smoke_job" "$before_hash" "$run_dir"
	;;
esac
