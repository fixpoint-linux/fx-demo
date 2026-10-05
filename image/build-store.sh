#!/bin/sh
# build-store.sh — provision a fixpoint-linux content-addressed store with the
# i386 userland and ACTIVATE a config into it, on the HOST.
#
# This is the step between "the components are built" and "mkinitramfs can
# assemble the guest". It follows fx-init's own M4 image lane
# (tests/qemu_boot.sh, the toolchain-free provisioning path) with one delta:
# every payload here is a STATIC elf_i386 binary, so the closure dirs need no
# ldd walk and the commands need no LD_LIBRARY_PATH — and because i386 static
# ELFs run natively on an x86-64 Linux host, the whole provisioning step runs
# on the host rather than in the guest.
#
# What activate_paths does: it prints the store path of every package in the
# closure, one per line. It does NOT fill them. The caller must put each
# package's payload in its dir. The payload paths must match the package-set
# TARGETS: fx-init/fxctl/fx-activate/fakesvc/dhake.com are what the boot path
# execs; the datalog-dafsa/dhall-c/fxstore deps are hash INPUTS only (their
# content never executes at boot — exactly as tests/qemu_boot.sh documents),
# so their dirs carry a marker file.
#
# fx-activate then derives the generation, writes its Dhakefile, and records it
# as the active version. The buildfile's Copy/Symlink sources name the store by
# the path given to --store; fx-init RELOCATES them to the boot-time store root
# (fx.store= on the kernel command line), which is why the guest works with the
# store at /fx/store no matter where the host activation happened.
#
# Usage:
#   image/build-store.sh --store DIR --fx-init-repo DIR --bin DIR \
#       [--config FILE] [--dhake FILE] [--fakesvc FILE]
#     --store DIR         the store to create/populate (mkdir -p'd if absent)
#     --fx-init-repo DIR  an fx-init checkout (for m3/package-set.dhall)
#     --bin DIR           a `zig build -Dtarget=x86-linux-musl` fx-init build:
#                         must contain fx-init, fxctl, fx-activate, activate_paths
#     --dhake FILE        the i386 dhake (dhake/build.zig -> bin/dhake);
#                         default: $BIN/../dhake/bin/dhake
#     --fakesvc FILE      a static i386 fakesvc; built here with `zig cc`
#                         from $FX_INIT_REPO/tests/fixtures/fakesvc/fakesvc.c
#     --config FILE       the config to activate (default m3/config-console.dhall)
set -eu

fail() { echo "build-store: FAIL: $*" >&2; exit 1; }

STORE=""; REPO=""; BIN=""; DHAKE=""; FAKESVC=""; CONFIG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --store)         STORE=$2; shift 2 ;;
        --fx-init-repo)  REPO=$2; shift 2 ;;
        --bin)           BIN=$2; shift 2 ;;
        --dhake)         DHAKE=$2; shift 2 ;;
        --fakesvc)       FAKESVC=$2; shift 2 ;;
        --config)        CONFIG=$2; shift 2 ;;
        *) fail "unknown arg '$1'" ;;
    esac
