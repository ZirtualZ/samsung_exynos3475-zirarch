#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
ROOTFS_ARCHIVE=${ROOTFS_ARCHIVE:-"$PROJECT_DIR/builds/zirarch-native-rootfs.tar.gz"}
WORK_DIR=${WORK_DIR:-"$PROJECT_DIR/builds/native-alpine-rootfs"}
ROOT_DIR=${ROOT_DIR:-"$WORK_DIR/image-root"}
OUTPUT=${OUTPUT:-"$PROJECT_DIR/builds/zirarch-alpine-system.img"}
SYSTEM_BYTES=${SYSTEM_BYTES:-3061841920}
LABEL=${LABEL:-SYSTEM}

rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"
tar -xzf "$ROOTFS_ARCHIVE" -C "$ROOT_DIR"

rm -f "$OUTPUT"
truncate -s "$SYSTEM_BYTES" "$OUTPUT"
mke2fs -q -F -t ext4 -L "$LABEL" \
	-O ^64bit,^metadata_csum -d "$ROOT_DIR" "$OUTPUT"

DEBUGFS_COMMANDS="$WORK_DIR/debugfs-root-ownership"
mkdir -p "$WORK_DIR"
{
	echo "set_inode_field / uid 0"
	echo "set_inode_field / gid 0"
	find "$ROOT_DIR" -mindepth 1 -print |
		sed "s#^$ROOT_DIR##" |
		while IFS= read -r path; do
			echo "set_inode_field $path uid 0"
			echo "set_inode_field $path gid 0"
		done
} > "$DEBUGFS_COMMANDS"
debugfs -w -f "$DEBUGFS_COMMANDS" "$OUTPUT" >/dev/null 2>&1

e2fsck -pf "$OUTPUT"
sha256sum "$OUTPUT"
echo "native system image: $OUTPUT"
du -h "$OUTPUT"
ls -lh "$OUTPUT"
