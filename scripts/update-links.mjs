#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const linksPath = resolve(root, "links.json");

const args = new Map();
for (let index = 2; index < process.argv.length; index += 1) {
  const item = process.argv[index];
  if (!item.startsWith("--")) continue;
  const key = item.slice(2);
  const next = process.argv[index + 1];
  if (!next || next.startsWith("--")) {
    args.set(key, "true");
  } else {
    args.set(key, next);
    index += 1;
  }
}

const base = String(args.get("base") || "").replace(/\/+$/, "");
if (!/^https:\/\/[-a-z0-9]+\.trycloudflare\.com$/i.test(base)) {
  console.error("Usage: node scripts/update-links.mjs --base https://your-tunnel.trycloudflare.com [--commit]");
  process.exit(2);
}

const data = JSON.parse(await readFile(linksPath, "utf8"));
data.generatedAt = new Date().toISOString();
data.tunnelBase = base;

for (const group of data.groups || []) {
  for (const item of group.items || []) {
    const url = new URL(item.href);
    item.href = `${base}${url.pathname}${url.search}`;
  }
}

await writeFile(linksPath, `${JSON.stringify(data, null, 2)}\n`);
console.log(`updated links.json -> ${base}`);

if (args.has("commit")) {
  execFileSync("git", ["add", "links.json"], { cwd: root, stdio: "inherit" });
  execFileSync("git", ["commit", "-m", `Update live tunnel links ${data.generatedAt}`], { cwd: root, stdio: "inherit" });
  execFileSync("git", ["push"], { cwd: root, stdio: "inherit" });
}
