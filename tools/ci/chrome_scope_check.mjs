#!/usr/bin/env node
// Chrome scope check.
//
// The chrome is inherited from cogame-babel and lives in
// client/chrome_common.js; the game block is client/renderer.js. Three
// things have to stay true, and none of them is visible to any other gate:
//
//   1. The game block must not re-declare anything the chrome exports. A
//      game-block `function markBeat` is HOISTED over a chrome alias
//      `var markBeat = C.markBeat` and silently turns every scrub beat into
//      an unlabelled div that never seeks -- every static check stays green
//      (tandem, 2026-08-23).
//   2. The beat builder lives in the chrome and is called markPlyBeat, so
//      the game block must not declare `markBeat` at all.
//   3. chrome_common.js must still carry the copied-region markers the
//      design note names, so a future "tidy-up" that rewrites the inherited
//      chrome fails loudly instead of quietly.
//
// Usage: node tools/ci/chrome_scope_check.mjs [repo root]
import { readFileSync } from "node:fs";
import path from "node:path";

const root = process.argv[2] || process.cwd();
const chromePath = path.join(root, "client", "chrome_common.js");
const gamePath = path.join(root, "client", "renderer.js");
const chrome = readFileSync(chromePath, "utf8");
const game = readFileSync(gamePath, "utf8");

const problems = [];

// ---- 1. the exported surface ------------------------------------------------
const exportBlock = chrome.match(
  /window\.FogChrome\s*=\s*\{([\s\S]*?)\n\s*\};/);
if (!exportBlock) {
  problems.push("client/chrome_common.js does not export window.FogChrome");
}
const exported = exportBlock ?
  [...exportBlock[1].matchAll(/^\s*([A-Za-z_$][\w$]*)\s*:/gm)]
    .map((m) => m[1]) : [];
if (exported.length < 12) {
  problems.push(
    `window.FogChrome exports only ${exported.length} names; the inherited ` +
    "chrome is bigger than that -- was a region dropped?");
}

// Top-level declarations of the game block's IIFE: two-space indented
// `function x` / `var x`.
const declared = new Set();
for (const match of game.matchAll(
    /^ {2}(?:function\s+([A-Za-z_$][\w$]*)|var\s+([A-Za-z_$][\w$]*))/gm)) {
  declared.add(match[1] || match[2]);
}
for (const name of exported) {
  if (declared.has(name)) {
    problems.push(
      `client/renderer.js re-declares "${name}", which ` +
      "client/chrome_common.js exports. Call it through the FogChrome " +
      "alias instead: a hoisted game-block declaration shadows the chrome " +
      "and fails silently (tandem, 2026-08-23).");
  }
}

// ---- 2. no markBeat anywhere in the game block -----------------------------
if (/\bmarkBeat\b/.test(game)) {
  problems.push(
    "client/renderer.js mentions markBeat. The beat builder is " +
    "markPlyBeat and it lives in client/chrome_common.js.");
}
if (!/function\s+markPlyBeat\s*\(/.test(chrome)) {
  problems.push(
    "client/chrome_common.js no longer defines markPlyBeat, so the " +
    "scrubber has no labelled, clickable beats.");
}

// ---- 3. the copied regions are still there ---------------------------------
const REGIONS = ["101-124", "680-733", "735-744", "790-863", "963-970",
  "972-1027", "1029-1048", "1142-1222"];
for (const region of REGIONS) {
  const begin = `BEGIN copied cogame-babel renderer.js ${region}`;
  const end = `END copied cogame-babel renderer.js ${region}`;
  if (!chrome.includes(begin) || !chrome.includes(end)) {
    problems.push(
      `client/chrome_common.js has lost the copied region ${region}. The ` +
      "chrome is byte-copied from cogame-babel d55d999 with exactly six " +
      "named edits; it is not a place to tidy up.");
  }
}
// The six named edits, each marked where it is.
for (const edit of ["EDIT 1", "EDIT 2", "EDIT 3", "EDIT 4", "EDIT 5a",
    "EDIT 5b", "EDIT 6"]) {
  if (!chrome.includes(edit)) {
    problems.push(`client/chrome_common.js has lost its "${edit}" marker.`);
  }
}
// Everything human-facing counts PLIES, not rounds.
if (!/"PLY " \+ \(block \+ 1\)/.test(chrome)) {
  problems.push("the feed block head no longer reads \"PLY n\".");
}

if (problems.length) {
  for (const problem of problems) console.error("::error::" + problem);
  console.error(`chrome scope check FAILED (${problems.length} problem(s))`);
  process.exit(1);
}
console.log(
  `chrome scope check OK: ${exported.length} exported chrome names, ` +
  `${declared.size} game-block declarations, no overlap, ` +
  `${REGIONS.length} copied regions intact`);
