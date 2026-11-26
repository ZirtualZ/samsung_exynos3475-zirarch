#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
STOCK_KERNEL=${STOCK_KERNEL:-"$PROJECT_DIR/boot-work/stock-correct/kernel"}
BUSYBOX=${BUSYBOX:-"$PROJECT_DIR/builds/minimal/busybox-armv7l"}
INIT_SCRIPT=${INIT_SCRIPT:-"$KERNEL_DIR/initramfs-on5/init-persistent"}
WORK_DIR=${WORK_DIR:-"$PROJECT_DIR/builds/persistent"}
OUTPUT=${OUTPUT:-"$PROJECT_DIR/builds/zirarch-persistent-boot.img"}
DEBUG_CONSOLE=${DEBUG_CONSOLE:-1}
ROOTFS_ARCHIVE=${ROOTFS_ARCHIVE:-"$PROJECT_DIR/builds/zirarch-rootfs.tar.gz"}
WIFI_FIRMWARE_DIR=${WIFI_FIRMWARE_DIR:-"$KERNEL_DIR/firmware/on5"}

mkdir -p "$WORK_DIR"

for firmware in bcmdhd_sta.bin nvram_net.txt; do
	[ -s "$WIFI_FIRMWARE_DIR/$firmware" ] || {
		echo "missing SM-G550T Wi-Fi firmware: $WIFI_FIRMWARE_DIR/$firmware" >&2
		echo "extract it with kernel/extract-on5-wifi.sh" >&2
		exit 1
	}
done
for firmware in \
	./vendor/etc/wifi/bcmdhd_sta.bin \
	./vendor/etc/wifi/nvram_net.txt
do
	tar -tzf "$ROOTFS_ARCHIVE" "$firmware" >/dev/null 2>&1 || {
		echo "rootfs is missing Wi-Fi firmware: $firmware" >&2
		echo "run kernel/prepare-on5-rootfs.sh after stock firmware extraction" >&2
		exit 1
	}
done

if [ ! -f "$BUSYBOX" ]; then
	"$KERNEL_DIR/build-on5-minimal.sh"
fi
[ -f "$STOCK_KERNEL" ] || {
	echo "missing stock kernel: $STOCK_KERNEL" >&2
	exit 1
}

cat > "$WORK_DIR/initramfs.list" <<EOF
dir /bin 0755 0 0
dir /cache 0755 0 0
dir /data 0755 0 0
dir /dev 0755 0 0
dir /proc 0755 0 0
dir /run 0755 0 0
dir /sbin 0755 0 0
dir /sys 0755 0 0
dir /vendor 0755 0 0
dir /vendor/etc 0755 0 0
dir /vendor/etc/wifi 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
file /bin/busybox $BUSYBOX 0755 0 0
file /init $INIT_SCRIPT 0755 0 0
file /vendor/etc/wifi/bcmdhd_sta.bin $WIFI_FIRMWARE_DIR/bcmdhd_sta.bin 0644 0 0
file /vendor/etc/wifi/nvram_net.txt $WIFI_FIRMWARE_DIR/nvram_net.txt 0644 0 0
slink /bin/sh busybox 0755 0 0
EOF

"$KERNEL_DIR/usr/gen_init_cpio" "$WORK_DIR/initramfs.list" |
	gzip -9 > "$WORK_DIR/initramfs.cpio.gz"

SKIP_BUILD=1 \
KERNEL_IMAGE="$STOCK_KERNEL" \
RAMDISK="$WORK_DIR/initramfs.cpio.gz" \
CMDLINE="console=tty0 console=ttySAC2,115200 consoleblank=0 loglevel=4 androidboot.selinux=permissive" \
DEBUG_CONSOLE="$DEBUG_CONSOLE" \
DEBUG_ADB=0 \
OUTPUT="$OUTPUT" \
	"$KERNEL_DIR/build-on5-boot.sh"

echo "persistent boot image: $OUTPUT"
