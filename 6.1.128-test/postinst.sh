#!/bin/bash
# Deploys the kernel built by ./build.sh (left loose in ./pkg, no .deb here)
# onto the BOOTPART/rootpart SD card: backs up the previous BOOTPART state,
# installs the kernel/dtb/modules, builds an initrd by chrooting into
# rootpart (via qemu-arm-static/binfmt), and wires up the with-initrd
# u-boot boot template.
#
# Adapted from ../deb/6.1.177/postinst.sh: this branch's build.sh does not
# produce a .deb, does not run dtbs_install (so ./pkg/dtb/ would be
# incomplete — dtbs are pulled straight from the built kernel source tree
# instead), and its kver suffix is "-stb-m8x" rather than "-m8x-armhf".
# Unlike 6.18, this kernel's arch/arm/boot/dts/ is still flat (no amlogic/
# subdirectory), so both layouts are detected.
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$SCRIPT_DIR/pkg"
BOOTPART="/media/$(whoami)/BOOTPART"
ROOTPART="/media/$(whoami)/rootpart"
TEMPLATE_DIR="$DTS_DIR/boot/template"

asroot() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

CONFIG_FILE=$(ls "$PKG_DIR"/boot/config-*-stb-m8x 2>/dev/null | head -n1) || true
[ -n "$CONFIG_FILE" ] || { echo "No pkg/boot/config-*-stb-m8x found; run build.sh first" >&2; exit 1; }
KVER=$(basename "$CONFIG_FILE" | sed -E 's/^config-//')
KERNEL_VERSION="${KVER%-stb-m8x}"
SRC_DIR="$SCRIPT_DIR/linux-$KERNEL_VERSION"
if [ -d "$SRC_DIR/arch/arm/boot/dts/amlogic" ]; then
    DTB_SRC_DIR="$SRC_DIR/arch/arm/boot/dts/amlogic"
else
    DTB_SRC_DIR="$SRC_DIR/arch/arm/boot/dts"
fi
echo "==> Deploying kernel $KVER"

[ -f "$PKG_DIR/uImage-$KVER" ] || { echo "$PKG_DIR/uImage-$KVER missing" >&2; exit 1; }
[ -d "$PKG_DIR/lib/modules/$KVER" ] || { echo "$PKG_DIR/lib/modules/$KVER missing" >&2; exit 1; }
[ -d "$DTB_SRC_DIR" ] || { echo "$DTB_SRC_DIR missing (source tree not built?)" >&2; exit 1; }
ls "$DTB_SRC_DIR"/meson8*.dtb >/dev/null 2>&1 || { echo "no meson8*.dtb found in $DTB_SRC_DIR (source tree not built?)" >&2; exit 1; }

for mp in "$BOOTPART" "$ROOTPART"; do
    mountpoint -q "$mp" || { echo "$mp is not mounted" >&2; exit 1; }
done

cleanup_chroot() {
    asroot umount "$ROOTPART/sys" 2>/dev/null || true
    asroot umount "$ROOTPART/proc" 2>/dev/null || true
    asroot umount "$ROOTPART/dev/pts" 2>/dev/null || true
    asroot umount "$ROOTPART/dev" 2>/dev/null || true
    asroot umount "$ROOTPART/boot" 2>/dev/null || true
}
trap cleanup_chroot EXIT

OLDKVER=$(awk -F= '/^kver=/{print $2}' "$BOOTPART/uEnv.ini")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BOOTPART/old-${OLDKVER}-${TIMESTAMP}"

echo "==> Backing up current BOOTPART (kver=$OLDKVER) to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
find "$BOOTPART" -mindepth 1 -maxdepth 1 \
    ! -name 'old-*' ! -name '.Trash-*' ! -name '.LOST.DIR' ! -name '.claude' \
    -exec cp -a {} "$BACKUP_DIR"/ \;

echo "==> Removing previous kernel-specific files (kver=$OLDKVER) from BOOTPART"
rm -rf "$BOOTPART/config-$OLDKVER" "$BOOTPART/dtb-$OLDKVER" \
       "$BOOTPART/System.map-$OLDKVER" "$BOOTPART/initrd.img-$OLDKVER" \
       "$BOOTPART/uIm-$OLDKVER" "$BOOTPART/uIn-$OLDKVER" "$BOOTPART/zImage-$OLDKVER"

echo "==> Installing with-initrd u-boot scripts"
cp -a "$TEMPLATE_DIR"/aml_autoscript "$TEMPLATE_DIR"/aml_autoscript.cmd "$TEMPLATE_DIR"/aml_autoscript.zip \
      "$TEMPLATE_DIR"/s805_autoscript "$TEMPLATE_DIR"/s805_autoscript.txt \
      "$TEMPLATE_DIR"/build.sh "$TEMPLATE_DIR"/shorten-filenames.sh \
      "$BOOTPART"/

echo "==> Copying new kernel files to BOOTPART"
install -m 644 "$CONFIG_FILE" "$BOOTPART/config-$KVER"
install -m 644 "$PKG_DIR/boot/System.map-$KVER" "$BOOTPART/System.map-$KVER"
install -m 644 "$PKG_DIR/uImage-$KVER" "$BOOTPART/uIm-$KVER"

echo "==> Collecting dtbs from the built source tree ($DTB_SRC_DIR)"
mkdir -p "$BOOTPART/dtb-$KVER"
cp "$DTB_SRC_DIR"/meson8*.dtb "$BOOTPART/dtb-$KVER"/

echo "==> Updating uEnv.ini kver"
sed -i "s/^kver=.*/kver=$KVER/" "$BOOTPART/uEnv.ini"

echo "==> Copying modules to rootpart"
asroot mkdir -p "$ROOTPART/usr/lib/modules"
if [ "$KVER" = "$OLDKVER" ] && [ -d "$ROOTPART/usr/lib/modules/$KVER" ]; then
    echo "==> $KVER already present in /usr/lib/modules (newer revision of the same version); renaming old modules dir"
    asroot mv "$ROOTPART/usr/lib/modules/$KVER" "$ROOTPART/usr/lib/modules/${KVER}.old-${TIMESTAMP}"
fi
asroot cp -a "$PKG_DIR/lib/modules/$KVER" "$ROOTPART/usr/lib/modules/$KVER"

echo "==> Building initrd for $KVER (chroot into rootpart via qemu-arm-static)"
asroot mount --bind "$BOOTPART" "$ROOTPART/boot"
asroot mount --bind /dev "$ROOTPART/dev"
asroot mount --bind /dev/pts "$ROOTPART/dev/pts"
asroot mount -t proc proc "$ROOTPART/proc"
asroot mount -t sysfs sysfs "$ROOTPART/sys"

if [ -f "$BOOTPART/initrd.img-$KVER" ]; then
    asroot chroot "$ROOTPART" update-initramfs -u -k "$KVER"
else
    asroot chroot "$ROOTPART" update-initramfs -c -k "$KVER"
fi

cleanup_chroot

[ -f "$BOOTPART/initrd.img-$KVER" ] || { echo "initrd.img-$KVER was not created" >&2; exit 1; }

echo "==> Wrapping initrd.img-$KVER as a u-boot ramdisk image"
mkimage -A arm -O linux -T ramdisk -C gzip -a 0 -e 0 \
    -n "initrd.img-$KVER" \
    -d "$BOOTPART/initrd.img-$KVER" \
    "$BOOTPART/uIn-$KVER"

sync
echo "==> Done. New kernel $KVER installed with initrd."
echo "    Backup of previous BOOTPART state: $BACKUP_DIR"
