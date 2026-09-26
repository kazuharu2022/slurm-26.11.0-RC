#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_CREATE_CONTROLLER_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_CREATE_CONTROLLER_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

domain=smd405-controller
guest_hostname=slurmctld-bak
disk=/home/virtimages/node03/smd405-controller.qcow2
seed=/home/virtimages/node03/smd405-controller-seed.iso
install_iso=/home/virtimages/templates/ubuntu-24.04.5-live-server-amd64.iso
expected_iso_sha256=97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8
approved_key_fingerprint='SHA256:Va4B52U2du/kpndyUhPAAlKPcCYCvTu+Vl/9T3S740M'
mac=52:54:00:40:05:01
expected_ctld_pid=197928
expected_dbd_pid=189104
expected_slurmd_pid=1136933
work_dir=
success=0

fail()
{
	printf 'SMD405_CREATE_CONTROLLER_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$work_dir" ] && rm -rf -- "$work_dir" >/dev/null 2>&1 || true
	if [ "$success" -ne 1 ] && virsh dominfo "$domain" >/dev/null 2>&1; then
		state=$(virsh domstate "$domain" 2>/dev/null | tr -d '\r' || true)
		if [ "$state" = running ]; then
			virsh domif-setlink "$domain" "$mac" down >/dev/null 2>&1 || true
			virsh destroy "$domain" >/dev/null 2>&1 || true
		fi
		printf '%s\n' \
			'recovery=failed_domain_stopped_link_down_artifacts_retained' >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
for command in virsh virt-install qemu-img xorriso ssh-keygen openssl \
	sha256sum systemctl scontrol squeue xmllint nc fuser; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ -f "$install_iso" ] || fail 'verified installation ISO is absent'
[ "$(sha256sum "$install_iso" | awk '{print $1}')" = "$expected_iso_sha256" ] || \
	fail 'installation ISO checksum mismatch'
virsh dominfo "$domain" >/dev/null 2>&1 && fail 'domain already exists'
[ ! -e "$disk" ] || fail 'target disk already exists'
[ ! -e "$seed" ] || fail 'NoCloud seed already exists'
[ "$(virsh domstate ubuntu24 | tr -d '\r')" = 'shut off' ] || \
	fail 'existing ubuntu24 VM is not shut off'

if virsh list --all --name | while IFS= read -r candidate_domain; do
	[ -n "$candidate_domain" ] || continue
	virsh domiflist "$candidate_domain" 2>/dev/null | awk 'NR > 2 {print $5}'
done | grep -Fqi "$mac"; then
	fail 'target MAC address is already in use'
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
scontrol ping | grep -Fq 'is UP' || fail 'production controller ping failed'
[ "$(squeue -h | wc -l)" -eq 0 ] || fail 'production queue is not empty'

