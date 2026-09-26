#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_ISO_DOWNLOAD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_ISO_DOWNLOAD_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

release=24.04.5
filename="ubuntu-${release}-live-server-amd64.iso"
expected_sha256=97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8
checksum_base_url=https://releases.ubuntu.com/24.04
iso_base_url=https://ftp.riken.jp/Linux/ubuntu-releases/releases/24.04.5
template_dir=/home/virtimages/templates
iso="${template_dir}/${filename}"
partial="${iso}.part"
sums="${template_dir}/ubuntu-${release}-SHA256SUMS"
sums_partial="${sums}.part"

fail()
{
	printf 'SMD405_ISO_DOWNLOAD_FAILED error=%s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
for command in curl sha256sum awk stat df; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ -d "$template_dir" ] || fail 'template directory is absent'

if [ -f "$iso" ]; then
	actual_sha256=$(sha256sum "$iso" | awk '{print $1}') || \
		fail 'cannot hash existing ISO'
	[ "$actual_sha256" = "$expected_sha256" ] || \
		fail "existing ISO checksum mismatch actual=$actual_sha256"
	printf '%s%s%s\n' \
		'SMD405_ISO_DOWNLOAD_COMPLETE' \
		" release=$release source=existing" \
		" sha256=$actual_sha256 size=$(stat -c %s "$iso")"
	exit 0
fi

available_kib=$(df -Pk "$template_dir" | awk 'NR == 2 {print $4}') || \
	fail 'cannot determine free space'
[ "${available_kib:-0}" -ge 6291456 ] || fail 'less than 6 GiB free space'

	curl --fail --location --silent --show-error \
	--output "$sums_partial" "${checksum_base_url}/SHA256SUMS" || \
	fail 'cannot download official SHA256SUMS'
official_sha256=$(awk -v name="$filename" '$2 == "*" name {print $1}' \
	"$sums_partial") || fail 'cannot parse official SHA256SUMS'
[ "$official_sha256" = "$expected_sha256" ] || \
	fail "official checksum changed actual=${official_sha256:-missing}"
mv "$sums_partial" "$sums" || fail 'cannot install SHA256SUMS file'
chown root:root "$sums" || fail 'cannot set SHA256SUMS owner'
chmod 0644 "$sums" || fail 'cannot set SHA256SUMS mode'

curl --fail --location --silent --show-error --continue-at - \
	--output "$partial" "${iso_base_url}/${filename}" || \
	fail 'ISO download failed; resumable partial retained'
actual_sha256=$(sha256sum "$partial" | awk '{print $1}') || \
	fail 'cannot hash downloaded ISO'
[ "$actual_sha256" = "$expected_sha256" ] || \
	fail "downloaded ISO checksum mismatch actual=$actual_sha256"
mv "$partial" "$iso" || fail 'cannot install verified ISO'
chown root:root "$iso" || fail 'cannot set ISO owner'
chmod 0644 "$iso" || fail 'cannot set ISO mode'

printf '%s%s%s\n' \
	'SMD405_ISO_DOWNLOAD_COMPLETE' \
	" release=$release source=download" \
	" sha256=$actual_sha256 size=$(stat -c %s "$iso")"
