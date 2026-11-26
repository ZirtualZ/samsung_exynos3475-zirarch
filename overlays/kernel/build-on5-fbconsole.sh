#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
SOURCE="$KERNEL_DIR/fbconsole/fbconsole.c"
FONT_SOURCE=${FONT_SOURCE:-/usr/share/kbd/consolefonts/default8x16.psfu.gz}
OUTPUT=${OUTPUT:-"$PROJECT_DIR/builds/zirarch-fbconsole"}
WORK_DIR="$PROJECT_DIR/builds/fbconsole"
MUSL_VERSION=${MUSL_VERSION:-1.2.5-r13}
MUSL_ARCHIVE="$WORK_DIR/musl-dev-$MUSL_VERSION.apk"
COMPILER_RT_VERSION=${COMPILER_RT_VERSION:-20.1.8-r0}
COMPILER_RT_ARCHIVE="$WORK_DIR/compiler-rt-$COMPILER_RT_VERSION.apk"
MUSL_ARCHIVE_RUNTIME="$WORK_DIR/musl-$MUSL_VERSION.apk"
TOOLCHAIN=${TOOLCHAIN:-"$PROJECT_DIR/arm-eabi-4.8"}

[ -f "$FONT_SOURCE" ] || {
	echo "missing console font: $FONT_SOURCE" >&2
	exit 1
}

mkdir -p "$WORK_DIR/sysroot"
if [ ! -f "$MUSL_ARCHIVE" ]; then
	curl -fL --retry 2 -o "$MUSL_ARCHIVE" \
		"https://dl-cdn.alpinelinux.org/alpine/v3.22/main/armv7/musl-dev-$MUSL_VERSION.apk"
fi
if [ ! -f "$COMPILER_RT_ARCHIVE" ]; then
	curl -fL --retry 2 -o "$COMPILER_RT_ARCHIVE" \
		"https://dl-cdn.alpinelinux.org/alpine/v3.22/main/armv7/compiler-rt-$COMPILER_RT_VERSION.apk"
fi
if [ ! -f "$MUSL_ARCHIVE_RUNTIME" ]; then
	curl -fL --retry 2 -o "$MUSL_ARCHIVE_RUNTIME" \
		"https://dl-cdn.alpinelinux.org/alpine/v3.22/main/armv7/musl-$MUSL_VERSION.apk"
fi
if [ ! -f "$WORK_DIR/sysroot/usr/lib/libc.a" ]; then
	tar -xf "$MUSL_ARCHIVE" -C "$WORK_DIR/sysroot"
fi
tar -xf "$MUSL_ARCHIVE_RUNTIME" -C "$WORK_DIR/sysroot"
if [ ! -f "$WORK_DIR/sysroot/usr/lib/clang/libclang_rt.builtins-armhf.a" ]; then
	tar -tf "$COMPILER_RT_ARCHIVE" | grep 'libclang_rt.builtins-armhf.a$' |
		head -1 > "$WORK_DIR/compiler-rt.path"
	mkdir -p "$WORK_DIR/sysroot/usr/lib/clang"
	tar -xf "$COMPILER_RT_ARCHIVE" -C "$WORK_DIR/sysroot" \
		"$(cat "$WORK_DIR/compiler-rt.path")"
	cp "$WORK_DIR/sysroot/$(cat "$WORK_DIR/compiler-rt.path")" \
		"$WORK_DIR/sysroot/usr/lib/clang/libclang_rt.builtins-armhf.a"
fi

gzip -dc "$FONT_SOURCE" > "$WORK_DIR/font.psf"
python3 - "$WORK_DIR/font.psf" "$KERNEL_DIR/fbconsole/font-8x16.h" <<'PY'
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
if data[:4] != bytes((0x72, 0xB5, 0x4A, 0x86)):
    raise SystemExit("unsupported PSF font")
height, flags = struct.unpack_from("<IB", data, 24)
if height != 16:
    raise SystemExit("expected 8x16 font")
glyphs = data[32:32 + 256 * 16]
with open(sys.argv[2], "w") as out:
    out.write("#include <stdint.h>\nstatic const uint8_t font_8x16[4096] = {\n")
    for offset in range(0, len(glyphs), 16):
        out.write("    " + ", ".join(f"0x{x:02x}" for x in glyphs[offset:offset+16]) + ",\n")
    out.write("};\n")
PY

clang \
	-target armv7-linux-musleabihf \
	--sysroot "$WORK_DIR/sysroot" \
	-fno-ident -Os -fPIE -fno-stack-protector \
	-ffunction-sections -fdata-sections \
	-c "$SOURCE" -o "$WORK_DIR/fbconsole.o"

"$TOOLCHAIN/bin/arm-eabi-ld" \
	-pie --dynamic-linker /lib/ld-musl-armhf.so.1 \
	"$WORK_DIR/sysroot/usr/lib/Scrt1.o" \
	"$WORK_DIR/sysroot/usr/lib/crti.o" \
	"$WORK_DIR/fbconsole.o" \
	"$WORK_DIR/sysroot/lib/ld-musl-armhf.so.1" \
	"$WORK_DIR/sysroot/usr/lib/clang/libclang_rt.builtins-armhf.a" \
	"$WORK_DIR/sysroot/usr/lib/crtn.o" \
	--gc-sections \
	-o "$OUTPUT"

file "$OUTPUT"
