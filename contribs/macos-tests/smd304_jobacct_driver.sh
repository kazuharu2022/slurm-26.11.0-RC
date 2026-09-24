#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
probe_src=${repo_root}/contribs/macos-tests/smd304_jobacct_probe.c
mac_prefix=/opt/slurm/26.11.0
mac_conf=${mac_prefix}/etc/slurm.conf
mac_bin=${mac_prefix}/bin
remote_host=${SMD304_REMOTE_HOST:-tera@192.168.10.180}
ssh_key=${SMD304_SSH_KEY:-/Users/tera/.ssh/id_ed25519}
remote_prefix=${SMD304_REMOTE_PREFIX:-/usr/local/slurm/26.11.0}
node_name=${SMD304_NODE_NAME:-PC-210}
stamp=$(/bin/date +%Y%m%dT%H%M%S)
run_dir=$(/usr/bin/mktemp -d "/private/tmp/slurm-smd304-${stamp}.XXXXXX")
payload_dir=${run_dir}/payload
output_dir=${run_dir}/job-output
probe_bin=${payload_dir}/smd304_jobacct_probe
marker=${output_dir}/ready.txt
io_file=${output_dir}/io.bin
stdout_file=${output_dir}/job.out
stderr_file=${output_dir}/job.err
log_file=/var/log/slurm/slurmd-launchd.err.log
job_id=
job_terminal=NO

fail()
{
	/usr/bin/printf 'SMD304_FAIL %s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

remote()
{
	/usr/bin/ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 \
		"$remote_host" "$@"
}

cleanup()
{
	if [ -n "$job_id" ] && [ "$job_terminal" != YES ]; then
		remote "set +e; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scancel ${job_id} >/dev/null 2>&1; exit 0" \
			>/dev/null 2>&1 || true
	fi
}

production_hashes()
{
	/usr/bin/shasum -a 256 \
		${mac_prefix}/sbin/slurmd \
		${mac_prefix}/sbin/slurmstepd \
		${mac_prefix}/lib/slurm/jobacct_gather_linux.so \
		${mac_conf} \
		/Library/LaunchDaemons/org.schedmd.slurmd.plist
}

launchd_pid()
{
	/bin/launchctl print system/org.schedmd.slurmd |
		/usr/bin/awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }'
}

