#!/bin/sh

set -u

candidate=${1:-}
case "$candidate" in
/*) ;;
*) printf 'usage: %s /absolute/path/to/certgen_script.so\n' "$0" >&2; exit 64 ;;
esac
if [ "${SMD407_CERTGEN_LINUX_PROBE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' 'error: set SMD407_CERTGEN_LINUX_PROBE_CONFIRMED=YES for the isolated client probe' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
production_plugins=${prefix}/lib/slurm
ca=${prefix}/etc/ca_cert.pem
run_dir=$(mktemp -d /tmp/slurm-smd407-certgen-linux-client-XXXXXX)
stage_dir=${run_dir}/plugins
success=0

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

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	find "$run_dir" -type f -exec chmod a+r {} \; >/dev/null 2>&1 || true
	if [ "$success" -ne 1 ]; then
		printf 'probe stopped; production was not modified; inspect run_dir=%s\n' "$run_dir" >&2
	fi
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this probe is for Linux'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$candidate" "$slurm_conf" "$slurmdbd_conf" "$scontrol" \
	"$squeue" "$ca" "$production_plugins/tls_s2n.so"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk chmod cmp cp env file find grep hostname id mkdir mktemp \
	sha256sum systemctl timeout uname; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done

mkdir "$stage_dir" || fail 'cannot create plugin stage'
chmod 0755 "$run_dir" "$stage_dir" || fail 'cannot make run directory traversable'
cp -a "${production_plugins}/." "$stage_dir" || fail 'cannot stage production plugin set'
cp "$candidate" "$stage_dir/certgen_script.so" || fail 'cannot stage candidate plugin'
chmod 0755 "$stage_dir/certgen_script.so" || fail 'cannot set candidate plugin mode'
file "$stage_dir/certgen_script.so" >"$run_dir/plugin-file.txt" || fail 'cannot inspect candidate plugin'
grep -Eq 'ELF 64-bit LSB shared object, x86-64' "$run_dir/plugin-file.txt" || \
	fail 'candidate architecture mismatch'
sha256sum "$candidate" "$stage_dir/certgen_script.so" >"$run_dir/plugin.sha256" || \
	fail 'cannot hash candidate plugin'

awk -v stage="$stage_dir" -v ca="$ca" '
/^[[:space:]]*PluginDir=/ { next }
/^[[:space:]]*CommunicationParameters=/ {
	if (tolower($0) !~ /disable_http/) $0 = $0 ",disable_http"
	seen_communication = 1
	print
	next
}
/^[[:space:]]*DebugFlags=/ {
	if (tolower($0) !~ /(^|,)tls(,|$)/) $0 = $0 ",TLS"
	seen_debug = 1
	print
	next
}
{ print }
END {
	if (!seen_communication) print "CommunicationParameters=disable_http"
	if (!seen_debug) print "DebugFlags=TLS"
	print "PluginDir=" stage
	print "CertgenType=certgen/script"
	print "TLSType=tls/s2n"
	print "TLSParameters=ca_cert_file=" ca
}
' "$slurm_conf" >"$run_dir/slurm.conf" || fail 'cannot build client config'
chmod 0644 "$run_dir/slurm.conf" || fail 'cannot set client config mode'

sha256sum "$production_plugins/certgen_script.so" "$slurm_conf" "$slurmdbd_conf" \
	>"$run_dir/production-before.sha256" || fail 'cannot hash production inputs'
systemctl is-active slurmdbd slurmctld slurmd >"$run_dir/services-before.txt" || \
	fail 'production service is not active'
systemctl show -p MainPID slurmdbd slurmctld slurmd >"$run_dir/pids-before.txt" || \
	fail 'cannot read production PIDs'
"$scontrol" show config >"$run_dir/active-before.txt" || fail 'cannot read active config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' "$run_dir/active-before.txt" || \
	fail 'active TLS is not tls/none'

probe_rc=0
timeout 30 env SLURM_CONF="$run_dir/slurm.conf" "$scontrol" -vvvvvv ping \
	>"$run_dir/scontrol.out" 2>"$run_dir/scontrol.err" || probe_rc=$?
printf 'probe_rc=%s\n' "$probe_rc" >"$run_dir/result.txt"
if grep -Eq 'can not be executed|Unable to generate|failed to initialize tls plugin' \
	"$run_dir/scontrol.err"; then
	fail 'candidate certgen or TLS initialization failed'
fi
grep -Fq 'connection successfully created' "$run_dir/scontrol.err" || \
	fail 'TLS client connection success marker missing'
if [ "$probe_rc" -eq 0 ]; then
	grep -q ' is UP$' "$run_dir/scontrol.out" || fail 'successful client did not report controller UP'
	client_route=UP_VIA_LOCAL_SACK
else
	client_route=TLS_INIT_PASS_RPC_NOT_UP
fi

sha256sum "$production_plugins/certgen_script.so" "$slurm_conf" "$slurmdbd_conf" \
	>"$run_dir/production-after.sha256" || fail 'cannot rehash production inputs'
cmp -s "$run_dir/production-before.sha256" "$run_dir/production-after.sha256" || \
	fail 'production input changed'
systemctl is-active slurmdbd slurmctld slurmd >"$run_dir/services-after.txt" || \
	fail 'production service stopped'
cmp -s "$run_dir/services-before.txt" "$run_dir/services-after.txt" || \
	fail 'production service state changed'
systemctl show -p MainPID slurmdbd slurmctld slurmd >"$run_dir/pids-after.txt" || \
	fail 'cannot reread production PIDs'
cmp -s "$run_dir/pids-before.txt" "$run_dir/pids-after.txt" || fail 'production PID changed'
"$scontrol" show config >"$run_dir/active-after.txt" || fail 'cannot reread active config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' "$run_dir/active-after.txt" || \
	fail 'active TLS changed'
for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"$run_dir/$node.txt" || fail "cannot read node=$node"
	[ "$(node_field State "$run_dir/$node.txt")" = IDLE ] || fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "$run_dir/$node.txt")" = 0 ] || fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "$run_dir/$node.txt")" = 0 ] || fail "node=$node AllocMem is not zero"
done
"$squeue" -h -w ubuntu,PC-210 >"$run_dir/queue.txt" || fail 'cannot read queue'
[ ! -s "$run_dir/queue.txt" ] || fail 'target queue is not empty'

success=1
printf 'SMD407_CERTGEN_LINUX_CLIENT_PROBE_PASS certgen_init=PASS tls_client_connection=PASS client_route=%s production_unchanged=PASS services_pids_unchanged=PASS tls=tls/none nodes=IDLE queue=EMPTY run_dir=%s\n' \
	"$client_route" "$run_dir"
