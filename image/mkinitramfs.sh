#!/bin/sh
# mkinitramfs-guest.sh — assemble the v86 guest initramfs.
#
# This is fx-init/tests/mkinitramfs.sh (the M4 image builder) ADAPTED for the
# browser guest, NOT a parallel layout.  The guest layout below is the
# reference one: /fx/store carries the activated store, /bin/init is the
# store's fx-init, the device nodes travel in a PREPENDED newc cpio segment
# (mode bits + rdevmajor/rdevminor — no CAP_MKNOD needed at build time), and
# the mountpoint skeleton (/proc /sys /dev /run/fx /tmp 1777) is what
# mount_early + pivot_root_to_tmpfs expect.  /usr/fx-core/bin is the -b
# console payload (mkinitramfs.sh -b), present pre- and post-pivot because
# /usr is one of pivot_root_to_tmpfs's binds.
#
# THE V86-SPECIFIC DELTAS from the reference script (each a measured reason,
# not a preference):
#   * every shipped binary is STATIC (elf_i386, 0 NEEDED via the in-graph
#     static libdatalog), so the reference's ldd-closure /lib64 walk and its
#     libdatalog.so copy contribute NOTHING — the .so alone is 23 MB.
#   * NO busybox: the host's is x86-64/glibc and cannot execute in an i386
#     guest, so shipping it would be a 1.2 MB broken applet set.  Nothing on
#     the boot path needs a shell (the activated boot buildfile's recipe is
#     Mkdir/Copy/Chmod/Rm/Symlink only — no Shell/Run action).
#   * /lib64 and /usr are still created as EMPTY DIRS: they are
#     pivot_root_to_tmpfs's bind sources, and a missing one makes the pivot
#     decline ("bind source /lib64 absent — staying on initramfs root").
#   * the archive is XZ (the kernel's RD_XZ path — the v86 recipe), not gzip;
#     xz --check=crc32 because the kernel XZ decoder rejects CRC64.
#
# usage: mkinitramfs-guest.sh -s STORE -r ROOTDIR -o OUT.xz [-b BINDIR] [-l LIST]
#   -b BINDIR  the fx-core console payload (fxsh + fx-*), copied to
#              /usr/fx-core/bin (the -b equivalent).
#   -l LISTFILE  the archive file list (dev segment + main segment).
set -u

fail() { echo "mkinitramfs-guest: FAIL: $*" >&2; exit 1; }

STORE=""; ROOTDIR=""; OUT=""; BINDIR=""; LIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) STORE=$2; shift 2 ;;
        -r) ROOTDIR=$2; shift 2 ;;
        -o) OUT=$2; shift 2 ;;
        -b) BINDIR=$2; shift 2 ;;
        -l) LIST=$2; shift 2 ;;
        *) fail "unknown arg '$1'" ;;
    esac
done
[ -n "$STORE" ]   || fail "-s STORE required"
[ -n "$ROOTDIR" ] || fail "-r ROOTDIR required"
[ -n "$OUT" ]     || fail "-o OUT.xz required"
[ -d "$STORE" ]   || fail "store not a directory: $STORE"
[ -d "$ROOTDIR" ] || fail "rootdir not a directory: $ROOTDIR"
for t in cpio xz find; do command -v "$t" >/dev/null 2>&1 || fail "$t not found"; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mkguest.XXXXXX")" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"

# ─── skeleton: mountpoints + tmp ─────────────────────────────────────────
mkdir -p "$STAGE/fx/store" "$STAGE/lib64" "$STAGE/usr" "$STAGE/bin" \
         "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run/fx" "$STAGE/tmp" \
    || fail "cannot create image skeleton"
chmod 1777 "$STAGE/tmp"

# ─── the store (minus build scratch), exactly as the reference copies it ──
cp -a "$STORE"/. "$STAGE/fx/store/" || fail "cannot copy store"
rm -rf "$STAGE/fx/store/.build" "$STAGE/fx/store/.tmp" 2>/dev/null

# ─── the fx-core console payload (-b) → /usr/fx-core/bin ─────────────────
if [ -n "$BINDIR" ]; then
    [ -d "$BINDIR" ] || fail "-b bindir not a directory: $BINDIR"
    mkdir -p "$STAGE/usr/fx-core/bin" || fail "cannot create /usr/fx-core/bin"
    for f in $(LC_ALL=C ls "$BINDIR"); do
        [ -f "$BINDIR/$f" ] || continue
        cp "$BINDIR/$f" "$STAGE/usr/fx-core/bin/$f" || fail "cannot copy $BINDIR/$f"
        chmod 755 "$STAGE/usr/fx-core/bin/$f"
    done
