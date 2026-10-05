# What actually happens at boot

The demo is not a mock-up: the page boots a real kernel, that kernel exec's
fx-init **out of a content-addressed store**, fx-init pivots and dispatches
`dhake`, dhake materializes the rootfs, and one of the activated services is the
fx-core shell on the serial console. This file is the chain, with the evidence
for each link.

## The kernel command line

The page sets exactly one thing that matters — where PID 1 comes from:

```
console=ttyS0 tsc=unstable \
rdinit=/fx/store/dda2c337b5145e76a4b8845dd84f1054f59beb56403dd2b931e79f3ad526c4e6-fx-init/fx-init \
fx.store=/fx/store
```

`rdinit=` names a path **inside the store**, which is the M4 initramfs path: no
disk image, no bootloader, no `init` on the initramfs. `tsc=unstable` keeps the
kernel from trusting a TSC that v86's emulation does not keep in sync.

## The chain, and the line each step prints

```
Run /fx/store/dda2c337…-fx-init/fx-init as init process                      <- kernel: rdinit resolved
fx-init: store from kernel command line fx.store=/fx/store                   <- fx-init: its store root
fx-init: boot start store /fx/store                                          <- the boot decision begins
fx-init: disk store: no /dev/vda — using ramfs store                         <- no virtio disk, so the store is the ramfs one
fx-init: pivot_root EINVAL (initramfs root is the namespace root) — switch_root fallback (MS_MOVE + chroot) applied
fx-init: pivoted to tmpfs root (magic 0x1021994)                             <- the M4 pivot ran and VERIFIED the fs magic
fx-init: warning: control socket failed                                      <- OPEN ITEM, see the README
fx>                                                                          <- the console service (fxsh) spawned ~2s in
…
fx-init: boot-ok v7                                                          <- fx-init's own verdict
```

`boot-ok` is emitted by fx-init's own `evaluate_boot_ok`
(`fx-init/zig/src/init.zig`), and only when **every service of the activated
generation reported started inside the grace window** (15 s here, from
`m3/config-console.dhall`). Nothing on the host computes it.

## Why each assertion is evidence, not decoration

`harness/assert.mjs` types into the guest through xterm.js's real keyboard path
(`serial0_send` → the emulated 8250 → the kernel's line discipline → fxsh) and
asserts on the **rendered** terminal (`.xterm-rows`, one row per line) as well
as on `window.__serial`.

| assertion | what makes it non-trivial |
|---|---|
| `fx-init: boot-ok` in the page | fx-init's own decision, requiring every service started. The page cannot synthesize it. |
| `pivoted to tmpfs root` | fx-init's `pivot_root_to_tmpfs` ran and matched `TMPFS_MAGIC`. It is a *measured* result, not a log line it prints unconditionally. |
| `Run /fx/store/… as init process` | the kernel's own line: PID 1 was exec'd from the store, not from the initramfs. |
| `cat /etc/hostname` → `fixbox` | the initramfs ships **no `/etc`** and the ROOTDIR overlay is empty, so the file can only exist because dhake's `etc` target copied it out of the store's generation dir. |
| `cksum /bin/fxctl` → `1217607440 210768` | matches the host's `cksum` of `store/937bc…-fxctl/fxctl` — **same CRC, same size**. The guest is reading *through* the symlink dhake created (the buildfile's `bin` target: `Rm` + `Symlink` per package) into the content-addressed store. A dangling or missing link fails. |
| `cksum /bin/init` → `2017035490 825300` | same, for the store's fx-init — i.e. `/bin/init` resolves to the very binary the kernel booted. |
| `cat /etc/passwd` → `root:x:0:0:…` | a second file from the same `Copy` sweep; one lucky file could be coincidence, a whole directory less so. |
| `seq 1 3 \| head -n 2` → `1`, `2`, never `3` | a two-process pipeline (`fx-seq \| fx-head`) over two separate static i386 binaries with a real `fork`/`pipe`/`execve`. `head` closing the read end early is what filters `3`. This is exactly what blink-wasm could not do. |

The run also captures the browser's fetch accounting (see the README), and
`evidence/proof.png` is the screenshot of the same session — read by an
independent vision model, which returned the transcript line for line, so the
page really *renders* it and the assertions are not reading a hidden buffer.

## The two harnesses are different instruments

* `harness/boot.mjs` — v86 in node, serial to stdout; exits 0 iff `boot-ok`
  appears. This is the cheap "does the guest boot at all" gate.
* `harness/drive.mjs` — v86 in node, sending one command per observed `fx> `;
  a scripted console session without a browser.
* `harness/assert.mjs` — headless chromium against the real page. This is the
  one that exercises the whole stack *as shipped* (page → v86 in wasm →
  xterm.js → the guest) and it is the proof the README quotes.

## Reproducing the guest's own numbers

```sh
node harness/boot.mjs web/bzImage web/initrd.xz "$(CMD)" 60 /tmp/serial.txt
```

The store dir hashes are content hashes of the source trees the store was
activated from. If you rebuild the userland (see `docs/BUILD.md`), the
`dda2c337…-fx-init` segment of the command line will be **different** — the new
hash is printed by `image/build-store.sh`, and that is the string to put into
`web/index.html`'s `CMDLINE`. Nothing else in the page is revision-dependent.