approved_key=
while IFS= read -r candidate_key; do
	case "$candidate_key" in ssh-ed25519\ *) ;; *) continue ;; esac
	fingerprint=$(printf '%s\n' "$candidate_key" | \
		ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
	if [ "$fingerprint" = "$approved_key_fingerprint" ]; then
		approved_key=$candidate_key
		break
	fi
done </home/REDACTED_USER/.ssh/authorized_keys
[ -n "$approved_key" ] || fail 'approved SSH public key is absent'

work_dir=$(mktemp -d /tmp/smd405-controller.XXXXXX) || \
	fail 'cannot create temporary work directory'
trap cleanup EXIT HUP INT TERM
password_hash=$(openssl rand -base64 48 | openssl passwd -6 -stdin) || \
	fail 'cannot generate random password hash'

{
	printf '%s\n' \
		'#cloud-config' \
		'autoinstall:' \
		'  version: 1' \
		'  locale: en_US.UTF-8' \
		'  keyboard:' \
		'    layout: us' \
		'  refresh-installer:' \
		'    update: false' \
		'  source:' \
		'    id: ubuntu-server-minimal' \
		'    search_drivers: false' \
		'  identity:' \
		'    realname: REDACTED_USER' \
		'    username: REDACTED_USER'
	printf "    password: '%s'\n" "$password_hash"
	printf '%s\n' \
		"    hostname: $guest_hostname" \
		'  ssh:' \
		'    install-server: true' \
		'    allow-pw: false' \
		'    authorized-keys:'
	printf '      - %s\n' "$approved_key"
	printf '%s\n' \
		'  storage:' \
		'    layout:' \
		'      name: direct' \
		'  apt:' \
		'    geoip: false' \
		'    fallback: offline-install' \
		'  updates: security' \
		'  late-commands:' \
		'    - |' \
		'      curtin in-target --target=/target -- sh -c "printf '\''REDACTED_USER ALL=(ALL) NOPASSWD: ALL\n'\'' > /etc/sudoers.d/99-smd405-provision && chmod 0440 /etc/sudoers.d/99-smd405-provision && visudo -cf /etc/sudoers.d/99-smd405-provision"' \
		'    - |' \
		'      curtin in-target --target=/target -- sh -c "mkdir -p /etc/ssh/sshd_config.d && printf '\''PasswordAuthentication no\nKbdInteractiveAuthentication no\n'\'' > /etc/ssh/sshd_config.d/60-smd405-key-only.conf"' \
		'  shutdown: poweroff'
} >"${work_dir}/user-data" || fail 'cannot create NoCloud user-data'
printf '%s\n' \
	"instance-id: smd405-controller-20260924" \
	"local-hostname: $guest_hostname" >"${work_dir}/meta-data" || \
	fail 'cannot create NoCloud meta-data'

xorriso -as mkisofs -quiet -output "$seed" -volid cidata -joliet -rock \
	"${work_dir}/user-data" "${work_dir}/meta-data" || \
	fail 'cannot create NoCloud seed ISO'
chown root:root "$seed" || fail 'cannot set seed ISO owner'
chmod 0600 "$seed" || fail 'cannot set seed ISO mode'
xorriso -indev "$seed" -pvd_info 2>&1 | \
	grep -Eq "^Volume [Ii]d[[:space:]]*:[[:space:]]*'?cidata'?$" || \
	fail 'NoCloud seed volume label mismatch'

qemu-img create -f qcow2 "$disk" 40G || fail 'cannot create target disk'
chown root:root "$disk" || fail 'cannot set target disk owner'
chmod 0600 "$disk" || fail 'cannot set target disk mode'

virt-install --connect qemu:///system \
	--name "$domain" \
	--memory 8192 \
	--vcpus 4 \
	--cpu host-passthrough \
	--os-variant ubuntu24.04 \
	--disk "path=${disk},format=qcow2,bus=virtio,cache=none" \
	--disk "path=${seed},device=cdrom,readonly=on" \
	--location "$install_iso,kernel=casper/vmlinuz,initrd=casper/initrd" \
	--network "bridge=br0,model=virtio,mac=${mac}" \
	--graphics none \
	--console pty,target_type=serial \
	--extra-args 'autoinstall console=ttyS0,115200n8 serial' \
	--noautoconsole \
	--noreboot \
	--wait=-1 || fail 'virt-install failed'
[ "$(virsh domstate "$domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'installed VM did not stop after installation'
virsh autostart "$domain" --disable >/dev/null || fail 'cannot disable autostart'

for medium in "$install_iso" "$seed"; do
	target=$(virsh domblklist "$domain" --inactive --details | \
		awk -v medium="$medium" '$4 == medium {print $3; exit}')
	if [ -n "$target" ]; then
		virsh detach-disk "$domain" "$target" --config >/dev/null || \
			fail "cannot detach installation medium target=$target"
	fi
done
virsh domblklist "$domain" --inactive --details | \
	grep -Fq "$seed" && fail 'NoCloud seed remains attached'
virsh domblklist "$domain" --inactive --details | \
	grep -Fq "$install_iso" && fail 'installation ISO remains attached'
if fuser "$seed" >/dev/null 2>&1; then
	fail 'detached NoCloud seed is still in use'
fi
chown root:root "$seed" || fail 'cannot restore seed ISO owner'
chmod 0600 "$seed" || fail 'cannot restore seed ISO mode'

virsh dominfo "$domain" | grep -Eq '^CPU\(s\):[[:space:]]+4$' || \
	fail 'domain vCPU count mismatch'
virsh dominfo "$domain" | grep -Eq '^Max memory:[[:space:]]+8388608 KiB$' || \
	fail 'domain memory mismatch'
virsh dominfo "$domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'domain autostart is not disabled'
virsh domblklist "$domain" --inactive --details | \
	awk -v disk="$disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'domain target disk mismatch'
virsh domiflist "$domain" --inactive | \
	awk -v mac="$mac" 'tolower($5) == tolower(mac) { found = 1 }
		END { exit !found }' || fail 'domain MAC mismatch'
qemu-img check "$disk" >/dev/null || fail 'target disk consistency check failed'

virsh start "$domain" >/dev/null || fail 'cannot boot installed VM'
attempt=0
ip_address=
while [ -z "$ip_address" ]; do
	ip_address=$(virsh domifaddr "$domain" --source arp 2>/dev/null | \
		awk -v mac="$mac" '
			tolower($2) == tolower(mac) && $3 == "ipv4" {
				sub(/\/.*/, "", $4)
				print $4
				exit
			}')
	if [ -z "$ip_address" ]; then
		ip_address=$(ip neigh show dev br0 | awk -v mac="$mac" '
			tolower($5) == tolower(mac) && $1 ~ /^[0-9]+\./ {
				print $1
				exit
			}')
	fi
	if [ -n "$ip_address" ] && ! nc -z -w 1 "$ip_address" 22; then
		ip_address=
	fi
	[ -n "$ip_address" ] && break
	attempt=$((attempt + 1))
	[ "$attempt" -lt 120 ] || fail 'installed VM did not expose SSH on DHCP address'
	sleep 5
done
case "$ip_address" in
	192.168.10.180|192.168.10.128)
		fail "unsafe DHCP address collision=$ip_address"
		;;
esac

[ "$(systemctl show -p MainPID --value slurmctld)" = "$expected_ctld_pid" ] || \
	fail 'production slurmctld PID changed after VM boot'
[ "$(systemctl show -p MainPID --value slurmdbd)" = "$expected_dbd_pid" ] || \
	fail 'production slurmdbd PID changed after VM boot'
[ "$(systemctl show -p MainPID --value slurmd)" = "$expected_slurmd_pid" ] || \
	fail 'production slurmd PID changed after VM boot'
[ "$(squeue -h | wc -l)" -eq 0 ] || fail 'production queue is not empty after VM boot'

success=1
trap - EXIT HUP INT TERM
rm -rf -- "$work_dir"
work_dir=
printf '%s%s%s%s\n' \
	'SMD405_CREATE_CONTROLLER_COMPLETE' \
	" domain=$domain hostname=$guest_hostname state=running ip=$ip_address" \
	' vcpus=4 memory_mib=8192 disk_gib=40 autostart=disabled' \
	" mac=$mac production_pids_unchanged=PASS queue_empty=PASS"
