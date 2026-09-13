#!/bin/sh

set -eu

user_name=smdmismatch
user_uid=3201
user_gid=3201
reserved_worker_uid=3202
reserved_worker_gid=3202
user_home=/home/smdmismatch

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

if [ "${SMD102_ACCOUNT_CREATE_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD102_ACCOUNT_CREATE_CONFIRMED=YES after approving account creation\n' >&2
	exit 64
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Linux ] || fail 'this script is for the Ubuntu controller node'
cd /tmp || fail 'cannot change directory to /tmp'

for command_path in /usr/bin/getent /usr/bin/id /usr/bin/awk \
	/usr/bin/passwd /usr/bin/stat /usr/sbin/groupadd /usr/sbin/useradd \
	/bin/chmod; do
	[ -x "$command_path" ] || fail "missing command: $command_path"
done

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "SMD102_UBUNTU_PROVISION_INCOMPLETE rc=%s; inspect passwd/group/home state before retry\n" "$rc" >&2; fi' EXIT HUP INT TERM

[ -z "$(/usr/bin/getent passwd "$reserved_worker_uid")" ] || \
	fail "reserved worker UID $reserved_worker_uid must remain unused on Ubuntu"
[ -z "$(/usr/bin/getent group "$reserved_worker_gid")" ] || \
	fail "reserved worker GID $reserved_worker_gid must remain unused on Ubuntu"

uid_owner=$(/usr/bin/getent passwd "$user_uid" | /usr/bin/awk -F: 'NR == 1 { print $1 }')
if [ -n "$uid_owner" ] && [ "$uid_owner" != "$user_name" ]; then
	fail "UID $user_uid is already owned by $uid_owner"
fi

gid_owner=$(/usr/bin/getent group "$user_gid" | /usr/bin/awk -F: 'NR == 1 { print $1 }')
if [ -n "$gid_owner" ] && [ "$gid_owner" != "$user_name" ]; then
	fail "GID $user_gid is already owned by $gid_owner"
fi

if /usr/bin/getent group "$user_name" >/dev/null 2>&1; then
	actual_gid=$(/usr/bin/getent group "$user_name" | /usr/bin/awk -F: 'NR == 1 { print $3 }')
	[ "$actual_gid" = "$user_gid" ] || fail "$user_name group has unexpected GID $actual_gid"
else
	printf 'step=create_group name=%s gid=%s\n' "$user_name" "$user_gid"
	/usr/sbin/groupadd --gid "$user_gid" "$user_name"
fi

if /usr/bin/getent passwd "$user_name" >/dev/null 2>&1; then
	actual_uid=$(/usr/bin/id -u "$user_name")
	actual_gid=$(/usr/bin/id -g "$user_name")
	actual_home=$(/usr/bin/getent passwd "$user_name" | /usr/bin/awk -F: 'NR == 1 { print $6 }')
	[ "$actual_uid" = "$user_uid" ] || fail "$user_name has unexpected UID $actual_uid"
	[ "$actual_gid" = "$user_gid" ] || fail "$user_name has unexpected primary GID $actual_gid"
	[ "$actual_home" = "$user_home" ] || fail "$user_name has unexpected HOME $actual_home"
else
	printf 'step=create_user name=%s uid=%s gid=%s\n' "$user_name" "$user_uid" "$user_gid"
	/usr/sbin/useradd --uid "$user_uid" --gid "$user_gid" \
		--create-home --home-dir "$user_home" --shell /bin/bash \
		--comment 'SMD-102 intentional ID mismatch user' "$user_name"
fi

/usr/bin/passwd --lock "$user_name" >/dev/null
/bin/chmod 0700 "$user_home"

[ "$(/usr/bin/id -u "$user_name")" = "$user_uid" ] || fail 'UID verification failed'
[ "$(/usr/bin/id -g "$user_name")" = "$user_gid" ] || fail 'GID verification failed'
home_identity=$(/usr/bin/stat -c '%u:%g:%a' "$user_home")
[ "$home_identity" = "$user_uid:$user_gid:700" ] || \
	fail "unexpected home identity or mode: $home_identity"
[ -z "$(/usr/bin/getent passwd "$reserved_worker_uid")" ] || \
	fail "reserved worker UID $reserved_worker_uid became occupied"
[ -z "$(/usr/bin/getent group "$reserved_worker_gid")" ] || \
	fail "reserved worker GID $reserved_worker_gid became occupied"

printf '%s\n' '[ubuntu-passwd]'
/usr/bin/getent passwd "$user_name"
printf '%s\n' '[ubuntu-group]'
/usr/bin/getent group "$user_name"
printf '%s\n' '[ubuntu-identity]'
/usr/bin/id "$user_name"
printf 'home=%s identity_mode=%s\n' "$user_home" "$home_identity"
printf 'password_login=LOCKED\n'
printf 'reserved_worker_identity_on_ubuntu=%s:%s:UNUSED\n' \
	"$reserved_worker_uid" "$reserved_worker_gid"
printf 'SMD102_UBUNTU_PROVISION_COMPLETE user=%s uid=%s gid=%s\n' \
	"$user_name" "$user_uid" "$user_gid"
trap - EXIT HUP INT TERM