metric_value()
{
	key=$1
	file=$2
	/usr/bin/awk -v wanted="${key}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, wanted) == 1) {
				sub(wanted, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'run without sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
[ -r "$probe_src" ] || fail 'probe source is missing'
[ -r "$mac_conf" ] || fail 'production config is not readable'
[ -x "${mac_bin}/scontrol" ] || fail 'production scontrol is missing'
[ -x "${mac_bin}/squeue" ] || fail 'production squeue is missing'
[ -r "$ssh_key" ] || fail 'SSH key is not readable'
[ -r "$log_file" ] || fail 'slurmd log is not readable'
[ -f "${mac_prefix}/lib/slurm/jobacct_gather_linux.so" ] ||
	fail 'installed jobacct_gather/linux inventory changed'
[ ! -e "${mac_prefix}/lib/slurm/jobacct_gather_cgroup.so" ] ||
	fail 'unexpected jobacct_gather/cgroup plugin is installed'
/usr/bin/grep -Eq '^[[:space:]]*JobAcctGatherType=jobacct_gather/none[[:space:]]*$' \
	"$mac_conf" || fail 'Mac production config is not jobacct_gather/none'
/usr/bin/grep -Fq 'xfree(conf->job_acct_gather_type)' \
	"${repo_root}/src/common/read_config.c" || fail 'none parser source contract changed'
/usr/bin/grep -Fq 'plugin_inited = PLUGIN_NOOP' \
	"${repo_root}/src/interfaces/jobacct_gather.c" || fail 'jobacct no-op source contract changed'

/bin/chmod 0711 "$run_dir"
/bin/mkdir -m 0755 "$payload_dir"
/bin/mkdir -m 0777 "$output_dir"

before_pid=$(launchd_pid)
case "$before_pid" in
''|*[!0-9]*) fail 'invalid launchd PID before test' ;;
esac
production_hashes >"${run_dir}/production-before.sha256"
log_lines_before=$(/usr/bin/wc -l <"$log_file" | /usr/bin/tr -d ' ')

SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" ping \
	>"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node "$node_name" -o \
	>"${run_dir}/node-before.txt" || fail 'node preflight failed'
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-before.txt" ||
	fail 'node is not IDLE before test'
/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt" ||
	fail 'CPUAlloc is not zero before test'
/usr/bin/grep -q 'AllocMem=0' "${run_dir}/node-before.txt" ||
	fail 'AllocMem is not zero before test'
SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h -w "$node_name" \
	>"${run_dir}/queue-before.txt"
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'queue is not empty before test'

remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n true; sudo -n -u testuser id; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol ping; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show node ${node_name} -o; test -z \"\$(sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/squeue -h -w ${node_name})\"" \
	>"${run_dir}/controller-preflight.txt" 2>&1 || fail 'controller preflight failed'

/usr/bin/sed -n '4188,4195p' "${repo_root}/src/common/read_config.c" \
	>"${run_dir}/source-none-parser.txt"
/usr/bin/sed -n '518,545p' "${repo_root}/src/interfaces/jobacct_gather.c" \
	>"${run_dir}/source-plugin-init.txt"
/usr/bin/sed -n '52,82p' "${repo_root}/doc/html/accounting.shtml" \
	>"${run_dir}/official-accounting-contract.txt"

/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O2 \
	"$probe_src" -o "$probe_bin" || fail 'probe build failed'
/bin/chmod 0755 "$probe_bin"
/usr/bin/file "$probe_bin" >"${run_dir}/probe-file.txt"
/usr/bin/shasum -a 256 "$probe_src" "$probe_bin" "$0" \
	>"${run_dir}/inputs.sha256"

suffix=$(/bin/date +%H%M%S)
job_name=S304_${suffix}
job_id=$(remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n -u testuser env HOME=/tmp LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sbatch --parsable --partition=debug --nodelist=${node_name} --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=256M --time=00:02:00 --chdir=/tmp --job-name=${job_name} --output=${stdout_file} --error=${stderr_file} --wrap='${probe_bin} ${marker} ${io_file} 20'") ||
	fail 'job submission failed'
case "$job_id" in
''|*[!0-9]*) fail "invalid job id: ${job_id}" ;;
esac
/usr/bin/printf 'job_id=%s job_name=%s\n' "$job_id" "$job_name" \
	>"${run_dir}/submission.txt"

i=0
while [ ! -s "$marker" ]; do
	if [ "$i" -ge 60 ]; then
		fail 'payload did not publish its ready marker within 60 seconds'
	fi
	/bin/sleep 1
	i=$((i + 1))
done
/bin/cp "$marker" "${run_dir}/payload-self-metrics.txt"

payload_pid=$(metric_value pid "$marker")
memory_bytes=$(metric_value memory_bytes "$marker")
write_bytes=$(metric_value write_bytes "$marker")
read_bytes=$(metric_value read_bytes "$marker")
user_us=$(metric_value user_us "$marker")
system_us=$(metric_value system_us "$marker")
case "$payload_pid" in
''|*[!0-9]*) fail 'payload PID is invalid' ;;
esac
[ "$memory_bytes" -eq 134217728 ] || fail "unexpected memory bytes ${memory_bytes}"
[ "$write_bytes" -eq 33554432 ] || fail "unexpected write bytes ${write_bytes}"
[ "$read_bytes" -eq 33554432 ] || fail "unexpected read bytes ${read_bytes}"
[ $((user_us + system_us)) -ge 1500000 ] ||
	fail "payload CPU usage is too small: user=${user_us} system=${system_us}"

i=1
while [ "$i" -le 3 ]; do
	/bin/ps -p "$payload_pid" -o pid=,rss=,vsz=,%cpu=,user=,command= \
		>"${run_dir}/ps-live-${i}.txt" || fail "cannot inspect live payload sample ${i}"
	remote "set +e; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sstat -j ${job_id}.batch -n -P --format=JobID,AveCPU,AveRSS,MaxRSS,MaxVMSize,MaxDiskRead,MaxDiskWrite,TRESUsageInAve,TRESUsageInMax,TRESUsageOutAve,TRESUsageOutMax; echo SSTAT_RC=\$?; exit 0" \
		>"${run_dir}/sstat-live-${i}.txt" 2>&1 || fail "sstat transport failed for sample ${i}"
	/bin/sleep 1
	i=$((i + 1))
