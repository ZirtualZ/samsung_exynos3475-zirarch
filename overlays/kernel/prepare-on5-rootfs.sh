#!/bin/sh
set -eu

KERNEL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$KERNEL_DIR/.." && pwd)
WORK_DIR=${WORK_DIR:-"$PROJECT_DIR/builds/alpine-rootfs"}
ROOT_DIR="$WORK_DIR/root"
TOOLS_DIR="$WORK_DIR/tools"
ALPINE_VERSION=${ALPINE_VERSION:-3.22}
ALPINE_RELEASE=${ALPINE_RELEASE:-3.22.8}
APK_STATIC_VERSION=${APK_STATIC_VERSION:-2.14.13-r0}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ROOTFS_ARCHIVE="$WORK_DIR/alpine-minirootfs-$ALPINE_RELEASE-armv7.tar.gz"
APK_STATIC_ARCHIVE="$WORK_DIR/apk-tools-static-$APK_STATIC_VERSION.apk"
ROOTFS_SHA256=a641f002abf617db94379110ffa798e0ed9903dbcec2bb1caa79df1fc7af8e8c
APK_STATIC_SHA256=d78d2a9ebadc8179b3b9063c3316e948f594c833db51eaeabe67f1d044245527
WIFI_FIRMWARE_DIR=${WIFI_FIRMWARE_DIR:-"$KERNEL_DIR/firmware/on5"}

for firmware in bcmdhd_sta.bin nvram_net.txt; do
	[ -s "$WIFI_FIRMWARE_DIR/$firmware" ] || {
		echo "missing SM-G550T Wi-Fi firmware: $WIFI_FIRMWARE_DIR/$firmware" >&2
		echo "extract it with kernel/extract-on5-wifi.sh" >&2
		exit 1
	}
done

rm -rf "$ROOT_DIR" "$TOOLS_DIR"
mkdir -p "$ROOT_DIR" "$TOOLS_DIR"

if [ ! -f "$ROOTFS_ARCHIVE" ]; then
	curl -fL --retry 2 -o "$ROOTFS_ARCHIVE" \
		"$MIRROR/v$ALPINE_VERSION/releases/armv7/alpine-minirootfs-$ALPINE_RELEASE-armv7.tar.gz"
fi
if [ ! -f "$APK_STATIC_ARCHIVE" ]; then
	curl -fL --retry 2 -o "$APK_STATIC_ARCHIVE" \
		"$MIRROR/v$ALPINE_VERSION/main/x86_64/apk-tools-static-$APK_STATIC_VERSION.apk"
fi

printf '%s  %s\n' "$ROOTFS_SHA256" "$ROOTFS_ARCHIVE" | sha256sum -c -
printf '%s  %s\n' "$APK_STATIC_SHA256" "$APK_STATIC_ARCHIVE" | sha256sum -c -

tar -xzf "$ROOTFS_ARCHIVE" -C "$ROOT_DIR"
tar -xf "$APK_STATIC_ARCHIVE" -C "$TOOLS_DIR"
mkdir -p "$ROOT_DIR/usr/bin" "$ROOT_DIR/etc/init.d"
cp "$PROJECT_DIR/builds/zirarch-fbconsole" "$ROOT_DIR/usr/bin/"
install -m 755 "$KERNEL_DIR/wifi" "$ROOT_DIR/usr/bin/wifi"
mkdir -p "$ROOT_DIR/vendor/etc/wifi"
install -m 644 "$WIFI_FIRMWARE_DIR/bcmdhd_sta.bin" \
	"$ROOT_DIR/vendor/etc/wifi/bcmdhd_sta.bin"
install -m 644 "$WIFI_FIRMWARE_DIR/nvram_net.txt" \
	"$ROOT_DIR/vendor/etc/wifi/nvram_net.txt"
install -m 755 "$KERNEL_DIR/fbconsole/screen-console.initd" \
	"$ROOT_DIR/etc/init.d/screen-console"
mkdir -p "$ROOT_DIR/etc/apk" "$ROOT_DIR/etc/runlevels"
cat > "$ROOT_DIR/etc/apk/repositories" <<EOF
$MIRROR/v$ALPINE_VERSION/main
$MIRROR/v$ALPINE_VERSION/community
EOF

"$TOOLS_DIR/sbin/apk.static" \
	--root "$ROOT_DIR" \
	--arch armv7 \
	--initdb \
	--no-scripts \
	--repositories-file "$ROOT_DIR/etc/apk/repositories" \
	add alpine-baselayout openrc dropbear dropbear-openrc \
		wpa_supplicant wpa_supplicant-openrc

