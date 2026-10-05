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
simulating fixpoint. **Total download: 3,926,476 bytes (3.74 MiB).**

```
Run /fx/store/85adaec9…-fx-init/fx-init as init process
fx-init: store from kernel command line fx.store=/fx/store
fx-init: disk store: no /dev/vda — using ramfs store
fx-init: pivot_root EINVAL (initramfs root is the namespace root) — switch_root fallback (MS_MOVE + chroot) applied
fx-init: pivoted to tmpfs root (magic 0x1021994)
fx-init: warning: no control channel: /run/fx/control.sock (socket failed: Function not implemented — this kernel has no socket layer: CONFIG_NET is not set) and no virtio control port — fxctl cannot connect in this guest
fx> cat /etc/hostname
fixboxfx> cksum /bin/fxctl
1217607440 210768 /bin/fxctl
fx> cksum /bin/init
3239201204 826524 /bin/init
fx> cat /etc/passwd
root:x:0:0::/home/root:/bin/sh
fx> fx-init: boot-ok v5
seq 1 3 | head -n 2
1
2
fx> ls /bin
{"name":"dhake","size":402376,"mode":493}
{"name":"fakesvc","size":1106800,"mode":493}
{"name":"fx-activate","size":952196,"mode":493}
{"name":"fxctl","size":210768,"mode":493}
{"name":"init","size":826524,"mode":493}
fx> ls /tmp
{"name":"fx-ls-OfIMGE","size":140,"mode":448}
{"name":"fx-ls-cgNbjD","size":200,"mode":448}
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

Exit 0 and every assertion below is the claim; `proof.png` and
`proof-serial.txt` are written to the current directory. **The run quoted in
`evidence/` was made this way, against a fresh `git clone` of the pushed repo,
not from a working tree** — `evidence/assert-output.txt` is its verbatim
transcript, including the scratch dir, the `sha256sum -c SHA256SUMS` result and
the port used. (That clone was at `8e549bc`, the commit that introduced the
shipped `web/` bytes; `SHA256SUMS` passes and `web/` is byte-identical on the
head of `main`.)

```
ASSERT fx-init-boot-ok-in-page: true (fx-init: boot-ok v5)
ASSERT pivoted-to-tmpfs: true
ASSERT rdinit-from-store: true
ASSERT dhake-materialized-/etc (rendered 'fixbox'): true
ASSERT dhake-/bin/fxctl-symlink-reads-through (in-guest size 210768): true
ASSERT dhake-/bin/init-symlink-reads-through (in-guest size 826524): true
ASSERT dhake-materialized-/etc/passwd: true
ASSERT typed-pipeline-in-terminal: true  output-1: true  output-2: true  3-filtered: true
ASSERT post-pivot-/tmp-writable (ls /bin runs, no Mkdtemp): true
ASSERT post-pivot-/tmp-lists-a-mkdtemp-scratch-dir (ls /tmp): true
TOTAL FETCHED BY THE BROWSER (bytes): 3926476
```

`docs/BOOT.md` explains why each of those is evidence rather than decoration.
The last two are the regression test for the `/tmp` fix — `evidence/
tmp-fix-before-after.txt` is the same assertion run against the **previous**
image, where both are `false` and the guest answers `ls /bin` with
`error: Mkdtemp`.

## The numbers (MEASURED, not estimated)

3,926,476 bytes is not a sum of file sizes: it is the sum of the
`content-length` of every response the browser actually received in the passing
run, with the server applying `Content-Encoding: gzip`.

| file | raw | sent |
|---|---|---|
| `initrd.xz` — the store + the 63 fx-core i386 binaries + fx-init | 2,498,888 | 2,498,888 (xz: incompressible) |
| `v86.wasm` | 2,007,347 | 380,456 |
| `bzImage` (i386, linux-6.12.19 `tinyconfig` + fragment) | 795,136 | 795,136 (extension-less: the server does not gzip it) |
| `libv86.js` | 359,825 | 93,787 |
| `xterm.mjs` | 344,970 | 88,463 |
| `seabios.bin` | 131,072 | 65,607 |
| `xterm.css` | 7,112 | 2,502 |
| `index.html` | 2,755 | 1,468 |
| | | **3,926,476** |

Same page served with `identity` encoding: 6,147,105 bytes (the same eight
assets uncompressed). For scale, a `qemu-wasm` route to the same guest is
~40 MB raw / ~10–13 MB compressed.

**Caveat, stated not hidden:** 169 bytes of that total is a single response
chromium makes that the page's server does *not* serve (a UUID path; the
server's own request log lists only the 8 assets). Excluding it, the page's own
assets total **3,926,307** bytes. `vgabios.bin` and `v86-fallback.wasm` are
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
below is the exact revision (all **clean, committed** trees this time — the
earlier guest had to be captured from uncommitted working-tree patches in three
of the six repos) observed at packaging time.

| component | revision | tree at packaging | shipped payload |
|---|---|---|---|
| [fx-core](https://github.com/fixpoint-linux/fx-core) | `669187010053b8ea37f179756b06dad73043e150` | clean | 63 static i386 binaries (`fxsh` + the `fx-*` stages) → `/usr/fx-core/bin` |
| [fx-init](https://github.com/fixpoint-linux/fx-init) | `675e801cdb7441cc0abf35a8fcee10a7c6bfd468` | clean | `fx-init` (PID 1), `fxctl`, `fx-activate` |
| [fxstore](https://github.com/fixpoint-linux/fxstore) | `f7962b681c6405d539baf6f41e93bf26e5739f55` | clean | hash input only (never executes) |
| [dhake](https://github.com/fixpoint-linux/dhake) | `12dc4fbc477c089fbade2ad20372e2f71a624db0` | clean | `dhake.com` (materializes the rootfs) |
| [dhall-c](https://github.com/fixpoint-linux/dhall-c) | `565d728d147426e747a6e74f0ed09c53331053b1` | clean | hash input only |
| [datalog-dafsa](https://github.com/fixpoint-linux/datalog-dafsa) | `59f7d855bd4d113e59798a0de92b9a2ad386661c` | clean | hash input only |

**The store paths are content hashes of the source trees.** The `rdinit=` hash
in `web/index.html` (`85adaec9…-fx-init`) is the hash of the `fx-init` tree at
`675e801`; the `dhake` store dir names the tree fx-init *vendors*
(`fx-init/vendor/dhake`, `eb16bcb`) even though the shipped `dhake.com` is built
from the sibling at `12dc4fb` — the store names its inputs, it does not vouch
for the binary you put in the directory. Re-running the provisioning against a
different `fx-init` tree yields a different name, which is the store doing its
job; `image/build-store.sh` prints the one to use.

**What is verified reproducible** (all MEASURED this packaging):

* every binary in the shipped image is **byte-identical** to a fresh clean-tree
  build — 63/63 fx-core sha256 matches, plus `fx-init`, `fx-activate`, `fxctl`,
  `dhake.com` and `fakesvc` (each image copy vs the build of the commit in the
  table above);
* `image/mkinitramfs.sh` produces a **byte-identical** `initrd.xz` from the
  same store — two consecutive runs give the same sha256 (that took the
  `--reproducible` delta, see `docs/BUILD.md`);
* the store dirs are stable across repeated `activate_paths` runs against
  quiescent trees (two runs, identical closure).

## Layout

```
web/                the page and everything it fetches (committed, no CDN)
  index.html          the page: v86 wiring + the CMDLINE
  bzImage             i386 linux-6.12.19  (sha256 25be0d53…)
  initrd.xz           the store + userland (sha256 15f82729…)
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
evidence/           the clean-clone run: assert-output.txt, proof.png,
                    proof-serial.txt (the guest's 8250 capture), proof-png-vision-read.txt
                    (an independent vision-model read of the screenshot), image-contents.txt,
                    tmp-fix-before-after.txt (the /tmp assertion vs the PREVIOUS image)
licenses/           v86 (BSD-2-Clause) and xterm.js (MIT) license + package metadata
SHA256SUMS          every committed artifact, verifiable with `sha256sum -c`
```

## Fixed since the previous image (the three items it listed as OPEN)

The previous guest shipped components built *before* these commits, so it
reported all three of these as open. Each is now fixed upstream and in this
image; the fix is quoted in the run above, and `evidence/tmp-fix-before-after.txt`
is the assertion run against the **previous** image next to this one's.

* **Post-pivot there was no `/tmp` — FIXED (fx-init `675e801`).** The old
  `pivot_root_to_tmpfs` created `/proc /sys /dev /run /fx /fx/disk /lib64 /usr
  /oldroot` on the new tmpfs root and `/tmp` was not among them, so the tmpfs
  root — which *replaces* the initramfs layer that had it — had no `/tmp` at
  all. Nine `fx-*` stages `mkdtemp` a hardcoded `/tmp/<stage>-XXXXXX` template,
  so the guest answered `ls /bin` with `error: Mkdtemp` and `cksum /tmp` with
  `cannot open '/tmp'` + `error: OpenFailed`. `init.zig` now creates
  `/newroot/tmp` with `mkdir(0o1777)` **and** `chmod(0o1777)` (the umask masks
  `mkdir`'s mode) — deliberately not folded into the shared dir list, which is
  `0755`; the mode is the point. MEASURED in this guest: `ls /bin` now returns
  its five rows and `ls /tmp` lists the `fx-ls-XXXXXX` scratch dirs of the
  preceding commands (i.e. the directory is not merely present but *used*).
  That is exactly the pair of assertions added to `harness/assert.mjs` — this
  bug had no fireable regression test in its own repo (fx-init's console lane
  drives only `seq | head`, which needs no `/tmp`), so the demo's assertion is
  where one now lives.
* **The control-socket warning was uninformative — FIXED (fx-init `675e801`).**
  The *behaviour* it reports is unchanged and is still open (next section): this
  kernel has no socket layer. What is fixed is the line. It was
  `fx-init: warning: control socket failed`; it is now
  `fx-init: warning: no control channel: /run/fx/control.sock (socket failed:
  Function not implemented — this kernel has no socket layer: CONFIG_NET is not
  set) and no virtio control port — fxctl cannot connect in this guest`, naming
  the path, the failing step, the errno, the structural cause and the
  consequence. `setup_ctrl` now records the failing step and its errno
  (`ctrlFail`) instead of returning a bare `-1`.
* **`fxsh`'s unknown-stage error was unhelpful — FIXED (fx-core `6691870`).**
  The refusal itself is correct and stays (below); the message now says why:
  `fx-shell: unknown stage '<name>' (not one of the 31 pipeline stages): a stage
  runs only when its command declares a typed signature, so the line can be
  typechecked before anything runs — fxsh does NOT execute arbitrary PATH
  binaries. The stage name has no 'fx-' prefix (the binary fx-ls is the stage
  `ls`).` The error *value* is unchanged (`error.UnknownCommand`).

## Open items (short, honest)

These are *known and unfixed as of the shipped image*. They are listed because a
demo that hides them is not a demo of the real thing.

* **The control plane cannot work in this guest — the pinned kernel has no
  socket layer (still open; a kernel change, not a code one).** fx-init *does*
  serve the control protocol on a UNIX socket (`/run/fx/control.sock`, and the
  `tests/fxinit_boot.sh` lane drives it), but `CONFIG_UNIX` depends on
  `CONFIG_NET`, the lean config is `# CONFIG_NET is not set`
  (`kbuild/config-i386-lean.txt:616`), and with `NET` off the kernel stubs the
  whole socket layer, so `socket(2)` returns `ENOSYS`. The `--enable UNIX` the
  build script used to pass was dropped **silently** by `olddefconfig` —
  corrected in `kbuild/build*.sh` and documented in `docs/BUILD.md`. MEASURED
  in this guest: the errno is reported verbatim by the rebuilt fx-init (the line
  quoted above). It does not affect the boot verdict — the boot path never uses
  the control socket — but it cannot be worked around in-guest: the in-guest
  `fxctl` (`activate`/`rollback`/`shutdown`) is unavailable because no process
  here can create a socket. The real fix is a kernel rebuild with `CONFIG_NET=y`
  (i.e. a different, much larger kernel than the one this demo ships).
* **fx-init's control plane has no virtio-serial under v86 either.** Separate
  from the above: with no `virtio-console` device in this guest there is no
  vport for the *other* control transport fx-init supports (the one
  `tests/qemu_ctrl.sh` drives), so neither channel exists here and the demo
  drives the console over the emulated 8250 instead.
* **`fxsh` is not a `PATH` shell, by design.** It dispatches exactly its 31
  `fx-*` pipeline stages and refuses everything else; `/bin/fxctl` is an
  unknown stage. 32 of the 63 shipped binaries are therefore unreachable from
  the console. That is the contract — a line runs only if it typechecks — not a
  defect: a PATH fallback would run commands whose stage-to-stage shapes were
  never checked. A module such as `realpath` takes its path operand *from the
  pipeline* (`text_operand`) — feeding it as argv is `TooManyArgs` — while
  `cksum`/`cat` accept a literal path. This is why the assertions use
  `cksum /bin/fxctl`.
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
