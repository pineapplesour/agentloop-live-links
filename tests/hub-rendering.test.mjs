import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const root = new URL("../", import.meta.url);

test("secondary Ralfi links live in the final collapsed group", async () => {
  const data = JSON.parse(await readFile(new URL("links.json", root), "utf8"));
  const finalGroup = data.groups.at(-1);

  assert.equal(finalGroup.collapsed, true);
  assert.deepEqual(
    finalGroup.items.map((item) => item.id),
    ["ralph-live", "ralph-checkin-final-live", "carebridge-plain-live"],
  );
  assert.deepEqual(
    data.groups.slice(0, -1).flatMap((group) => group.items).map((item) => item.id),
    ["maeum-atrium", "maeum-atrium-dev"],
  );
});

test("collapsed groups use a native closed details control", async () => {
  const html = await readFile(new URL("index.html", root), "utf8");

  assert.match(html, /group\.collapsed/);
  assert.match(html, /document\.createElement\("details"\)/);
  assert.match(html, /document\.createElement\("summary"\)/);
  assert.doesNotMatch(html, /details\.open\s*=\s*true/);
});
