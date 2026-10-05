// drive.mjs — boot the fx-demo guest under v86 and DRIVE the fxsh console
// service over the emulated 8250 serial line (the console service's terminal).
//
// This is the scripted-session harness: it sends one command per observed
// `fx> ` prompt and keeps the whole capture. assert.mjs is the browser
// equivalent (real keyboard -> xterm.js -> serial0_send).
//
// Usage: node harness/drive.mjs <cmds-file> [secs] [serial-out] \
//            [bzImage] [initrd] [cmdline]
//   cmds-file: one console command per line; `#` starts a comment line.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEB = path.join(HERE, "..", "web");
// the SAME UMD bundle the page loads (see boot.mjs)
const { V86 } = createRequire(import.meta.url)("../web/libv86.js");

const CMDLINE =
    "console=ttyS0 tsc=unstable" +
    " rdinit=/fx/store/dda2c337b5145e76a4b8845dd84f1054f59beb56403dd2b931e79f3ad526c4e6-fx-init/fx-init" +
    " fx.store=/fx/store";

const [cmdsFile, secs, out, bz = path.join(WEB, "bzImage"),
       initrd = path.join(WEB, "initrd.xz"), cmdline = CMDLINE] = process.argv.slice(2);
if (!cmdsFile) {
    process.stderr.write("usage: node harness/drive.mjs <cmds-file> [secs] [serial-out]\n");
    process.exit(2);
}
const cmds = fs.readFileSync(cmdsFile, "utf8").split("\n").filter((l) => l.length && !l.startsWith("#"));
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
    memory_size: 128 * 1024 * 1024,
    autostart: true,
    disable_speaker: true,
    screen: { container: null },
});

let serial = "";
let pending = cmds.slice();
const PROMPT = "fx> ";
let seen = 0;
let bootOk = false;
emulator.add_listener("serial0-output-byte", (byte) => {
    serial += String.fromCharCode(byte);
    if (!bootOk && serial.includes("fx-init: boot-ok")) {
        bootOk = true;
        console.log("[drive] boot-ok seen");
    }
    const idx = serial.indexOf(PROMPT, seen);
    if (idx >= 0 && pending.length) {
        seen = idx + PROMPT.length;
        const cmd = pending.shift();
        console.log(`[drive] prompt -> sending: ${cmd}`);
        setTimeout(() => emulator.serial0_send(cmd + "\n"), 200);
    }
});

setTimeout(async () => {
    if (out) fs.writeFileSync(out, serial);
    console.log(`[drive] captured ${serial.length} serial bytes; ${pending.length} commands unsent`);
    await emulator.destroy();
    process.exit(pending.length === 0 && bootOk ? 0 : 1);
}, (secs ? Number(secs) : 90) * 1000);