done
[ -n "$STORE" ] || fail "--store DIR required"
[ -n "$REPO" ]  || fail "--fx-init-repo DIR required"
[ -n "$BIN" ]   || fail "--bin DIR required"
[ -d "$REPO/m3" ] || fail "no m3/ under --fx-init-repo $REPO"
[ -d "$BIN" ]     || fail "--bin not a directory: $BIN"
[ -n "$CONFIG" ] || CONFIG="$REPO/m3/config-console.dhall"
case "$CONFIG" in /*) ;; *) CONFIG="$REPO/$CONFIG" ;; esac
[ -r "$CONFIG" ] || fail "--config not readable: $CONFIG"
[ -n "$DHAKE" ]  || DHAKE="$BIN/../dhake/bin/dhake"
[ -f "$DHAKE" ]  || fail "no dhake at $DHAKE (pass --dhake FILE)"
for b in fx-init fxctl fx-activate activate_paths; do
    [ -x "$BIN/$b" ] || fail "$BIN/$b missing/not executable (build fx-init for x86-linux-musl first)"
done
PKGSET="$REPO/m3/package-set.dhall"
[ -r "$PKGSET" ] || fail "no package set at $PKGSET"

# every payload must be a static i386 ELF: the guest is 32-bit and the image
# ships no dynamic loader, so a dynamically-linked or 64-bit binary would only
# fail later, in the guest. Check now.
check_i386() { # check_i386 PATH
    f=$(file -b "$1" 2>/dev/null) || return 1
    case "$f" in
        *"ELF 32-bit"*i386*"statically linked"*) return 0 ;;
        *) fail "$1 is not a static i386 ELF: $f" ;;
    esac
}
for b in fx-init fxctl fx-activate; do check_i386 "$BIN/$b"; done
check_i386 "$DHAKE"

mkdir -p "$STORE" || fail "cannot create store $STORE"

# ─── fakesvc: the heartbeat service's payload (not an fx-init binary) ──────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxstore.XXXXXX")" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
if [ -z "$FAKESVC" ]; then
    C="$REPO/tests/fixtures/fakesvc/fakesvc.c"
    [ -r "$C" ] || fail "no fakesvc source at $C (pass --fakesvc FILE)"
    command -v zig >/dev/null 2>&1 || fail "zig not found (needed to build fakesvc; or pass --fakesvc FILE)"
    echo "--- zig cc fakesvc (x86-linux-musl, static) ---"
    zig cc -target x86-linux-musl -std=gnu11 -O2 -static -o "$WORK/fakesvc" "$C" \
        || fail "zig cc fakesvc failed"
    FAKESVC="$WORK/fakesvc"
fi
check_i386 "$FAKESVC"

# ─── the closure dirs, one payload each ───────────────────────────────────
echo "--- activate_paths: the closure ---"
PATHS=$("$BIN/activate_paths" --store "$STORE" --package-set "$PKGSET" \
    dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore) \
    || fail "activate_paths failed"
[ -n "$PATHS" ] || fail "activate_paths printed no closure"
echo "$PATHS" | while IFS= read -r pd; do
    [ -n "$pd" ] || continue
    mkdir -p "$STORE/$pd" || exit 1
    case "$pd" in
        *-fx-init)      cp "$BIN/fx-init"     "$STORE/$pd/fx-init";     chmod 755 "$STORE/$pd/fx-init" ;;
        *-fxctl)        cp "$BIN/fxctl"       "$STORE/$pd/fxctl";       chmod 755 "$STORE/$pd/fxctl" ;;
        *-fx-activate)  cp "$BIN/fx-activate" "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
        *-fake-service) cp "$FAKESVC"         "$STORE/$pd/fakesvc";     chmod 755 "$STORE/$pd/fakesvc" ;;
        *-dhake)        cp "$DHAKE"           "$STORE/$pd/dhake.com";   chmod 755 "$STORE/$pd/dhake.com" ;;
        *)              : > "$STORE/$pd/.provisioned-by-build-store" ;;
    esac
done || fail "filling the closure failed"

# ─── activate ─────────────────────────────────────────────────────────────
echo "--- fx-activate: $(basename "$CONFIG") ---"
ACT=$("$BIN/fx-activate" --store "$STORE" --package-set "$PKGSET" --config "$CONFIG") \
    || fail "activate failed"
echo "$ACT"
V=$(echo "$ACT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V" ] || fail "cannot parse version from activate output"

# the store dir fx-init itself lands in — this is the hash the kernel command
# line's rdinit= must name (see docs/BOOT.md)
FXINIT_DIR=$(ls -d "$STORE"/*-fx-init 2>/dev/null | head -1)
[ -n "$FXINIT_DIR" ] || fail "no *-fx-init dir in the store after activation"

echo
echo "build-store: OK"
echo "  store      $STORE"
echo "  version    $V"
echo "  rdinit     /fx/store/$(basename "$FXINIT_DIR")/fx-init  (inside the guest)"
echo "  -> put this in the kernel cmdline as rdinit=, with fx.store=/fx/store"
