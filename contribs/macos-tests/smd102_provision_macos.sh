#!/bin/sh

set -eu

user_name=smdmismatch
user_uid=3202
user_gid=3202
controller_uid=3201
controller_gid=3201
user_home=/Users/smdmismatch
loginwindow_domain=/Library/Preferences/com.apple.loginwindow

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

user_value_for_name()
{
	key=$1
	/usr/bin/dscacheutil -q user -a name "$user_name" 2>/dev/null | \
		/usr/bin/awk -v key="$key:" '$1 == key { print $2; exit }'
}

user_guid_for_name()
{
	/usr/bin/dscl . -read "/Users/$user_name" GeneratedUID 2>/dev/null | \
		/usr/bin/awk '/^GeneratedUID: / { print $2; exit }'
}

loginwindow_user_hidden()
{
	/usr/bin/defaults read "$loginwindow_domain" HiddenUsersList 2>/dev/null | \
		/usr/bin/awk -v expected="$user_name" '
			{
				value = $0
				gsub(/^[ \t]+/, "", value)
				gsub(/[ \t]+$/, "", value)
				sub(/,$/, "", value)
				gsub(/^"/, "", value)
				gsub(/"$/, "", value)
				if (value == expected)
					found = 1
			}
			END { if (found) print "YES" }
		'
}

if [ "${SMD102_ACCOUNT_CREATE_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD102_ACCOUNT_CREATE_CONFIRMED=YES after approving account creation\n' >&2
	exit 64
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this script is for the macOS worker node'
cd /tmp || fail 'cannot change directory to /tmp'

for command_path in /usr/bin/dscl /usr/bin/dscacheutil /usr/bin/defaults /usr/bin/id \
	/usr/bin/awk /usr/bin/uuidgen /usr/bin/pwpolicy /usr/sbin/dseditgroup \
	/usr/sbin/createhomedir /usr/sbin/chown /bin/chmod; do
	[ -x "$command_path" ] || fail "missing command: $command_path"
done

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "SMD102_MACOS_PROVISION_INCOMPLETE rc=%s; inspect Directory Service and home state before retry\n" "$rc" >&2; fi' EXIT HUP INT TERM

[ -z "$(user_name_for_uid "$controller_uid")" ] || \
	fail "controller UID $controller_uid must remain unused on macOS"
[ -z "$(group_name_for_gid "$controller_gid")" ] || \
	fail "controller GID $controller_gid must remain unused on macOS"

uid_owner=$(user_name_for_uid "$user_uid")
if [ -n "$uid_owner" ] && [ "$uid_owner" != "$user_name" ]; then
	fail "UID $user_uid is already owned by $uid_owner"
fi

gid_owner=$(group_name_for_gid "$user_gid")
if [ -n "$gid_owner" ] && [ "$gid_owner" != "$user_name" ]; then
	fail "GID $user_gid is already owned by $gid_owner"
fi

actual_gid=$(group_gid_for_name "$user_name")
if [ -n "$actual_gid" ]; then
	[ "$actual_gid" = "$user_gid" ] || fail "$user_name group has unexpected GID $actual_gid"
else
	printf 'step=create_group name=%s gid=%s\n' "$user_name" "$user_gid"
	/usr/sbin/dseditgroup -o create -n . -i "$user_gid" \
		-r 'SMD-102 intentional ID mismatch group' "$user_name"
fi

if /usr/bin/id "$user_name" >/dev/null 2>&1; then
	actual_uid=$(/usr/bin/id -u "$user_name")
	actual_gid=$(/usr/bin/id -g "$user_name")
	actual_home=$(user_value_for_name dir)
	[ "$actual_uid" = "$user_uid" ] || fail "$user_name has unexpected UID $actual_uid"
	[ "$actual_gid" = "$user_gid" ] || fail "$user_name has unexpected primary GID $actual_gid"
	[ "$actual_home" = "$user_home" ] || fail "$user_name has unexpected HOME $actual_home"
else
	printf 'step=create_user name=%s uid=%s gid=%s\n' "$user_name" "$user_uid" "$user_gid"
	generated_uid=$(/usr/bin/uuidgen)
	/usr/bin/dscl . -create "/Users/$user_name"
	printf 'step=set_user_attribute name=%s key=RealName\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" RealName 'SMD-102 Intentional ID Mismatch User'
	printf 'step=set_user_attribute name=%s key=UniqueID\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" UniqueID "$user_uid"
	printf 'step=set_user_attribute name=%s key=PrimaryGroupID\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" PrimaryGroupID "$user_gid"
	printf 'step=set_user_attribute name=%s key=NFSHomeDirectory\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" NFSHomeDirectory "$user_home"
	printf 'step=set_user_attribute name=%s key=UserShell\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" UserShell /bin/bash
	printf 'step=set_user_attribute name=%s key=GeneratedUID\n' "$user_name"
	/usr/bin/dscl . -create "/Users/$user_name" GeneratedUID "$generated_uid"
fi

actual_guid=$(user_guid_for_name)
if [ -z "$actual_guid" ]; then
	printf 'step=repair_user_attribute name=%s key=GeneratedUID\n' "$user_name"
	actual_guid=$(/usr/bin/uuidgen)
	/usr/bin/dscl . -create "/Users/$user_name" GeneratedUID "$actual_guid"
fi
[ -n "$(user_guid_for_name)" ] || fail 'GeneratedUID verification failed'

printf 'step=set_loginwindow_hidden name=%s method=HiddenUsersList\n' "$user_name"
if [ "$(loginwindow_user_hidden)" != YES ]; then
	/usr/bin/defaults write "$loginwindow_domain" HiddenUsersList \
		-array-add "$user_name"
fi
[ "$(loginwindow_user_hidden)" = YES ] || \
	fail "loginwindow HiddenUsersList verification failed for $user_name"

printf 'step=disable_authentication name=%s\n' "$user_name"
if auth_before=$(/usr/bin/pwpolicy -u "$user_name" -authentication-allowed 2>&1); then
	auth_before_rc=0
else
	auth_before_rc=$?
fi
case "$auth_before" in
*"is not allowed to authenticate"*)
	printf 'authentication_already_disabled=YES\n'
	;;
*)
	if ! disable_output=$(/usr/bin/pwpolicy -u "$user_name" -disableuser 2>&1); then
		printf 'authentication_before=%s rc=%s\n' \
			"$auth_before" "$auth_before_rc" >&2
		printf '%s\n' "$disable_output" >&2
		fail "pwpolicy could not disable $user_name"
	fi
	[ -z "$disable_output" ] || printf '%s\n' "$disable_output"
	;;
esac
/usr/bin/dscacheutil -flushcache

if [ ! -d "$user_home" ]; then
	printf 'step=create_home path=%s\n' "$user_home"
	/usr/sbin/createhomedir -c -u "$user_name"
fi
[ -d "$user_home" ] || fail "home directory was not created: $user_home"
/usr/sbin/chown -R "$user_uid:$user_gid" "$user_home"
/bin/chmod 0700 "$user_home"

[ "$(/usr/bin/id -u "$user_name")" = "$user_uid" ] || fail 'UID verification failed'
[ "$(/usr/bin/id -g "$user_name")" = "$user_gid" ] || fail 'GID verification failed'
if auth_check=$(/usr/bin/pwpolicy -u "$user_name" -authentication-allowed 2>&1); then
	auth_check_rc=0
else
	auth_check_rc=$?
fi
case "$auth_check" in
*"is not allowed to authenticate"*) ;;
*) fail "authentication disable verification failed rc=$auth_check_rc output=$auth_check" ;;
esac
home_identity=$(/usr/bin/stat -f '%u:%g:%Lp' "$user_home")
[ "$home_identity" = "$user_uid:$user_gid:700" ] || \
	fail "unexpected home identity or mode: $home_identity"
[ -z "$(user_name_for_uid "$controller_uid")" ] || \
	fail "controller UID $controller_uid became occupied on macOS"
[ -z "$(group_name_for_gid "$controller_gid")" ] || \
	fail "controller GID $controller_gid became occupied on macOS"

printf '%s\n' '[macos-user]'
/usr/bin/dscacheutil -q user -a name "$user_name"
printf '%s\n' '[macos-group]'
/usr/bin/dscacheutil -q group -a name "$user_name"
printf '%s\n' '[macos-identity]'
/usr/bin/id "$user_name"
printf 'home=%s identity_mode=%s\n' "$user_home" "$home_identity"
printf 'authentication_check=%s\n' "$auth_check"
printf 'password_login=DISABLED\n'
printf 'controller_identity_on_macos=%s:%s:UNUSED\n' \
	"$controller_uid" "$controller_gid"
printf 'loginwindow_hidden=YES method=HiddenUsersList\n'
printf 'SMD102_MACOS_PROVISION_COMPLETE user=%s uid=%s gid=%s\n' \
	"$user_name" "$user_uid" "$user_gid"
trap - EXIT HUP INT TERM
