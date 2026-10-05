# Building the guest

Everything in `web/` is committed, so you do **not** need this document to *run*
the demo — only to rebuild it. It is written so that a rebuild is a sequence of
commands, not an archaeology exercise.

Three steps: **kernel** → **userland + store** → **image**.

---

## 0. Toolchain

| tool | version used | why |
|---|---|---|
| `podman` (or `docker`) | any | the kernel is built in `debian:stable` |
| `zig` | **0.16.0** | every userland binary is a Zig build |
| `cpio`, `xz`, `file` | GNU cpio 2.15, xz 5.x | the initramfs; the reproducibility flags below are GNU cpio ≥ 2.12 |
| `python3` | 3.13 | the gzip-reporting static server |
| `node` | 26.x | the boot harnesses and the Playwright assertion |

---

## 1. The kernel — `kbuild/`

One command, in a container (the host may have any libc):

```sh
podman run --rm -v "$PWD/kbuild:/k:Z" debian:stable bash /k/build-lean.sh
# -> kbuild/bzImage-i386-lean   795,136 bytes
#    sha256 25be0d5358d9445712f6d04e59a7be9133acbd3f69ad0720a69e43d5ba844b3d
```

`build-lean.sh` is `make ARCH=i386 tinyconfig` + a fragment listing exactly the
gates tinyconfig leaves **off**, each with its reason in the script. The
resolved config is saved to `config-i386-lean.txt` and is the checked-in record
of what was built; `config-i386.txt` is the earlier, untrimmed variant
(`kbuild/build.sh`, 881,152 bytes — it boots too, it is just 86 KB larger).

The hard-won gates, in the order they bit:

* **`CONFIG_BINFMT_ELF`** — off once `EXPERT` is on. Without it the kernel
  cannot exec an ELF: nothing runs, not even init.
* **`CONFIG_PRINTK` / `TTY` / `SERIAL_8250(_CONSOLE)`** — no console, no demo.
* **`BLK_DEV_INITRD` + `RD_XZ`** — the image is an xz'd cpio archive handed in
  as `initrd`; without `RD_XZ` the kernel drops it silently.
* **`DEVTMPFS(+_MOUNT)`, `TMPFS`, `PROC_FS`, `PROC_SYSCTL`** — fx-init's pivot
  to a tmpfs root and its `/proc` mount.
* **`MULTIUSER`, `FILE_LOCKING`, `FUTEX`, `EPOLL`, `EVENTFD`, `SIGNALFD`,
  `TIMERFD`, `BINFMT_SCRIPT`, `SHMEM`** — what a real PID 1 and its
  fork/pipe/execve pipeline need.
* **`CONFIG_UNIX` is NOT in this kernel, and the build no longer pretends it
  is.** `build.sh` / `build-lean.sh` used to pass `--enable UNIX`, which
  `olddefconfig` DROPS **silently**: `CONFIG_UNIX` depends on `CONFIG_NET`, the
  `tinyconfig` base has `# CONFIG_NET is not set`, and a dropped symbol does not
  even appear in the resolved config (`kbuild/config-i386-lean.txt:616`;
  `grep -c '^CONFIG_UNIX=' kbuild/config-i386-lean.txt` → `0`). The consequence
  is visible in the guest: there is **no socket layer at all**, so `socket(2)`
  returns `ENOSYS` and fx-init's `/run/fx/control.sock` can never come up (the
  README's control-socket open item — this is its root cause). Enabling `UNIX`
  means enabling `NET`, i.e. a different, much larger kernel than the one this
  demo ships; both scripts now print `NET`/`UNIX` as `UNSET` in their
  resolved-config check so the flag cannot be re-added unnoticed.
* `--disable VT VT_CONSOLE VGA_CONSOLE HW_CONSOLE INPUT SERIO HID` — the
  serial-only console does not need a graphics stack; this is the 86 KB trim.

**Why i386 at all:** v86 has no long mode ("64-bit kernels are not supported"),
so a 32-bit kernel is the only kernel this emulator can boot.

**The kernel build is not bit-reproducible.** `make` embeds a build timestamp in
the version banner. If you need the shipped bytes, use the pinned artifact; if
you need a *working* kernel, rebuild and re-verify with the assertion.

---

## 2. The userland — six repos, static i386

The guest is 32-bit and the image ships **no dynamic loader**, so every binary
that executes in the guest must be a static `elf_i386`. On an x86-64 Linux host
those run natively, which is why the *store provisioning* below happens on the
host rather than in the guest.