fi

# the store's fx-init dir (guest-absolute target for /bin/init)
FXINIT_DIR=$( (cd "$STAGE/fx/store" && ls -d ./*-fx-init 2>/dev/null) | head -1 )
[ -n "$FXINIT_DIR" ] || fail "no *-fx-init dir in the store (activate a generation first)"
ln -s "/fx/store/${FXINIT_DIR#./}/fx-init" "$STAGE/bin/init"

# ─── ROOTDIR overlay (pre-boot rootfs state; empty by default) ───────────
cp -a "$ROOTDIR"/. "$STAGE/" || fail "cannot overlay ROOTDIR $ROOTDIR"

# ─── the early device-node cpio segment (verbatim from the reference) ────
# 070701 (newc): 110-byte header = magic + 13 x 8-hex fields, then name+NUL,
# then a 4-byte pad.  Modes decimal: dir|0755 = 16877; chr|0600 = 8576;
# chr|0666 = 8630.  The kernel opens /dev/console for PID1's fds 0-2 BEFORE
# exec'ing rdinit, so these must be REAL char devices.
DEV_INO=900
cpio_rec() {
    DEV_INO=$((DEV_INO + 1))
    _n=$1; _m=$2; _rj=$3; _rn=$4
    _ns=$((${#_n} + 1))
    printf '070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x00000000' \
        "$DEV_INO" "$_m" 0 0 1 0 0 0 0 "$_rj" "$_rn" "$_ns"
    printf '%s\0' "$_n"
    _pad=$(( (4 - ((110 + _ns) & 3)) & 3 ))
    [ "$_pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$_pad" 2>/dev/null
    return 0
}
{
    cpio_rec dev         16877  0  0
    cpio_rec dev/console  8576  5  1
    cpio_rec dev/null     8630  1  3
    cpio_rec dev/tty      8576  5  0
    cpio_rec dev/ttyS0    8576  4 64
    cpio_rec TRAILER!!!      0  0  0
} > "$WORK/dev.cpio"

# ─── make the archive byte-reproducible (the 5th v86 delta) ─────────────
# newc cpio records the source file's inode in the header, and the staging
# tree is created fresh under mktemp each run, so the reference script's
# `cpio -o -H newc` emits a DIFFERENT archive every time even from an
# unchanged store.  MEASURED before this delta: two consecutive runs from the
# same store gave 63872fd1… and 46f59483…; after: identical sha256, twice.
#   --reproducible     zeroes the device/inode-dependent fields
#   --renumber-inodes  renumbers so the ino column is a function of the tree
# plus a pinned mtime (newc records one, and the fresh skeleton dirs and the
# plain-`cp` -b payload would otherwise carry the build time).  SOURCE_DATE_EPOCH
# is the standard knob (https://reproducible-builds.org); 0 unless overridden.
: "${SOURCE_DATE_EPOCH:=0}"
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + \
    || fail "cannot pin mtimes on $STAGE"

# ─── assemble: early devices ++ staged tree, xz'd for the kernel's RD_XZ ─
( cd "$STAGE" && find . | LC_ALL=C sort \
    | cpio -o -H newc --reproducible --renumber-inodes ) > "$WORK/main.cpio" \
    || fail "cpio archive failed"
cat "$WORK/dev.cpio" "$WORK/main.cpio" \
    | xz --check=crc32 --lzma2=preset=9,dict=8MiB -T1 -c > "$OUT" || fail "xz failed"
[ -s "$OUT" ] || fail "archive is empty"

if [ -n "$LIST" ]; then
    { cpio -it < "$WORK/dev.cpio" 2>/dev/null
      cpio -it < "$WORK/main.cpio" 2>/dev/null
    } | LC_ALL=C sort > "$LIST" || fail "cannot write list $LIST"
fi
echo "mkinitramfs-guest: built $OUT ($(wc -c < "$OUT") bytes, raw $(( $(wc -c < "$WORK/dev.cpio") + $(wc -c < "$WORK/main.cpio") )), store $STORE)"
