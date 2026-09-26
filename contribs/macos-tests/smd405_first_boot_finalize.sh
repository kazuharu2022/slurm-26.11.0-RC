#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_FIRST_BOOT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_FIRST_BOOT_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

source_domain=ubuntu24
clone_domain=smd405-backup
clone_uuid=67757283-8233-42d2-80e2-0c7cdc1fc3eb
clone_mac=52:54:00:40:05:01
expected_ctld_pid=197928
expected_dbd_pid=189104
expected_slurmd_pid=1136933
fallback_shutdown=0

fail()
{
	printf 'SMD405_FIRST_BOOT_FINALIZE_FAILED error=%s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh xmllint systemctl; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ "$(virsh domuuid "$clone_domain")" = "$clone_uuid" ] || \
	fail 'clone UUID mismatch'

attempt=0
while [ "$(virsh domstate "$clone_domain" | tr -d '\r')" != 'shut off' ]; do
	attempt=$((attempt + 1))
	if [ "$attempt" -eq 60 ]; then
		virsh domif-setlink "$clone_domain" "$clone_mac" down >/dev/null 2>&1 || true
		virsh shutdown "$clone_domain" >/dev/null 2>&1 || true
		fallback_shutdown=1
	fi
	if [ "$attempt" -ge 120 ]; then
		virsh domif-setlink "$clone_domain" "$clone_mac" down >/dev/null 2>&1 || true
		fail 'clone did not shut down; left running with live link down'
	fi
	sleep 1
done
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM is not shut off'
[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM is not shut off'
virsh dominfo "$clone_domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'clone autostart is not disabled'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'persistent clone interface is not down'
if fuser /home/virtimages/node03/ubuntu24.04 \
	/home/virtimages/node03/smd405-backup.qcow2 >/dev/null 2>&1; then
	fail 'source or clone disk is still in use'
fi

[ "$(systemctl show -p MainPID --value slurmctld)" = "$expected_ctld_pid" ] || \
	fail 'production slurmctld PID changed'
[ "$(systemctl show -p MainPID --value slurmdbd)" = "$expected_dbd_pid" ] || \
	fail 'production slurmdbd PID changed'
[ "$(systemctl show -p MainPID --value slurmd)" = "$expected_slurmd_pid" ] || \
	fail 'production slurmd PID changed'
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || \
		fail "production service is not active: $service"
done

printf '%s%s%s\n' \
	'SMD405_FIRST_BOOT_FINALIZE_COMPLETE' \
	" domain=$clone_domain state=shut_off persistent_link=down" \
	" fallback_shutdown=$fallback_shutdown source_vm_unchanged=PASS production_pids_unchanged=PASS"
