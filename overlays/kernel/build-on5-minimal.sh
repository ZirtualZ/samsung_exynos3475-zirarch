#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
BUSYBOX=${BUSYBOX:-"$PROJECT_DIR/builds/minimal/busybox-armv7l"}
OUTPUT=${OUTPUT:-"$PROJECT_DIR/builds/zirarch-minimal-boot.img"}
WORK_DIR="$PROJECT_DIR/builds/minimal"
BUSYBOX_URL=https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv7l

mkdir -p "$WORK_DIR"
if [ ! -f "$BUSYBOX" ]; then
	curl -fL --retry 2 -o "$BUSYBOX" "$BUSYBOX_URL"
	chmod 755 "$BUSYBOX"
fi

file "$BUSYBOX" | grep -q 'ELF 32-bit.*ARM.*statically linked' || {
	echo "BUSYBOX must be a statically linked 32-bit ARM executable: $BUSYBOX" >&2
	exit 1
}

if [ "${BUSYBOX_ONLY:-0}" = 1 ]; then
	echo "static ARM BusyBox: $BUSYBOX"
	exit 0
fi

cat > "$WORK_DIR/initramfs.list" <<EOF
dir /bin 0755 0 0
dir /cache 0755 0 0
dir /dev 0755 0 0
dir /etc 0755 0 0
dir /proc 0755 0 0
dir /root 0700 0 0
dir /run 0755 0 0
dir /sbin 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
file /bin/busybox $BUSYBOX 0755 0 0
file /init $KERNEL_DIR/initramfs-on5/init 0755 0 0
file /etc/passwd $KERNEL_DIR/initramfs-on5/passwd 0644 0 0
slink /bin/sh busybox 0755 0 0
EOF

"$KERNEL_DIR/usr/gen_init_cpio" "$WORK_DIR/initramfs.list" |
	gzip -9 > "$WORK_DIR/initramfs.cpio.gz"

RAMDISK="$WORK_DIR/initramfs.cpio.gz" \
DEBUG_CONSOLE=1 \
DEBUG_ADB=0 \
CMDLINE="console=tty0 console=ttySAC2,115200 consoleblank=0 fbcon=map:0 loglevel=7 ignore_loglevel initcall_debug" \
OUTPUT="$OUTPUT" \
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}" \
	"$KERNEL_DIR/build-on5-boot.sh"

echo "minimal boot image: $OUTPUT"
echo "This image uses RAM only and does not modify Android partitions."
