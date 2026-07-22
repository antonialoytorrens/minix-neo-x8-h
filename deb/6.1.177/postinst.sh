#!/bin/bash
# Deploys a linux-image-*-m8x-armhf_*.deb from this directory onto the
# BOOTPART/rootpart SD card: extracts the kernel, backs up the previous
# BOOTPART state, installs the kernel/dtb/modules, builds an initrd by
# chrooting into rootpart (via qemu-arm-static/binfmt), and wires up the
# with-initrd u-boot boot template.
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

IMAGE_DEB=$(ls "$SCRIPT_DIR"/linux-image-*-m8x-armhf_*.deb 2>/dev/null | grep -v -- '-dbgsym_' | head -n1) || true
[ -n "$IMAGE_DEB" ] || { echo "No linux-image-*-m8x-armhf deb found in $SCRIPT_DIR" >&2; exit 1; }
KVER=$(basename "$IMAGE_DEB" | sed -E 's/^linux-image-(.*)_[0-9].*/\1/')
echo "==> Deploying kernel $KVER"

for mp in "$BOOTPART" "$ROOTPART"; do
    mountpoint -q "$mp" || { echo "$mp is not mounted" >&2; exit 1; }
done

WORKDIR=$(mktemp -d)

cleanup_chroot() {
    asroot umount "$ROOTPART/sys" 2>/dev/null || true
    asroot umount "$ROOTPART/proc" 2>/dev/null || true
    asroot umount "$ROOTPART/dev/pts" 2>/dev/null || true
    asroot umount "$ROOTPART/dev" 2>/dev/null || true
    asroot umount "$ROOTPART/boot" 2>/dev/null || true
}
cleanup_all() {
    cleanup_chroot
    rm -rf "$WORKDIR"
}
trap cleanup_all EXIT

echo "==> Extracting $(basename "$IMAGE_DEB")"
dpkg-deb -x "$IMAGE_DEB" "$WORKDIR"

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
install -m 644 "$WORKDIR/boot/config-$KVER" "$BOOTPART/config-$KVER"
install -m 644 "$WORKDIR/boot/System.map-$KVER" "$BOOTPART/System.map-$KVER"
cp -a "$WORKDIR/boot/dtb-$KVER" "$BOOTPART/dtb-$KVER"
install -m 644 "$WORKDIR/boot/uImage-$KVER" "$BOOTPART/uIm-$KVER"

echo "==> Updating uEnv.ini kver"
sed -i "s/^kver=.*/kver=$KVER/" "$BOOTPART/uEnv.ini"

echo "==> Copying modules to rootpart"
asroot mkdir -p "$ROOTPART/usr/lib/modules"
if [ "$KVER" = "$OLDKVER" ] && [ -d "$ROOTPART/usr/lib/modules/$KVER" ]; then
    echo "==> $KVER already present in /usr/lib/modules (newer revision of the same version); renaming old modules dir"
    asroot mv "$ROOTPART/usr/lib/modules/$KVER" "$ROOTPART/usr/lib/modules/${KVER}.old-${TIMESTAMP}"
fi
asroot cp -a "$WORKDIR/lib/modules/$KVER" "$ROOTPART/usr/lib/modules/$KVER"

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
