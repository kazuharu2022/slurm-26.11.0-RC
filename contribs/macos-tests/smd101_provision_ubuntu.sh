#!/bin/sh

set -eu

test_user=testuser
test_uid=3001
test_gid=3001
new_user=testuser2
new_uid=3002
new_gid=3002
shared_group=smdtest
shared_gid=3100
new_home=/home/testuser2

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

if [ "${SMD101_ACCOUNT_CREATE_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD101_ACCOUNT_CREATE_CONFIRMED=YES after approving account creation\n' >&2
	exit 64
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Linux ] || fail 'this script is for the Ubuntu head node'

for command_path in /usr/bin/getent /usr/bin/id /usr/bin/awk /usr/bin/grep \
	/usr/bin/passwd /usr/bin/stat /usr/sbin/groupadd /usr/sbin/useradd \
	/usr/sbin/usermod /bin/chmod; do
	[ -x "$command_path" ] || fail "missing command: $command_path"
done

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "SMD101_UBUNTU_PROVISION_INCOMPLETE rc=%s; inspect passwd/group state before retry\n" "$rc" >&2; fi' EXIT HUP INT TERM

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail "$test_user UID is not $test_uid"
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail "$test_user primary GID is not $test_gid"

uid_owner=$(/usr/bin/getent passwd "$new_uid" | /usr/bin/awk -F: 'NR == 1 { print $1 }')
if [ -n "$uid_owner" ] && [ "$uid_owner" != "$new_user" ]; then
	fail "UID $new_uid is already owned by $uid_owner"
fi

for group_spec in "$new_user:$new_gid" "$shared_group:$shared_gid"; do
	group_name=${group_spec%%:*}
	group_id=${group_spec#*:}
	gid_owner=$(/usr/bin/getent group "$group_id" | /usr/bin/awk -F: 'NR == 1 { print $1 }')
	if [ -n "$gid_owner" ] && [ "$gid_owner" != "$group_name" ]; then
		fail "GID $group_id is already owned by $gid_owner"
	fi
	if /usr/bin/getent group "$group_name" >/dev/null 2>&1; then
		actual_gid=$(/usr/bin/getent group "$group_name" | /usr/bin/awk -F: 'NR == 1 { print $3 }')
		[ "$actual_gid" = "$group_id" ] || fail "$group_name has unexpected GID $actual_gid"
	else
		/usr/sbin/groupadd --gid "$group_id" "$group_name"
	fi
done

if /usr/bin/getent passwd "$new_user" >/dev/null 2>&1; then
	actual_uid=$(/usr/bin/id -u "$new_user")
	actual_gid=$(/usr/bin/id -g "$new_user")
	[ "$actual_uid" = "$new_uid" ] || fail "$new_user has unexpected UID $actual_uid"
	[ "$actual_gid" = "$new_gid" ] || fail "$new_user has unexpected primary GID $actual_gid"
else
	/usr/sbin/useradd --uid "$new_uid" --gid "$new_gid" \
		--groups "$shared_group" --create-home --home-dir "$new_home" \
		--shell /bin/bash --comment 'SMD-101 test user' "$new_user"
fi

/usr/sbin/usermod --append --groups "$shared_group" "$test_user"
/usr/sbin/usermod --append --groups "$shared_group" "$new_user"
/usr/bin/passwd --lock "$new_user" >/dev/null
/bin/chmod 0700 "$new_home"

[ "$(/usr/bin/id -u "$new_user")" = "$new_uid" ] || fail 'new UID verification failed'
[ "$(/usr/bin/id -g "$new_user")" = "$new_gid" ] || fail 'new primary GID verification failed'
/usr/bin/id -G "$test_user" | /usr/bin/awk -v gid="$shared_gid" '
{
	for (i = 1; i <= NF; i++) if ($i == gid) found = 1
}
END { exit(found ? 0 : 1) }
' || fail "$test_user is not in GID $shared_gid"
/usr/bin/id -G "$new_user" | /usr/bin/awk -v gid="$shared_gid" '
{
	for (i = 1; i <= NF; i++) if ($i == gid) found = 1
}
END { exit(found ? 0 : 1) }
' || fail "$new_user is not in GID $shared_gid"

home_identity=$(/usr/bin/stat -c '%u:%g:%a' "$new_home")
case "$home_identity" in
"$new_uid:$new_gid:700") ;;
*) fail "unexpected home identity or mode: $home_identity" ;;
esac

printf '%s\n' '[ubuntu-passwd]'
/usr/bin/getent passwd "$test_user" "$new_user"
printf '%s\n' '[ubuntu-groups]'
/usr/bin/getent group "$new_user" "$shared_group"
printf '%s\n' '[ubuntu-identities]'
/usr/bin/id "$test_user"
/usr/bin/id "$new_user"
printf 'home=%s identity_mode=%s\n' "$new_home" "$home_identity"
printf 'password_login=%s\n' 'LOCKED'
printf 'SMD101_UBUNTU_PROVISION_COMPLETE testuser=%s:%s new_user=%s:%s shared_group=%s:%s\n' \
	"$test_uid" "$test_gid" "$new_uid" "$new_gid" "$shared_group" "$shared_gid"
trap - EXIT HUP INT TERM

