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
new_home=/Users/testuser2

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

user_name_for_uid()
{
	/usr/bin/dscacheutil -q user -a uid "$1" 2>/dev/null | \
		/usr/bin/awk '/^name: / { print $2; exit }'
}

group_name_for_gid()
{
	/usr/bin/dscacheutil -q group -a gid "$1" 2>/dev/null | \
		/usr/bin/awk '/^name: / { print $2; exit }'
}

group_gid_for_name()
{
	/usr/bin/dscacheutil -q group -a name "$1" 2>/dev/null | \
		/usr/bin/awk '/^gid: / { print $2; exit }'
}

step()
{
	printf 'step=%s\n' "$1"
}

user_guid()
{
	/usr/bin/dscl . -read "/Users/$1" GeneratedUID 2>/dev/null | \
		/usr/bin/awk '/^GeneratedUID: / { print $2; exit }'
}

merge_group_member()
{
	group_name=$1
	member_name=$2
	member_guid=$(user_guid "$member_name")
	[ -n "$member_guid" ] || fail "missing GeneratedUID for $member_name"

	step "merge_group_member group=$group_name member=$member_name"
	/usr/bin/dscl . -merge "/Groups/$group_name" GroupMembership "$member_name"
	/usr/bin/dscl . -merge "/Groups/$group_name" GroupMembers "$member_guid"
}

if [ "${SMD101_ACCOUNT_CREATE_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD101_ACCOUNT_CREATE_CONFIRMED=YES after approving account creation\n' >&2
	exit 64
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this script is for the macOS worker node'
cd /tmp || fail 'cannot change directory to /tmp'

for command_path in /usr/bin/dscl /usr/bin/dscacheutil /usr/bin/id \
	/usr/bin/awk /usr/bin/uuidgen /usr/sbin/dseditgroup \
	/usr/sbin/createhomedir /usr/sbin/chown /bin/chmod; do
	[ -x "$command_path" ] || fail "missing command: $command_path"
done

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "SMD101_MACOS_PROVISION_INCOMPLETE rc=%s; inspect Directory Service and home state before retry\n" "$rc" >&2; fi' EXIT HUP INT TERM

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail "$test_user UID is not $test_uid"
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail "$test_user primary GID is not $test_gid"

uid_owner=$(user_name_for_uid "$new_uid")
if [ -n "$uid_owner" ] && [ "$uid_owner" != "$new_user" ]; then
	fail "UID $new_uid is already owned by $uid_owner"
fi

for group_spec in "$new_user:$new_gid" "$shared_group:$shared_gid"; do
	group_name=${group_spec%%:*}
	group_id=${group_spec#*:}
	gid_owner=$(group_name_for_gid "$group_id")
	if [ -n "$gid_owner" ] && [ "$gid_owner" != "$group_name" ]; then
		fail "GID $group_id is already owned by $gid_owner"
	fi
	actual_gid=$(group_gid_for_name "$group_name")
	if [ -n "$actual_gid" ]; then
		[ "$actual_gid" = "$group_id" ] || fail "$group_name has unexpected GID $actual_gid"
	else
		step "create_group name=$group_name gid=$group_id"
		/usr/sbin/dseditgroup -o create -n . -i "$group_id" \
			-r "SMD-101 $group_name" "$group_name"
	fi
done

if /usr/bin/id "$new_user" >/dev/null 2>&1; then
	actual_uid=$(/usr/bin/id -u "$new_user")
	actual_gid=$(/usr/bin/id -g "$new_user")
	[ "$actual_uid" = "$new_uid" ] || fail "$new_user has unexpected UID $actual_uid"
	[ "$actual_gid" = "$new_gid" ] || fail "$new_user has unexpected primary GID $actual_gid"
else
	step "create_user name=$new_user uid=$new_uid gid=$new_gid"
	generated_uid=$(/usr/bin/uuidgen)
	/usr/bin/dscl . -create "/Users/$new_user"
	/usr/bin/dscl . -create "/Users/$new_user" RealName 'SMD-101 Test User 2'
	/usr/bin/dscl . -create "/Users/$new_user" UniqueID "$new_uid"
	/usr/bin/dscl . -create "/Users/$new_user" PrimaryGroupID "$new_gid"
	/usr/bin/dscl . -create "/Users/$new_user" NFSHomeDirectory "$new_home"
	/usr/bin/dscl . -create "/Users/$new_user" UserShell /bin/bash
	/usr/bin/dscl . -create "/Users/$new_user" GeneratedUID "$generated_uid"
	/usr/bin/dscl . -create "/Users/$new_user" Password '*'
	/usr/bin/dscl . -create "/Users/$new_user" IsHidden 1
fi

# Primary group membership is represented by PrimaryGroupID and does not need a
# duplicate explicit membership entry.  For the supplementary group, update the
# two local Directory Service membership attributes directly.  On this host the
# dseditgroup edit path returned eDSPermissionError after all three records had
# been created; direct attribute updates avoid that failing edit path.
merge_group_member "$shared_group" "$test_user"
merge_group_member "$shared_group" "$new_user"
/usr/bin/dscacheutil -flushcache

if [ ! -d "$new_home" ]; then
	step "create_home path=$new_home"
	/usr/sbin/createhomedir -c -u "$new_user"
fi
[ -d "$new_home" ] || fail "home directory was not created: $new_home"
/usr/sbin/chown -R "$new_uid:$new_gid" "$new_home"
/bin/chmod 0700 "$new_home"

step verify

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

home_identity=$(/usr/bin/stat -f '%u:%g:%Lp' "$new_home")
case "$home_identity" in
"$new_uid:$new_gid:700") ;;
*) fail "unexpected home identity or mode: $home_identity" ;;
esac

printf '%s\n' '[macos-users]'
/usr/bin/dscacheutil -q user -a name "$test_user"
/usr/bin/dscacheutil -q user -a name "$new_user"
printf '%s\n' '[macos-groups]'
/usr/bin/dscacheutil -q group -a name "$new_user"
/usr/bin/dscacheutil -q group -a name "$shared_group"
printf '%s\n' '[macos-identities]'
/usr/bin/id "$test_user"
/usr/bin/id "$new_user"
printf 'home=%s identity_mode=%s\n' "$new_home" "$home_identity"
printf 'password_login=%s\n' 'DISABLED'
printf 'hidden_from_login_window=%s\n' 'YES'
printf 'SMD101_MACOS_PROVISION_COMPLETE testuser=%s:%s new_user=%s:%s shared_group=%s:%s\n' \
	"$test_uid" "$test_gid" "$new_uid" "$new_gid" "$shared_group" "$shared_gid"
trap - EXIT HUP INT TERM