Pin the checkouts at the revisions the shipped guest was built from (see the
"Revisions" section of the README — three of the six have uncommitted i386 port
patches, and those patches are **not** in the repos' remotes):

```sh
git clone https://github.com/fixpoint-linux/datalog-dafsa
git clone https://github.com/fixpoint-linux/dhall-c
git clone https://github.com/fixpoint-linux/fxstore
git clone https://github.com/fixpoint-linux/fx-init
git clone https://github.com/fixpoint-linux/fx-core
git clone https://github.com/fixpoint-linux/dhake
```

Four `zig build` invocations. They must sit as siblings — each build reads the
others' sources in-graph (for musl it links a **static** libdatalog/libdhall
built from the sibling's Zig sources, instead of the glibc `.so`):

```sh
# fxstore (a dependency of fx-init's package set)
cd fxstore && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix /tmp/i386/fxstore

# fx-init -> 11 static i386 binaries in bin/
cd ../fx-init/zig && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix /tmp/i386/fxinit
#   activate_facts activate_paths config_check fx-activate fxctl fxctl_check
#   fx-image fx-init log_probe_live reloc_check supervise_check

# fx-core -> 63 static i386 binaries in bin/ (fxsh + the fx-* stage set)
cd ../../fx-core && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix /tmp/i386/fxcore

# dhake -> bin/dhake
cd ../dhake && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix /tmp/i386/dhake

# fakesvc: the heartbeat service's payload (a fixture of fx-init, not a package build)
zig cc -target x86-linux-musl -std=gnu11 -O2 -static \
    -o /tmp/i386/fakesvc ../fx-init/tests/fixtures/fakesvc/fakesvc.c
```

Verify what you got (all four must be static 32-bit i386, zero `NEEDED`):

```sh
for b in /tmp/i386/fxinit/bin/fx-init /tmp/i386/fxinit/bin/fxctl \
         /tmp/i386/fxinit/bin/fx-activate /tmp/i386/dhake/bin/dhake; do
    file "$b"; readelf -d "$b" | grep -c NEEDED || true
done
# "ELF 32-bit LSB executable, Intel i386, statically linked" / 0
```

**MEASURED:** the `fx-core` line above, run against `fx-core` at commit
`d6567de` (a clean tree), reproduces the 63 binaries shipped in `web/initrd.xz`
**byte for byte** — 63/63 `sha256sum` matches, no mismatches. That command and
that revision are therefore verified, not merely documented. The other three
builds were captured from uncommitted working-tree state (see the README's
revisions table) and cannot be re-derived exactly.

### Why the i386 port was work

Recovered from the component reports, because a rebuild will hit the same wall:
`zig build -Dtarget=x86-linux-musl` originally failed in every repo with
`ld.lld: …libdatalog.so is incompatible with elf_i386`. The glibc `.so` cannot
link into an i386 musl binary; the fix was to build a **static** libdatalog
in-graph from the sibling's Zig sources. `dhake` links a shared `libdhall.so`
by the same route. On top of the linkage there were width/layout bugs that only
appear on ILP32 — `struct stat`/`struct statfs` field offsets (i386 musl has
`st_mode` at 16, x86-64 at 24), `time_t` being 64-bit while `c_long` is 32, the
`__*_time64` symbol selection, `strtol` saturating at `LONG_MAX`, a landlock
`PathBeneathAttr` whose `u64` field changes the struct size, and a
`@as(usize, sz)` narrowing in dhall-c's HTTP chunk loop. All are fixed in the
revisions listed in the README.

---

## 3. The store and its activation — `image/build-store.sh`

The store is content-addressed: `activate_paths` prints one directory per
package in the closure, and the caller fills each with that package's payload.
`build-store.sh` does the whole step:

```sh
image/build-store.sh \
    --store /tmp/fx/store \
    --fx-init-repo /path/to/fx-init \
    --bin /tmp/i386/fxinit/bin \
    --dhake /tmp/i386/dhake/bin/dhake \
    --config /path/to/fx-init/m3/config-console.dhall
```

It runs `activate_paths`, copies each payload in (the three dependency
packages — `datalog-dafsa`, `dhall-c`, `fxstore` — are **hash inputs only**;
their content never executes at boot, so their dirs carry a marker file, exactly
as fx-init's own `tests/qemu_boot.sh` does), then runs `fx-activate`, which
derives the generation and writes its `Dhakefile.dhall`. It prints the store dir
that the kernel command line's `rdinit=` must name.

⚠️ **Run it against quiescent sources.** The store paths are hexadecimal
*content hashes of the source trees*. MEASURED while writing this document: two
runs of `activate_paths` a minute apart returned a **different** hash for
`fake-service` because a concurrent editor was mid-edit in `fx-init`. The
reference harness defends against this with a source-freeze step
(`freeze_src` in `tests/qemu_boot.sh`); do the same, or run with nobody editing.

---

## 4. The image — `image/mkinitramfs.sh`

```sh
mkdir -p /tmp/fx/root                      # the pre-boot ROOTDIR overlay: empty for this guest
image/mkinitramfs.sh -s /tmp/fx/store -r /tmp/fx/root \
                     -o web/initrd.xz -b /tmp/i386/fxcore/bin
# -> web/initrd.xz   2,502,144 bytes
#    sha256 83579980424ec1e30df6b7ef3eee2fe1222e8b9a253f2692166bd69d70d11084
```

The image is a newc cpio archive: a **prepended segment of device nodes**
(`/dev/console`, `/dev/ttyS0`, … — with mode and rdev in the header, so no
`CAP_MKNOD` is needed at build time), then the staged tree, xz'd. The guest
layout is fx-init's own: store at `/fx/store`, `/bin/init` a symlink into it,
`/usr/fx-core/bin` the `-b` console payload.

Five deltas from the reference `fx-init/tests/mkinitramfs.sh`, each with a
measured reason:

1. **No `/lib64` ldd closure, no `libdatalog.so` copy** — every payload is
   static with zero `NEEDED`, so the walk contributes nothing. The `.so` alone
   is 23 MB.
2. **No busybox** — the host's is x86-64/glibc and cannot `execve` in an i386
   guest, so shipping it would be a ~1.2 MB broken applet set. Nothing on the
   boot path needs a shell: the activated boot buildfile's recipe is
   `Mkdir`/`Copy`/`Chmod`/`Rm`/`Symlink` only — no `Shell`/`Run` action.
3. **`/lib64` and `/usr` still exist as EMPTY DIRS** — they are
   `pivot_root_to_tmpfs`'s bind sources, and a missing one makes the pivot
   decline and stay on the initramfs root (`bind source /lib64 absent`).
4. **xz, not gzip** — the kernel's `RD_XZ` path, with `--check=crc32` because
   the kernel's XZ decoder accepts only `none`/CRC32 and plain `xz` writes CRC64
   (reported as `Input was encoded with settings that are not supported by this
   XZ decoder`).
5. **`--reproducible --renumber-inodes` + a pinned mtime** — newc cpio records
   the source file's inode and mtime, and the staging tree is created fresh
   under `mktemp`, so the reference script emits a **different archive every
   run** even from an unchanged store. MEASURED before: two consecutive runs
   from the same store gave `63872fd1…` and `46f59483…`. After: identical
   sha256, twice. `SOURCE_DATE_EPOCH` (default 0) is the standard knob.

The image is byte-reproducible **given the store**: same store in, same
`initrd.xz` out. It is not reproducible from *different* sources, because the
store dir names are content hashes.

---

## 5. The page's third-party assets — `web/`

Vendored, not CDN-loaded: the demo has no network dependency after the clone.

```sh
npm pack v86@0.5.470            # -> v86-0.5.470.tgz
npm pack @xterm/xterm@6.0.0     # -> xterm-xterm-6.0.0.tgz
tar -xzf v86-0.5.470.tgz        package/build/libv86.js -> web/libv86.js
tar -xzf v86-0.5.470.tgz        package/build/v86.wasm   -> web/v86.wasm
tar -xzf xterm-xterm-6.0.0.tgz  package/lib/xterm.mjs    -> web/xterm.mjs
tar -xzf xterm-xterm-6.0.0.tgz  package/css/xterm.css    -> web/xterm.css
curl -O https://copy.sh/v86/bios/seabios.bin             -> web/seabios.bin
```

`seabios.bin` is not in the npm tarball. It is the SeaBIOS image v86's own site
serves; **verified** here against both `https://copy.sh/v86/bios/seabios.bin`
and `https://raw.githubusercontent.com/copy/v86/master/bios/seabios.bin` — all
three copies are `sha256 73e3f359…`, 131,072 bytes (see `SHA256SUMS`).

`vgabios.bin` and `v86-fallback.wasm` are **not** shipped: the console is
serial-only, so neither is requested. That is an asserted property of the
passing run (they appear in neither the browser's fetches nor `serve.py`'s log).

`harness/boot.mjs` and `harness/drive.mjs` load `web/libv86.js` — the same UMD
bundle the page loads — through `createRequire`; there is no second copy of v86
in the repo.

---

## 6. Serve and assert

```sh
python3 harness/serve.py 8080 web &
npm install playwright && npx playwright install chromium-headless-shell
node harness/assert.mjs http://127.0.0.1:8080/
```

(Or skip the installs and set `PLAYWRIGHT=/path/to/node_modules/playwright/index.mjs`.)

The harnesses write `proof.png` and `proof-serial.txt` into the current
directory. `assert.mjs` exits 0 only if every assertion it prints holds.
