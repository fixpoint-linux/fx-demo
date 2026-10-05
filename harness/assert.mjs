// assert.mjs — Playwright proof that the REAL fixpoint-linux system boots in
// the browser page and that fx-init's own boot verdict reaches the DOM.
//
// Usage: node harness/assert.mjs [baseurl]        (default http://127.0.0.1:8080/)
//
// Playwright is the one dependency this repo does not vendor (it ships a
// browser, not a script). Install it with:
//     npm install playwright && npx playwright install chromium-headless-shell
// Resolution order:
//   1. $PLAYWRIGHT — a path or specifier, e.g.
//        PLAYWRIGHT=/path/to/node_modules/playwright/index.mjs node harness/assert.mjs
//   2. the bare specifier `playwright`, resolved from this directory
//        (as `npm install` above leaves it)
// Either way the *browser* comes from Playwright's own cache
// (~/.cache/ms-playwright) unless PLAYWRIGHT_BROWSERS_PATH says otherwise.
//
// Writes proof.png and proof-serial.txt into the CURRENT directory and exits
// 0 iff every assertion holds.
import fs from "node:fs";

const pw = process.env.PLAYWRIGHT || "playwright";
const { chromium } = await import(pw);

const base = process.argv[2] || "http://127.0.0.1:8080/";
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

const downloaded = [];
page.on("response", async (r) => {
    const len = Number(r.headers()["content-length"] || 0);
    if (len) downloaded.push([r.url().split("/").pop(), len, r.headers()["content-encoding"] || "identity"]);
});

await page.goto(base, { waitUntil: "load" });

// (1) the kernel exec'd fx-init OUT OF THE STORE, and fx-init said so.
await page.waitForFunction(
    () => window.__serial && window.__serial.includes("as init process"),
    null, { timeout: 180000 });
console.log("KERNEL: " + (await page.evaluate(() => (window.__serial.match(/Run .*as init process/) || [""])[0])));

// (2) the console shell service is up (it spawns at ~2s, before the verdict).
await page.waitForFunction(() => window.__serial.includes("fx> "), null, { timeout: 180000 });
console.log("PROMPT SEEN: fx> ");

// Type through xterm.js (the real keyboard path -> serial0_send).
async function typeCmd(cmd) {
    await page.click(".xterm-helper-textarea");
    for (const ch of cmd) await page.keyboard.type(ch, { delay: 5 });
    await page.keyboard.press("Enter");
    await page.waitForTimeout(4000);
}

// /etc/hostname exists ONLY if dhake materialized the rootfs from the store
// (the initramfs ships no /etc and the ROOTDIR overlay is empty) — so this
// line is the materialization proof, read through the guest's own shell.
await typeCmd("cat /etc/hostname");
// /bin/fxctl is a SYMLINK dhake created into the store (the buildfile's `bin`
// target: Rm + Symlink per package).  fxsh dispatches only its 31 fx-* stages,
// so a PATH exec is not available; `cksum` is a file_operand stage and takes
// the path literally, reading THROUGH the link — a dangling or absent link
// fails instead.  MEASURED host-side: /bin/fxctl -> 210768 bytes,
// /bin/init -> 826524 bytes (the store files' own sizes).
await typeCmd("cksum /bin/fxctl");
await typeCmd("cksum /bin/init");
// a second /etc file from the same Copy sweep.
await typeCmd("cat /etc/passwd");
// the two-stage pipeline over two separate /bin binaries (fx-seq | fx-head).
await typeCmd("seq 1 3 | head -n 2");
// THE /tmp REGRESSION (fx-init 675e801).  Post-pivot the tmpfs root carried
// no /tmp — and every `fx-*` stage that takes a path actually opens a
// `mkdtemp("/tmp/<stage>-XXXXXX")` scratch dir, so the shipped guest answered
// `ls /bin` with `error: Mkdtemp` (the OLD image's own serial, quoted in
// evidence/tmp-fix-before-after.txt).  fx-ls mkdtemps too, so `ls /bin`
// producing rows at all is the fix; `ls /tmp` then LISTS the scratch dir the
// previous fx-ls left there, which is the writable-/tmp proof rather than a
// mere existence check.  Asserted on window.__serial — the full 8250 capture,
// not the visible viewport — because the listing is several rows.
await typeCmd("ls /bin");
await typeCmd("ls /tmp");

