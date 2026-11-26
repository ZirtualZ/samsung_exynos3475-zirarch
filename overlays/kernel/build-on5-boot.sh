#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
STOCK_BOOT=${STOCK_BOOT:-"$PROJECT_DIR/inputs/stock-on5-boot.img"}
OUTPUT=${OUTPUT:-"$PROJECT_DIR/builds/zirarch-boot.img"}
CROSS_COMPILE=${CROSS_COMPILE:-"$PROJECT_DIR/arm-eabi-4.8/bin/arm-eabi-"}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
DEBUG_CONSOLE=${DEBUG_CONSOLE:-0}
DEBUG_ADB=${DEBUG_ADB:-0}
ADB_PUBLIC_KEY=${ADB_PUBLIC_KEY:-}
RAMDISK=${RAMDISK:-}
CMDLINE=${CMDLINE:-}

if [ ! -f "$STOCK_BOOT" ]; then
	echo "missing stock boot image: $STOCK_BOOT" >&2
	exit 1
fi

if [ "${SKIP_BUILD:-0}" != 1 ]; then
	make -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
		lineage-on5ltetmo_defconfig
	make -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
		-j"$JOBS" zImage
fi

KERNEL_IMAGE=${KERNEL_IMAGE:-"$KERNEL_DIR/arch/arm/boot/zImage"}
if [ ! -f "$KERNEL_IMAGE" ]; then
	echo "missing kernel image: $KERNEL_IMAGE" >&2
	exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

python3 - "$STOCK_BOOT" "$TMP_DIR/ramdisk" "$TMP_DIR/dtb" "$DEBUG_CONSOLE" <<'PY'
import os
import re
import shutil
import struct
import subprocess
import sys

boot_path, ramdisk_path, dtb_path, debug_console = sys.argv[1:]
with open(boot_path, "rb") as image:
    data = image.read()

if data[:8] != b"ANDROID!":
    raise SystemExit("stock image is not an Android boot image")

kernel_size, _, ramdisk_size, _, second_size, _, _, page_size, dtb_size = \
    struct.unpack_from("<9I", data, 8)
if page_size != 2048 or second_size:
    raise SystemExit("unsupported stock boot image layout")

def pages(size):
    return (size + page_size - 1) // page_size

ramdisk_offset = page_size * (1 + pages(kernel_size))
dtb_offset = page_size * (
    1 + pages(kernel_size) + pages(ramdisk_size)
)
if dtb_size == 0 or len(data) < dtb_offset + dtb_size:
    raise SystemExit("stock image has no usable Samsung DTB container")

with open(ramdisk_path, "wb") as out:
    out.write(data[ramdisk_offset:ramdisk_offset + ramdisk_size])
with open(dtb_path, "wb") as out:
    out.write(data[dtb_offset:dtb_offset + dtb_size])

if debug_console == "1":
    if not shutil.which("dtc"):
        raise SystemExit("DEBUG_CONSOLE=1 requires dtc")

    dtb = bytearray(data[dtb_offset:dtb_offset + dtb_size])
    count = struct.unpack_from("<I", dtb, 8)[0]
    for index in range(count):
        entry = 0x20 + index * 0x20
        offset, size = struct.unpack_from("<2I", dtb, entry)
        old_blob = bytes(dtb[offset:offset + size])
        work = os.path.join(os.path.dirname(dtb_path), "dtb-%d" % index)
        old_path = work + ".old"
        dts_path = work + ".dts"
        new_path = work + ".new"
        with open(old_path, "wb") as out:
            out.write(old_blob)
        with open(dts_path, "w") as out:
            subprocess.run(
                ["dtc", "-I", "dtb", "-O", "dts", old_path],
                check=True, stdout=out,
            )
        source = open(dts_path).read()
        debug_args = (
            " console=tty0 consoleblank=0 fbcon=map:0"
            " loglevel=8 ignore_loglevel initcall_debug"
        )
        source, changed = re.subn(
            r'(\sbootargs\s*=\s*")([^"]*)(";\s*)',
            lambda match: match.group(1) + match.group(2) + debug_args
            + match.group(3),
            source,
            count=1,
        )
        if changed != 1:
            raise SystemExit("DTB %d has no /chosen/bootargs" % index)
        with open(dts_path, "w") as out:
            out.write(source)
        subprocess.run(
            ["dtc", "-I", "dts", "-O", "dtb", "-o", new_path, dts_path],
            check=True,
        )
        new_blob = open(new_path, "rb").read()
        if len(new_blob) > size:
            raise SystemExit("debug DTB %d grew beyond its Samsung slot" % index)
        dtb[offset:offset + size] = new_blob.ljust(size, b"\0")

    with open(dtb_path, "wb") as out:
        out.write(dtb)
