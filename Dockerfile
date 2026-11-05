# Build environment for everything in this repository (kernel, rootfs, installer, boot scripts, recovery image).
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates make bc bison flex gcc gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
    libssl-dev libelf-dev python3 cpio gzip pigz xz-utils lz4 kmod rsync u-boot-tools file \
    debootstrap qemu-user-static binfmt-support mdadm e2fsprogs \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
