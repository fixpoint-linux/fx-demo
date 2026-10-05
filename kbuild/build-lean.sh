#!/bin/bash
# Runs INSIDE debian:stable container with /k mounted.
# Builds a minimal i386 bzImage for v86 (classic PC: 8250 serial, ramfs initramfs).
set -euo pipefail
cd /k
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential flex bison bc libelf-dev libssl-dev xz-utils ca-certificates >/dev/null
echo "=== toolchain ==="; gcc --version | head -1; ld --version | head -1

if [ ! -d linux-6.12.19 ]; then tar xf linux-6.12.19.tar.xz; fi
cd linux-6.12.19
make ARCH=i386 tinyconfig >/dev/null
# Fragment: exactly the gates tinyconfig leaves off. Rationale per symbol.
# SOCKETS: --enable UNIX is deliberately NOT in the list below, and that is a
# measured correction rather than an omission.  CONFIG_UNIX depends on
# CONFIG_NET, the tinyconfig base has "# CONFIG_NET is not set", and
# olddefconfig DROPS a --enable whose dependency is unmet SILENTLY -- the
# dropped symbol then appears in the resolved config NEITHER as =y NOR even as
# "# CONFIG_UNIX is not set".  The guest therefore has no socket layer at all:
# socket(2) returns ENOSYS, which is why fx-init's /run/fx/control.sock never
# comes up (see the README open item).  Putting UNIX back means enabling NET --
# a much larger kernel than this one.  The check after olddefconfig prints
# UNIX/NET as UNSET, so re-adding the flag cannot go unnoticed again.
./scripts/config \
  --enable PRINTK \
  --enable BINFMT_ELF \
  --enable TTY \
  --enable BLK_DEV_INITRD \
  --enable RD_GZIP --enable RD_XZ \
  --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT \
  --enable TMPFS \
  --enable PROC_FS --enable PROC_SYSCTL \
  --enable SYSFS \
  --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable MULTIUSER \
  --enable FILE_LOCKING \
  --enable BINFMT_SCRIPT \
  --enable FUTEX --enable EPOLL --enable SIGNALFD --enable TIMERFD --enable EVENTFD \
  --disable VT --disable VT_CONSOLE --disable VGA_CONSOLE --disable HW_CONSOLE \
  --disable INPUT --disable SERIO --disable HID --disable DEBUG_KERNEL \
  --enable SHMEM \
  --enable EXPERT --disable ELF_CORE --disable CORE_DUMP_DEFAULT_ELF_HEADERS --enable EXPERT
make ARCH=i386 olddefconfig >/dev/null
echo "=== resolved config check (must all be =y) ==="
for s in PRINTK BINFMT_ELF TTY BLK_DEV_INITRD RD_GZIP DEVTMPFS DEVTMPFS_MOUNT TMPFS PROC_FS SERIAL_8250 SERIAL_8250_CONSOLE MULTIUSER FILE_LOCKING BINFMT_ELF 64BIT; do
  printf '%-28s %s\n' "$s" "$(grep -E "^CONFIG_$s=" .config || echo 'UNSET')"
done
echo "=== sockets: deliberately OFF (must print UNSET — see the note above) ==="
for s in NET UNIX; do
  printf '%-28s %s\n' "$s" "$(grep -E "^CONFIG_$s=" .config || echo 'UNSET')"
done
cp .config /k/config-i386-lean.txt
make ARCH=i386 -j"$(nproc)" bzImage 2>&1 | tail -25
cp arch/x86/boot/bzImage /k/bzImage-i386-lean
ls -la /k/bzImage-i386-lean
sha256sum /k/bzImage-i386-lean