done

rss_kb=$(/usr/bin/awk 'NR == 1 { print $2 }' "${run_dir}/ps-live-1.txt")
case "$rss_kb" in
''|*[!0-9]*) fail "invalid ps RSS: ${rss_kb}" ;;
esac
[ "$rss_kb" -ge 100000 ] || fail "live RSS too small: ${rss_kb} KiB"

i=0
while [ "$i" -lt 90 ]; do
	state=$(remote "set +e; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sacct -X -j ${job_id} -n -P --format=State | head -n 1; exit 0" | /usr/bin/awk -F'|' 'NR == 1 { print $1 }')
	case "$state" in
	COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY)
		job_terminal=YES
		break
		;;
	esac
	/bin/sleep 1
	i=$((i + 1))
done
[ "$job_terminal" = YES ] || fail 'job did not reach a terminal state'

remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sacct -j ${job_id} -n -P --format=JobIDRaw,JobName,State,ExitCode,ElapsedRaw,CPUTimeRAW,TotalCPU,UserCPU,SystemCPU,AveRSS,MaxRSS,MaxVMSize,MaxDiskRead,MaxDiskWrite,TRESUsageInAve,TRESUsageInMax,TRESUsageOutAve,TRESUsageOutMax,ReqMem,AllocTRES" \
	>"${run_dir}/sacct-final.txt" 2>"${run_dir}/sacct-final.stderr" ||
	fail 'final sacct query failed'
/usr/bin/grep -Eq "^${job_id}\|${job_name}\|COMPLETED\|0:0\|" \
	"${run_dir}/sacct-final.txt" || fail 'parent job accounting is not COMPLETED 0:0'
/usr/bin/grep -Eq "^${job_id}\.batch\|batch\|COMPLETED\|0:0\|" \
	"${run_dir}/sacct-final.txt" || fail 'batch accounting is not COMPLETED 0:0'
[ -s "$stdout_file" ] || fail 'payload stdout is missing'
[ ! -s "$stderr_file" ] || fail 'payload stderr is not empty'
/usr/bin/grep -q '^SMD304_SELF ' "$stdout_file" || fail 'self metrics are missing from stdout'
/usr/bin/grep -q '^SMD304_DONE ' "$stdout_file" || fail 'payload completion marker is missing'

SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node "$node_name" -o \
	>"${run_dir}/node-after.txt" || fail 'final node readback failed'
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-after.txt" ||
	fail 'node is not IDLE after test'
/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" ||
	fail 'final CPUAlloc is not zero'
/usr/bin/grep -q 'AllocMem=0' "${run_dir}/node-after.txt" ||
	fail 'final AllocMem is not zero'
SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h -w "$node_name" \
	>"${run_dir}/queue-after.txt"
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'queue is not empty after test'

after_pid=$(launchd_pid)
[ "$after_pid" = "$before_pid" ] || fail 'launchd slurmd PID changed'
production_hashes >"${run_dir}/production-after.sha256"
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production artifact hash changed'

log_start=$((log_lines_before + 1))
/usr/bin/sed -n "${log_start},\$p" "$log_file" >"${run_dir}/launchd-log-delta.txt"
if /usr/bin/grep -Eqi 'fatal|segmentation|abort|jobacct.*error|plugin.*error' \
	"${run_dir}/launchd-log-delta.txt"; then
	fail 'unexpected daemon error appeared in log delta'
fi

/usr/bin/printf '%s\n' \
	"SMD304_RUNTIME_COMPLETE job=${job_id} payload_cpu_us=$((user_us + system_us)) live_rss_kb=${rss_kb} payload_read_bytes=${read_bytes} payload_write_bytes=${write_bytes} state=COMPLETED node=IDLE queue=EMPTY launchd_pid=${after_pid} production=UNCHANGED run_dir=${run_dir}"
