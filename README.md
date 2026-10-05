# fx-demo — the real fixpoint-linux system in a browser terminal

A static page that boots a **real 32-bit Linux kernel** under
[v86](https://github.com/copy/v86) (an x86 PC emulator compiled to wasm), with
the actual fixpoint-linux system running on it:

* **`fx-init` as PID 1** — exec'd *out of the content-addressed store* via the
  kernel's `rdinit=`, the M4 initramfs path: no disk image, no bootloader.
* **the content-addressed store** at `/fx/store`.
* **`dhake` materializing the rootfs** — `/etc` and `/bin` exist in the guest
  only because dhake's buildfile ran and copied/symlinked them out of the store.
* **the fx-core shell (`fxsh`) on the serial console**, at a real `fx> ` prompt,
  running real `fork`/`pipe`/`execve` pipelines.

The kernel, the store, `fx-init`, `dhake` and every `fx-*` stage are genuine
builds of the fixpoint-linux components — the emulator is emulating a PC, not
simulating fixpoint. **Total download: 3,929,733 bytes (3.75 MiB).**

```
Run /fx/store/dda2c337…-fx-init/fx-init as init process
fx-init: store from kernel command line fx.store=/fx/store
fx-init: disk store: no /dev/vda — using ramfs store
fx-init: pivot_root EINVAL (initramfs root is the namespace root) — switch_root fallback (MS_MOVE + chroot) applied
fx-init: pivoted to tmpfs root (magic 0x1021994)
fx> cat /etc/hostname
fixboxfx> cksum /bin/fxctl
1217607440 210768 /bin/fxctl
fx> cksum /bin/init
2017035490 825300 /bin/init
fx> cat /etc/passwd
root:x:0:0::/home/root:/bin/sh
fx> fx-init: boot-ok v7
seq 1 3 | head -n 2
1
2
fx>
```

## Run it

```sh
git clone https://github.com/fixpoint-linux/fx-demo && cd fx-demo
python3 harness/serve.py 8080 web        # open http://127.0.0.1:8080/
```

Everything the page fetches is committed, so this works offline and needs no
build. A served page is required (not `file://`) because a module script and a
wasm fetch cannot be loaded from the filesystem.

### Prove it yourself

```sh
python3 harness/serve.py 8080 web &
npm install playwright
npx playwright install chromium-headless-shell   # the browser playwright drives
node harness/assert.mjs http://127.0.0.1:8080/
```

(If you already have Playwright and a browser, skip the two installs and set
`PLAYWRIGHT=/path/to/node_modules/playwright/index.mjs` instead.)

Exit 0 and the ten assertions below are the claim; `proof.png` and
`proof-serial.txt` are written to the current directory. **The run quoted in
`evidence/` was made this way, against a fresh `git clone` of the pushed repo at
commit `8e549bc`, not from a working tree** — see `evidence/assert-output.txt`
for the verbatim transcript, the port used, and the `sha256sum -c` result.

```
ASSERT fx-init-boot-ok-in-page: true (fx-init: boot-ok v7)
ASSERT pivoted-to-tmpfs: true
ASSERT rdinit-from-store: true
ASSERT dhake-materialized-/etc (rendered 'fixbox'): true
ASSERT dhake-/bin/fxctl-symlink-reads-through (in-guest size 210768): true
ASSERT dhake-/bin/init-symlink-reads-through (in-guest size 825300): true
ASSERT dhake-materialized-/etc/passwd: true
ASSERT typed-pipeline-in-terminal: true  output-1: true  output-2: true  3-filtered: true
TOTAL FETCHED BY THE BROWSER (bytes): 3929733
```

`docs/BOOT.md` explains why each of those is evidence rather than decoration.

## The numbers (MEASURED, not estimated)

3,929,733 bytes is not a sum of file sizes: it is the sum of the
`content-length` of every response the browser actually received in the passing
run, with the server applying `Content-Encoding: gzip`.

| file | raw | sent |
|---|---|---|
| `initrd.xz` — the store + the 63 fx-core i386 binaries + fx-init | 2,502,144 | 2,502,144 (xz: incompressible) |
| `v86.wasm` | 2,007,347 | 380,456 |
| `bzImage` (i386, linux-6.12.19 `tinyconfig` + fragment) | 795,136 | 795,136 (extension-less: the server does not gzip it) |
| `libv86.js` | 359,825 | 93,787 |
| `xterm.mjs` | 344,970 | 88,463 |
| `seabios.bin` | 131,072 | 65,607 |
| `xterm.css` | 7,112 | 2,502 |
| `index.html` | 2,755 | 1,469 |
| | | **3,929,733** |

Same page served with `identity` encoding: 6,150,361 bytes (the same eight
assets uncompressed). For scale, a `qemu-wasm` route to the same guest is
~40 MB raw / ~10–13 MB compressed.

**Caveat, stated not hidden:** 169 bytes of that total is a single response
chromium makes that the page's server does *not* serve (a UUID path; the
server's own request log lists only the 8 assets). Excluding it, the page's own
assets total **3,929,564** bytes. `vgabios.bin` and `v86-fallback.wasm` are
never fetched — the console is serial-only, and the fallback wasm is only
requested if the primary fails to load.

## Artifacts: committed, not release assets

**Decision: the built artifacts and the third-party runtime assets are all
committed to this repo and pinned by `sha256` in `SHA256SUMS`.** v86 and
xterm.js are **vendored**, not fetched from a CDN.

Why:

* The whole point of the repo is that `git clone` + serve + assert works. A
  release-asset route puts a network fetch and a hash check in the hot path of
  the demo, and a CDN route puts a third party in it. Vendored + committed means
  the clean-clone proof has no external dependency at all.
* It costs **6.6 MB**, which is small. The `fx-init` project's convention of
  publishing its *kernel* as a hash-pinned release asset exists because that
  artifact is tens of megabytes — this payload set is not, and the argument does
  not carry over.
* The pins are real anyway (`SHA256SUMS`, and `sha256sum -c` is part of the
  verification below), so anyone who prefers a release-asset mirror can build
  one from this repo without ambiguity about *which* bytes.

## Revisions the shipped guest was built from

Component repos are **not** submodules here — the shipped artifacts are the
anchors. `web/bzImage` and `web/initrd.xz` are pinned by sha256, and the tree
below is the exact revision (and dirty-state) observed at packaging time.

| component | revision | tree at packaging | shipped payload |
|---|---|---|---|
| [fx-core](https://github.com/fixpoint-linux/fx-core) | `d6567de4a3988edb97858e5d82c17483fa0b9080` | clean | 63 static i386 binaries (`fxsh` + the `fx-*` stages) → `/usr/fx-core/bin` |
| [fx-init](https://github.com/fixpoint-linux/fx-init) | `48cae93e3cefcbaa856fcce8c5f983ee7135417e` + **uncommitted** i386 port | dirty | `fx-init` (PID 1), `fxctl`, `fx-activate` |
| [fxstore](https://github.com/fixpoint-linux/fxstore) | `f55a1acf69d77aec92a1eb53f6c8ea836efdba72` + uncommitted i386 port | dirty | hash input only (never executes) |
| [dhake](https://github.com/fixpoint-linux/dhake) | `a76f65d160ae8508bcbdd6b709b4aa6a28e24ebd` + uncommitted `build.zig`/`sandbox.zig` | dirty | `dhake.com` (materializes the rootfs) |
| [dhall-c](https://github.com/fixpoint-linux/dhall-c) | `565d728d147426e747a6e74f0ed09c53331053b1` | clean | hash input only |
| [datalog-dafsa](https://github.com/fixpoint-linux/datalog-dafsa) | `59f7d855bd4d113e59798a0de92b9a2ad386661c` | clean | hash input only |

Two things follow, and both are honest limitations rather than details:

1. **The i386 port of `fx-init`/`fxstore`/`dhake` was uncommitted working-tree
   state** when the guest was captured. Those patches are described in
   `docs/BUILD.md` but are not retrievable as a commit from the remotes; if you
   rebuild from today's `HEAD` you get equivalent binaries, not identical ones.
2. **The store paths are content hashes of the source trees.** The `rdinit=`
   hash in `web/index.html` (`dda2c337…-fx-init`) is the hash of the `fx-init`
   tree as it was at packaging. MEASURED while writing this: re-running the
   provisioning against today's `fx-init` tree yields `651b4e34…`, because that
   tree now carries further fixes. The store is doing exactly what it is
   designed to do — the demo just has to be told the new name
   (`image/build-store.sh` prints it).

**What *is* verified reproducible:** the 63 fx-core binaries in the shipped
image are **byte-identical** to a fresh
`cd fx-core && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall` of
`d6567de` (63/63 sha256 match, measured). And `image/mkinitramfs.sh` produces a
**byte-identical** `initrd.xz` from the same store — two consecutive runs give
the same sha256 (that took the `--reproducible` delta, see `docs/BUILD.md`).

## Layout

```
web/                the page and everything it fetches (committed, no CDN)
  index.html          the page: v86 wiring + the CMDLINE
  bzImage             i386 linux-6.12.19  (sha256 25be0d53…)
  initrd.xz           the store + userland (sha256 83579980…)
  libv86.js v86.wasm seabios.bin         (v86 0.5.470, Apache/BSD 2-clause)
  xterm.mjs xterm.css                    (@xterm/xterm 6.0.0, MIT)
kbuild/             the kernel build recipe (podman, debian:stable)
  build-lean.sh config-i386-lean.txt     what the page ships
  build.sh      config-i386.txt          the earlier untrimmed variant
image/              the guest image
  build-store.sh      provision + activate a store from the i386 userland
  mkinitramfs.sh      assemble initrd.xz (fx-init's M4 builder, adapted)
harness/            boot / drive / assert
  serve.py            gzip-reporting static server (the download number's instrument)
  boot.mjs drive.mjs  v86 in node, serial to stdout / scripted sessions
  assert.mjs          the Playwright proof
docs/               BUILD.md (rebuild), BOOT.md (the boot chain and its evidence)
evidence/           proof-serial.txt, assert-output.txt, proof.png, image-contents.txt
licenses/           v86 (BSD-2-Clause) and xterm.js (MIT) license + package metadata
SHA256SUMS          every committed artifact, verifiable with `sha256sum -c`
```

## Open items (short, honest)

These are *known and unfixed as of the shipped image*. They are listed because a
demo that hides them is not a demo of the real thing.

* **`fx-init: warning: control socket failed` on every boot.** It does not
  affect the boot verdict — the boot path never uses the control socket — but
  the in-guest `fxctl` (`activate`/`rollback`/`shutdown`) is therefore
  unavailable. Root cause not investigated.
* **fx-init's control plane has no virtio-serial under v86.** With no
  `virtio-console` device in this guest, the control socket cannot be reached
  from outside the guest; the demo drives the console over the emulated 8250
  instead. Related to the warning above.
* **Post-pivot there is no `/tmp`.** `pivot_root_to_tmpfs`
  (`fx-init/zig/src/init.zig`) creates `/proc /sys /dev /run /fx /fx/disk
  /lib64 /usr /oldroot` on the new tmpfs root — `/tmp` is not among them, and
  the tmpfs root replaces the initramfs layer that had it. So any `fx-*` stage
  that `mkdtemp`s under a hardcoded `/tmp` fails in the console shell. OBSERVED
  LIVE in this guest: `ls /bin` → `error: Mkdtemp`. It is **pre-existing in
  fx-init's own QEMU image lane** too — that harness only exercises
  `seq | head`, which needs no `/tmp`, so it never surfaced. The assertion
  deliberately uses stages that avoid `/tmp` (`cat`, `cksum`, `seq`, `head`)
  rather than papering over it. Fix is one line either side: add `/tmp` to the
  pivot dir list, or `Mkdir /tmp` in the boot buildfile.
* **`fxsh` is not a `PATH` shell.** It dispatches exactly its 31 `fx-*` pipeline
  stages; `/bin/fxctl` is `fx-shell: unknown stage '/bin/fxctl'`. A module such
  as `realpath` takes its path operand *from the pipeline* (`text_operand`) —
  feeding it as argv is `TooManyArgs` — while `cksum`/`cat` accept a literal
  path. This is why the assertions use `cksum /bin/fxctl`.
* **Guest memory is fixed at 128 MiB** and the initrd is placed at the 64 MiB
  mark by v86's `bzImage` loader, so the initrd must stay well under 64 MiB. It
  is 2.5 MB.
* **The kernel build is not bit-reproducible** — `make` embeds a timestamp. The
  kernel is pinned by sha256; see `docs/BUILD.md`.
* **This guest is an initramfs-only root.** The store lives in ramfs; nothing
  persists across a guest reboot. The disk-store path (`/dev/vda`) exists in
  fx-init but is not wired up here — the console prints
  `disk store: no /dev/vda — using ramfs store` at every boot.

## Licensing

The fixpoint-linux components (`fx-init`, `fx-core`, `fxstore`, `dhake`) carry
their own licenses in their own repositories. The vendored third-party assets
keep theirs, reproduced in `licenses/`: **v86** (BSD-2-Clause, 0.5.470) and
**xterm.js** (`@xterm/xterm` 6.0.0, MIT). `seabios.bin` is SeaBIOS (LGPLv3),
distributed by the v86 project as the emulator's firmware image; it is verified
here against v86's published copy.