// (3) fx-init's own boot verdict, awaited in the page.
let bootOk = false;
for (let i = 0; i < 60 && !bootOk; i++) {
    bootOk = await page.evaluate(() => window.__serial.includes("fx-init: boot-ok"));
    if (!bootOk) await page.waitForTimeout(1000);
}

const serial = await page.evaluate(() => window.__serial);
const rowsArr = await page.evaluate(() => [...document.querySelectorAll(".xterm-rows > div")].map((d) => d.textContent.replace(/\u00a0/g, " ").replace(/\s+$/, "")));
const rows = rowsArr.join("\n");
console.log("---- serial (guest 8250), tail ----");
console.log(serial.split("\n").slice(-14).join("\n"));
console.log("---- .xterm-rows textContent ----");
console.log(JSON.stringify(rows));

const verdict = (serial.match(/fx-init: boot-ok v\d+/) || [""])[0];
const lines = rowsArr.map((l) => l.trim());
const a1 = verdict !== "";                                   // fx-init's own verdict, in the page
const a2 = serial.includes("pivoted to tmpfs root");         // the M4 initramfs pivot ran
const a3 = serial.includes("Run /fx/store/") && serial.includes("as init process"); // fx-init exec'd out of the store
const a4 = lines.some((l) => l.includes("fixbox"));          // dhake materialized /etc/hostname (fx-cat prints it with NO trailing newline, so the row runs into the next prompt)
const a5 = rows.includes("seq 1 3 | head -n 2");
const a6 = rows.includes("210768 /bin/fxctl");
const a6b = rows.includes("826524 /bin/init");
// the /tmp fix, in two halves: `ls /bin` produced ROWS of /bin (it used to be
// `error: Mkdtemp`), and `ls /tmp` shows a `fx-ls-XXXXXX` scratch dir inside
// /tmp — i.e. mkdtemp succeeded and the directory is writable.  The `!Mkdtemp`
// half is what fails on the pre-675e801 image.
const a8 = serial.includes('"name":"init"') && !serial.includes("Mkdtemp");
const a9 = /"name":"fx-ls-[A-Za-z0-9]{6}"/.test(serial);
const a7 = rows.includes("root:x:0:0:");                     // a second dhake-materialized /etc file
const hasOne = lines.includes("1");
const hasTwo = lines.includes("2");
const hasThree = lines.includes("3");                        // must NOT appear: head cut the stream
console.log("ASSERT fx-init-boot-ok-in-page:", a1, "(" + verdict + ")");
console.log("ASSERT pivoted-to-tmpfs:", a2);
console.log("ASSERT rdinit-from-store:", a3);
console.log("ASSERT dhake-materialized-/etc (rendered 'fixbox'):", a4);
console.log("ASSERT dhake-/bin/fxctl-symlink-reads-through (in-guest size 210768):", a6);
console.log("ASSERT dhake-/bin/init-symlink-reads-through (in-guest size 826524):", a6b);
console.log("ASSERT dhake-materialized-/etc/passwd:", a7);
console.log("ASSERT typed-pipeline-in-terminal:", a5, " output-1:", hasOne, " output-2:", hasTwo, " 3-filtered:", !hasThree);
console.log("ASSERT post-pivot-/tmp-writable (ls /bin runs, no Mkdtemp):", a8);
console.log("ASSERT post-pivot-/tmp-lists-a-mkdtemp-scratch-dir (ls /tmp):", a9);

console.log("---- downloaded resources (content-length as fetched) ----");
let total = 0;
for (const [name, len, enc] of downloaded) { total += len; console.log(`${len.toString().padStart(9)}  ${name} (${enc})`); }
console.log(`TOTAL FETCHED BY THE BROWSER (bytes): ${total}`);

await page.screenshot({ path: "proof.png" });
fs.writeFileSync("proof-serial.txt", serial);
await browser.close();
process.exit(a1 && a2 && a3 && a4 && a5 && a6 && a6b && a7 && a8 && a9 && hasOne && hasTwo && !hasThree ? 0 : 1);
