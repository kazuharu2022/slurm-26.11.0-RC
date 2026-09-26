#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_ROLLBACK_CLONE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_ROLLBACK_CLONE_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

source_domain=ubuntu24
source_uuid=81cca873-2c1b-4225-83db-1f1deef925cd
source_disk=/home/virtimages/node03/ubuntu24.04
clone_domain=smd405-backup
clone_uuid=67757283-8233-42d2-80e2-0c7cdc1fc3eb
clone_disk=/home/virtimages/node03/smd405-backup.qcow2
clone_mac=52:54:00:40:05:01

fail()
{
	printf 'SMD405_ROLLBACK_CLONE_FAILED error=%s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh qemu-img xmllint; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done

[ "$(virsh domuuid "$source_domain")" = "$source_uuid" ] || \
	fail 'source VM UUID mismatch'
[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM is not shut off'
[ -f "$source_disk" ] || fail 'source disk is absent'
[ -f "$clone_disk" ] || fail 'clone overlay is absent'
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM is not shut off'
[ "$(virsh domuuid "$clone_domain")" = "$clone_uuid" ] || \
	fail 'clone VM UUID mismatch'
virsh dominfo "$clone_domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'clone autostart is not disabled'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'persistent clone interface is not down'
virsh domblklist "$clone_domain" --details | \
	awk -v disk="$clone_disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'clone disk definition mismatch'
qemu-img info --output=json "$clone_disk" | \
	grep -Fq "\"backing-filename\": \"$source_disk\"" || \
	fail 'clone overlay backing file mismatch'
if fuser "$clone_disk" "$source_disk" >/dev/null 2>&1; then
	fail 'source or clone disk is in use'
fi

virsh undefine "$clone_domain" || fail 'cannot undefine clone domain'
[ ! -e "$clone_disk" ] || rm -f -- "$clone_disk" || \
	fail 'cannot remove clone overlay'
if virsh dominfo "$clone_domain" >/dev/null 2>&1; then
	fail 'clone domain still exists'
fi
[ ! -e "$clone_disk" ] || fail 'clone overlay still exists'
[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM state changed'
[ "$(stat -c '%U:%G:%a' "$source_disk")" = 'root:root:600' ] || \
	fail 'source disk metadata changed'

printf '%s\n' \
	'SMD405_ROLLBACK_CLONE_COMPLETE clone_domain=ABSENT clone_overlay=ABSENT source_vm_unchanged=PASS'