cat > "$ROOT_DIR/etc/hostname" <<EOF
on5-pmos
EOF

cat > "$ROOT_DIR/etc/hosts" <<EOF
127.0.0.1 localhost localhost.localdomain
127.0.1.1 on5-pmos
::1 localhost localhost.localdomain
EOF

cat > "$ROOT_DIR/etc/inittab" <<EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

ttySAC2::respawn:/sbin/getty -L 115200 ttySAC2 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

cat > "$ROOT_DIR/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto rndis0
iface rndis0 inet static
	address 192.168.7.2
	netmask 255.255.255.0

auto wlan0
iface wlan0 inet manual
EOF

mkdir -p "$ROOT_DIR/etc/wpa_supplicant"
cat > "$ROOT_DIR/etc/wpa_supplicant/wpa_supplicant.conf" <<'EOF'
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
EOF
chmod 600 "$ROOT_DIR/etc/wpa_supplicant/wpa_supplicant.conf"

cat > "$ROOT_DIR/etc/init.d/usb-gadget" <<'EOF'
#!/sbin/openrc-run

description="Expose an ACM serial console and RNDIS network interface"

depend()
{
	need devfs
	before networking
}

start()
{
	local gadget=/sys/class/android_usb/android0
	[ -d "$gadget" ] || return 1
	ebegin "Starting Samsung USB gadget"
	echo 0 > "$gadget/enable"
	echo rndis,acm > "$gadget/functions"
	echo 0x6863 > "$gadget/idProduct"
	echo 1 > "$gadget/enable"
	eend $?
}

stop()
{
	echo 0 > /sys/class/android_usb/android0/enable 2>/dev/null || true
}
EOF
chmod 755 "$ROOT_DIR/etc/init.d/usb-gadget"

cat > "$ROOT_DIR/etc/init.d/wifi-link" <<'EOF'
#!/sbin/openrc-run

description="Bring up the Broadcom Wi-Fi interface"

depend()
{
	need devfs modules
	before wpa_supplicant networking
}

start()
{
	[ -d /sys/class/net/wlan0 ] || {
		eerror "wlan0 is missing; check bcmdhd firmware in /vendor/etc/wifi"
		return 1
	}
	ebegin "Bringing up wlan0"
	ip link set wlan0 up
	eend $?
}

stop()
{
	ip link set wlan0 down 2>/dev/null || true
}
EOF
chmod 755 "$ROOT_DIR/etc/init.d/wifi-link"

for runlevel in sysinit boot default shutdown; do
	mkdir -p "$ROOT_DIR/etc/runlevels/$runlevel"
done
for service in devfs dmesg mdev procfs sysfs; do
	[ -e "$ROOT_DIR/etc/init.d/$service" ] &&
		ln -sfn "/etc/init.d/$service" "$ROOT_DIR/etc/runlevels/sysinit/$service"
done
for service in bootmisc hostname hwclock localmount modules root sysctl urandom; do
	[ -e "$ROOT_DIR/etc/init.d/$service" ] &&
		ln -sfn "/etc/init.d/$service" "$ROOT_DIR/etc/runlevels/boot/$service"
done
for service in loopback usb-gadget wifi-link wpa_supplicant screen-console \
	networking dropbear; do
	ln -sfn "/etc/init.d/$service" "$ROOT_DIR/etc/runlevels/default/$service"
done
for service in killprocs mount-ro savecache; do
	[ -e "$ROOT_DIR/etc/init.d/$service" ] &&
		ln -sfn "/etc/init.d/$service" "$ROOT_DIR/etc/runlevels/shutdown/$service"
done

sed -i 's/^root:\*:/root::/' "$ROOT_DIR/etc/shadow"
cat > "$ROOT_DIR/etc/motd" <<'EOF'
Zirarch postmarketOS-oriented Alpine/OpenRC preview

USB ACM console: ttyGS0 / host ttyACM0
RNDIS address: 192.168.7.2
Android /data is retained outside this chroot.
EOF

tar \
	--numeric-owner \
	--owner=0 \
	--group=0 \
	-C "$ROOT_DIR" \
	-czf "$PROJECT_DIR/builds/zirarch-rootfs.tar.gz" \
	.

echo "rootfs: $PROJECT_DIR/builds/zirarch-rootfs.tar.gz"
du -h "$PROJECT_DIR/builds/zirarch-rootfs.tar.gz"
