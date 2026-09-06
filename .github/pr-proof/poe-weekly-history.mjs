import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
const repoRoot = new URL("../../", import.meta.url);
const file = "Sources/CodexBarCore/Resources/Plugins/poe.js";
const source =
  process.argv[2] === "baseline"
    ? execFileSync("git", ["show", `c15f736ef:${file}`], { encoding: "utf8", cwd: repoRoot })
    : fs.readFileSync(new URL(file, repoRoot), "utf8");
let provider;
vm.runInNewContext(source, { defineProvider: (p) => (provider = p) });
const reference = 1785816000000,
  cutoff = reference - 7 * 86400000;
const entries = [
  { creation_time: reference / 1000, cost_points: 10, cost_usd: 0.01 },
  { creation_time: cutoff / 1000, cost_points: 20, cost_usd: 0.02 },
  { creation_time: cutoff / 1000 - 1, cost_points: 100, cost_usd: 0.1 },
  { creation_time: cutoff / 1000 - 13 * 86400, cost_points: 900, cost_usd: 0.9 },
];
async function fetch(now, rows = entries) {
  const calls = [];
  const snapshot = await provider.fetchUsage({
    date: { now: () => new Date(now), nowMillis: () => now },
    format: { number: (n, options) => new Intl.NumberFormat("en-US", options).format(n) },
    http: {
      getJSON: async (url) => {
        calls.push(url);
        return {
          status: 200,
          json: url.includes("current_balance") ? { current_point_balance: 2500 } : { data: rows },
        };
      },
    },
  });
  assert.equal(calls.length, 2);
  return snapshot;
}
const current = await fetch(reference);
const row = (snapshot, label) => snapshot.details[0].rows.find((r) => r.label === label);
console.log(JSON.stringify({ case: "sparse history and cutoff", rows: current.details[0].rows.slice(0, 4) }));
assert.equal(row(current, "Last 7 days").value, "30 points");
assert.equal(row(current, "Last 7 days").secondaryValue, "2 requests · $0.03");
assert.equal(row(current, "Last 30 days").value, "1,030 points");
assert.equal(row(current, "Last 30 days").secondaryValue, "4 requests · $1.03");
assert.equal(row(current, "Today").value, "10 points");
assert.equal(
  current.details[0].chart.points.reduce((sum, p) => sum + p.value, 0),
  1030,
);
const later = await fetch(reference + 8 * 86400000);
console.log(JSON.stringify({ case: "eight days later", rows: later.details[0].rows.slice(0, 4) }));
assert.equal(row(later, "Last 7 days").value, "0 points");
assert.equal(row(later, "Last 7 days").secondaryValue, "0 requests");
assert.equal(row(later, "Last 30 days").value, "1,030 points");
const expired = await fetch(reference + 31 * 86400000);
assert.equal(expired.details[0].rows.length, 1);
assert.equal(row(expired, "Current balance").value, "2,500 points");
console.log(
  "PASS: sparse history, exact 7-day cutoff, one-second exclusion, empty week, 30-day totals, chart, and balance retention",
);
