#!/bin/sh

set -u

action=${1:-}
target_conf=${SMD001_TARGET_CONF:-}
slurm_prefix=${SMD001_SLURM_PREFIX:-}
backup_dir=${SMD001_BACKUP_DIR:-}
node_name=${SMD001_NODE_NAME:-PC-210}
node_addr=${SMD001_NODE_ADDR:-192.168.10.128}
host_label=${SMD001_HOST_LABEL:-unknown}
slurmd=${slurm_prefix}/sbin/slurmd
candidate=${backup_dir}/slurm.conf.nodeaddr-candidate
before=${backup_dir}/slurm.conf.before
metadata=${backup_dir}/metadata.before

fail()
{
	printf 'error[%s]: %s\n' "$host_label" "$*" >&2
	exit 1
}

hash_file()
{
	if [ -x /usr/bin/shasum ]; then
		/usr/bin/shasum -a 256 "$1"
	elif [ -x /usr/bin/sha256sum ]; then
		/usr/bin/sha256sum "$1"
	else
		fail 'no SHA-256 command'
	fi
}

file_metadata()
{
	case "$(/usr/bin/uname -s)" in
	Darwin) /usr/bin/stat -f '%u:%g:%Lp' "$1" ;;
	Linux) /usr/bin/stat -c '%u:%g:%a' "$1" ;;
	*) fail 'unsupported operating system' ;;
	esac
}

validate_candidate()
{
	[ -f "$candidate" ] || fail "missing candidate $candidate"
	count=$(/usr/bin/grep -c "^NodeName=${node_name}[[:space:]]" "$candidate")
	[ "$count" -eq 1 ] || fail "expected one NodeName=${node_name} line, found $count"
	/usr/bin/grep -Eq \
		"^NodeName=${node_name}[[:space:]].*([[:space:]])NodeAddr=${node_addr}([[:space:]]|$)" \
		"$candidate" || fail 'candidate NodeAddr mismatch'
	[ "$([ -e "${slurm_prefix}/etc/slurm.key" ] && printf yes || printf no)" = yes ] ||
		fail 'missing production slurm.key'
	SLURM_SACK_KEY="${slurm_prefix}/etc/slurm.key" \
		"$slurmd" -C -f "$candidate" >"${backup_dir}/candidate-parse.txt" \
		2>"${backup_dir}/candidate-parse.err" || fail 'candidate parse failed'
}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	fail 'run as root'
fi
[ -n "$target_conf" ] || fail 'SMD001_TARGET_CONF is required'
[ -n "$slurm_prefix" ] || fail 'SMD001_SLURM_PREFIX is required'
[ -n "$backup_dir" ] || fail 'SMD001_BACKUP_DIR is required'

case "$action" in
stage)
	[ -f "$target_conf" ] || fail "missing $target_conf"
	[ -x "$slurmd" ] || fail "missing $slurmd"
	[ ! -e "$backup_dir" ] || fail "backup directory already exists: $backup_dir"
	(umask 077 && /bin/mkdir "$backup_dir") || exit 1
	/bin/chmod 0700 "$backup_dir" || exit 1
	/bin/cp -p "$target_conf" "$before" || exit 1
	file_metadata "$target_conf" >"$metadata" || exit 1
	hash_file "$target_conf" >"${backup_dir}/before.sha256" || exit 1

	existing_line=$(/usr/bin/grep "^NodeName=${node_name}[[:space:]]" "$target_conf" || true)
	[ -n "$existing_line" ] || fail "NodeName=${node_name} line is missing"
	case "$existing_line" in
	*" NodeAddr=${node_addr}"*) /bin/cp -p "$target_conf" "$candidate" ;;
	*' NodeAddr='*) fail "existing NodeAddr is not ${node_addr}: $existing_line" ;;
	*)
		/usr/bin/awk -v node="$node_name" -v addr="$node_addr" '
		$1 == "NodeName=" node {
			print $0 " NodeAddr=" addr
			n++
			next
		}
		{ print }
		END { if (n != 1) exit 42 }
		' "$target_conf" >"$candidate" || fail 'candidate generation failed'
		;;
	esac
	validate_candidate
	hash_file "$candidate" >"${backup_dir}/candidate.sha256" || exit 1
	/usr/bin/diff -u "$before" "$candidate" >"${backup_dir}/config.diff" || diff_rc=$?
	if [ "${diff_rc:-0}" -gt 1 ]; then
		fail 'diff command failed'
	fi
	printf 'SMD001_NODEADDR_HOST_STAGED host=%s address=%s backup=%s\n' \
		"$host_label" "$node_addr" "$backup_dir"
	;;
apply)
	[ -f "$before" ] || fail 'backup is missing'
	validate_candidate
	before_metadata=$(/bin/cat "$metadata")
	/bin/cp "$candidate" "$target_conf" || exit 1
	/usr/bin/cmp -s "$candidate" "$target_conf" || fail 'active config differs from candidate'
	[ "$(file_metadata "$target_conf")" = "$before_metadata" ] ||
		fail 'active config metadata changed'
	hash_file "$target_conf" >"${backup_dir}/active-after.sha256" || exit 1
	printf 'SMD001_NODEADDR_HOST_APPLIED host=%s address=%s backup=%s\n' \
		"$host_label" "$node_addr" "$backup_dir"
	;;
verify)
	[ -f "$before" ] || fail 'backup is missing'
	validate_candidate
	/usr/bin/cmp -s "$candidate" "$target_conf" || fail 'active config differs from candidate'
	[ "$(file_metadata "$target_conf")" = "$(/bin/cat "$metadata")" ] ||
		fail 'active config metadata differs from before'
	hash_file "$target_conf" >"${backup_dir}/active-verified.sha256" || exit 1
	printf 'SMD001_NODEADDR_HOST_VERIFIED host=%s address=%s backup=%s\n' \
		"$host_label" "$node_addr" "$backup_dir"
	;;
restore)
	[ -f "$before" ] || fail 'backup is missing'
	before_metadata=$(/bin/cat "$metadata")
	/bin/cp "$before" "$target_conf" || exit 1
	/usr/bin/cmp -s "$before" "$target_conf" || fail 'restore cmp failed'
	[ "$(file_metadata "$target_conf")" = "$before_metadata" ] ||
		fail 'restored config metadata mismatch'
	hash_file "$target_conf" >"${backup_dir}/restored.sha256" || exit 1
	printf 'SMD001_NODEADDR_HOST_RESTORED host=%s backup=%s\n' \
		"$host_label" "$backup_dir"
	;;
*)
	printf 'usage: %s stage|apply|verify|restore\n' "$0" >&2
	exit 64
	;;
esac
