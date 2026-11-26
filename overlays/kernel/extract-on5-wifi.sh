#!/bin/sh
set -eu

SSH_TARGET=${SSH_TARGET:-root@192.168.7.2}
OUTPUT_DIR=${OUTPUT_DIR:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/firmware/on5"}
SSH_IDENTITY=${SSH_IDENTITY:-}
SSH_KNOWN_HOSTS=${SSH_KNOWN_HOSTS:-"$HOME/.ssh/known_hosts"}

mkdir -p "$OUTPUT_DIR"
tmp_archive=$(mktemp "$OUTPUT_DIR/wifi.XXXXXX.tar.gz")
trap 'rm -f "$tmp_archive"' EXIT INT TERM

if [ -n "$SSH_IDENTITY" ]; then
	set -- -i "$SSH_IDENTITY" -o IdentitiesOnly=yes
else
	set --
fi

ssh "$@" -o BatchMode=yes -o ConnectTimeout=10 \
	-o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
	-o StrictHostKeyChecking=accept-new "$SSH_TARGET" sh -s <<'EOF' > "$tmp_archive"
set -eu
mount_dir=/tmp/zirarch-system-firmware
mkdir -p "$mount_dir"
mounted=false
cleanup()
{
	[ "$mounted" = false ] || umount "$mount_dir"
	rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ -e "$mount_dir/etc/wifi/bcmdhd_sta.bin" ]; then
	:
else
	mount -o ro /dev/mmcblk0p19 "$mount_dir"
	mounted=true
fi

for file in \
	"$mount_dir/etc/wifi/bcmdhd_sta.bin" \
	"$mount_dir/etc/wifi/nvram_net.txt"
do
	[ -s "$file" ] || {
		echo "missing stock Wi-Fi file: $file" >&2
		exit 1
	}
done

tar -C "$mount_dir" -czf - \
	etc/wifi/bcmdhd_sta.bin \
	etc/wifi/nvram_net.txt
EOF

tar -xzf "$tmp_archive" -C "$OUTPUT_DIR" --strip-components=2
sha256sum \
	"$OUTPUT_DIR/bcmdhd_sta.bin" \
	"$OUTPUT_DIR/nvram_net.txt"
