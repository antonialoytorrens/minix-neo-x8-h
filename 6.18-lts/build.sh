#!/bin/bash
set -eu -o pipefail

KERNEL_VERSION="6.18.38"

cd "$(dirname $0)"
if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
	wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz
fi

if [ ! -f "linux-${KERNEL_VERSION}" ]; then
	tar -xf linux-${KERNEL_VERSION}.tar.xz
fi

cd linux-${KERNEL_VERSION}

for f in ../linux-m8x/debian-latest/debian/patches/*.patch; do
	patch -p1 -F0 -N -f < "${f}"
done

cp ../config.armhf .config
make ARCH="arm" CROSS_COMPILE="/usr/bin/arm-linux-gnueabihf-" olddefconfig && \
make -j$(nproc) ARCH="arm" CROSS_COMPILE="/usr/bin/arm-linux-gnueabihf-" && \
install -m 644 .config ../pkg/boot/config-${KERNEL_VERSION}-stb-m8x && \
install -m 644 arch/arm/boot/zImage ../pkg/boot/zImage-${KERNEL_VERSION}-stb-m8x && \
install -m 644 System.map ../pkg/boot/System.map-${KERNEL_VERSION}-stb-m8x && \
make ARCH="arm" CROSS_COMPILE="/usr/bin/arm-linux-gnueabihf-" INSTALL_MOD_PATH="$(pwd)/../pkg" modules_install && \
make ARCH="arm" CROSS_COMPILE="/usr/bin/arm-linux-gnueabihf-" INSTALL_HDR_PATH="$(pwd)/../pkg" headers_install && \
mkimage -A arm -O linux -T kernel -C none -a 0x00208000 -e 0x00208000 -n linux-${KERNEL_VERSION}-stb-m8x -d arch/arm/boot/zImage ../pkg/uImage-${KERNEL_VERSION}-stb-m8x

echo "Remember to copy files and run 'short_filenames.sh' inside BOOT PARTITION!"
