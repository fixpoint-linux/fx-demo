// boot.mjs — headless v86 boot of the fx-demo guest, serial -> stdout/file.
//
// This is the node twin of the page: the same bzImage, the same initrd.xz,
// the same cmdline, the same emulator bundle. It exists so a boot can be
// observed without a browser (and so a failing boot can be diffed against
// the page's).
//
// Usage: node harness/boot.mjs [bzImage] [initrd] [cmdline] [seconds] [serial-out]
//   defaults: web/bzImage, web/initrd.xz, the CMDLINE the page uses, 30s, no file
//   exits 0 iff the serial carries fx-init's own boot verdict
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEB = path.join(HERE, "..", "web");

// web/libv86.js is the UMD bundle the page loads as a classic script. In a
// CommonJS context the same file also exports V86, so this harness drives the
// SAME emulator build the page does — no second copy of v86 in the repo.
const { V86 } = createRequire(import.meta.url)("../web/libv86.js");

// The cmdline the page uses (index.html CMDLINE), kept identical here. The
// rdinit path names fx-init OUT OF THE CONTENT-ADDRESSED STORE — the hash is
// the store dir the shipped initrd.xz carries (see docs/BOOT.md).
const CMDLINE =
    "console=ttyS0 tsc=unstable" +
    " rdinit=/fx/store/dda2c337b5145e76a4b8845dd84f1054f59beb56403dd2b931e79f3ad526c4e6-fx-init/fx-init" +
    " fx.store=/fx/store";

const argv = process.argv.slice(2);
const bz = argv[0] || path.join(WEB, "bzImage");
const initrd = argv[1] || path.join(WEB, "initrd.xz");
const cmdline = argv[2] || CMDLINE;
const secs = argv[3] || "30";
const out = argv[4] || "";

const buf = (p) => {
    const b = fs.readFileSync(p);
    return { buffer: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) };
};

const emulator = new V86({
    wasm_path: path.join(WEB, "v86.wasm"),
    bios: buf(path.join(WEB, "seabios.bin")),
    bzimage: buf(bz),
    initrd: buf(initrd),
    cmdline,
    // v86's bzImage loader places the initrd at the 64 MiB mark, so guest RAM
    // must exceed 64 MiB + initrd size (at 64 MiB it throws RangeError).
    memory_size: 128 * 1024 * 1024,
    autostart: true,
    disable_speaker: true,
    screen: { container: null },
});

let serial = "";
emulator.add_listener("serial0-output-byte", (byte) => {
    const ch = String.fromCharCode(byte);
    serial += ch;
    process.stdout.write(ch);
});

setTimeout(async () => {
    if (out) fs.writeFileSync(out, serial);
    process.stderr.write(`\n[boot.mjs] captured ${serial.length} serial bytes${out ? " -> " + out : ""}\n`);
    await emulator.destroy();
    process.exit(serial.includes("fx-init: boot-ok") ? 0 : 1);
}, (secs ? Number(secs) : 30) * 1000);