PY

if [ -n "$RAMDISK" ]; then
	cp "$RAMDISK" "$TMP_DIR/ramdisk"
fi

if [ "$DEBUG_ADB" = 1 ]; then
	RAMDISK_DIR="$TMP_DIR/ramdisk-unpacked"
	mkdir "$RAMDISK_DIR"
	(
		cd "$RAMDISK_DIR"
		gzip -dc "$TMP_DIR/ramdisk" | cpio -idm --quiet --no-preserve-owner || true
		chmod u+rwx .subackup 2>/dev/null || true
		find . -type d -exec chmod u+rwx {} +
		sed -i \
			-e 's/^ro.secure=.*/ro.secure=0/' \
			-e 's/^ro.debuggable=.*/ro.debuggable=1/' \
			-e 's/^ro.adb.secure=.*/ro.adb.secure=0/' \
			-e 's/^persist.sys.usb.config=.*/persist.sys.usb.config=mtp,adb/' \
			"$RAMDISK_DIR/default.prop"
		printf '\npersist.service.adb.enable=1\n' >> "$RAMDISK_DIR/default.prop"
		cat >> "$RAMDISK_DIR/init.rc" <<'EOF'

on early-init
    setprop ro.secure 0
    setprop ro.debuggable 1
    setprop ro.adb.secure 0
    setenforce 0

service adb_key_sync /system/bin/sh -c "mkdir -p /data/misc/adb; cp /adb_keys /data/misc/adb/adb_keys; chmod 600 /data/misc/adb/adb_keys; chown 0 0 /data/misc/adb/adb_keys; stop adbd; start adbd"
    class main
    disabled
    oneshot
    seclabel u:r:su:s0
EOF
		cat >> "$RAMDISK_DIR/init.universal3475.rc" <<'EOF'

on boot
    setprop persist.sys.usb.config mtp,adb
    setprop sys.usb.config mtp,adb

on post-fs-data
    start adb_key_sync
EOF
		if [ -n "$ADB_PUBLIC_KEY" ]; then
			cat "$ADB_PUBLIC_KEY" > "$RAMDISK_DIR/adb_keys"
			chmod 600 "$RAMDISK_DIR/adb_keys"
		fi
		find . -print0 | cpio --null -o -H newc --owner=0:0 --quiet | gzip -9 > "$TMP_DIR/ramdisk-debug"
	)
	mv "$TMP_DIR/ramdisk-debug" "$TMP_DIR/ramdisk"
fi

BOARD=$(python3 - "$STOCK_BOOT" <<'PY'
import sys
data = open(sys.argv[1], "rb").read(64)
print(data[48:64].split(b"\0", 1)[0].decode("ascii"))
PY
)

mkbootimg \
	--kernel "$KERNEL_IMAGE" \
	--ramdisk "$TMP_DIR/ramdisk" \
	--pagesize 2048 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--tags_offset 0x00000100 \
	--board "$BOARD" \
	--cmdline "$CMDLINE" \
	-o "$TMP_DIR/boot.img"

python3 - "$TMP_DIR/boot.img" "$TMP_DIR/dtb" "$OUTPUT" <<'PY'
import os
import struct
import sys

image_path, dtb_path, output_path = sys.argv[1:]
image = bytearray(open(image_path, "rb").read())
dtb = open(dtb_path, "rb").read()

if image[:8] != b"ANDROID!":
    raise SystemExit("mkbootimg did not produce an Android boot image")

_, _, ramdisk_size, _, _, _, _, page_size = struct.unpack_from("<8I", image, 8)
dtb_offset = page_size * (
    1 + ((struct.unpack_from("<I", image, 8)[0] + page_size - 1) // page_size)
    + ((ramdisk_size + page_size - 1) // page_size)
)
if len(image) != dtb_offset:
    raise SystemExit("unexpected boot image layout")

# Samsung's On5 bootloader expects the legacy dt_size field and DTBH blob.
struct.pack_into("<I", image, 40, len(dtb))
struct.pack_into("<I", image, 28, 0x10F00000)
image.extend(dtb)
image.extend(b"SEANDROIDENFORCE\0")

os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
with open(output_path, "wb") as out:
    out.write(image)
PY

echo "kernel release: $(make -s -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)"
echo "boot image: $OUTPUT"
