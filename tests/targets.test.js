// --targets is what the panel's pickers are built from: the screens you can
// pin an assignment to, and the special workspaces that currently exist.
//
// It must agree with --monitor-keys, because a key shown in the panel and a key
// the launcher resolves against have to be the same string.

const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const SCRIPT = path.join(__dirname, "..", "auto-workspace.sh")

function run(args, input) {
  const opts = { encoding: "utf8" }
  if (input === undefined) opts.stdio = ["ignore", "pipe", "pipe"]
  else opts.input = input
  return execFileSync("/usr/bin/bash", [SCRIPT, ...args], opts)
}

function hyprlandRunning() {
  try {
    execFileSync("hyprctl", ["monitors", "-j"], { encoding: "utf8" })
    return true
  } catch {
    return false
  }
}

test("--targets prints parseable JSON with monitors and specials", (t) => {
  if (!hyprlandRunning()) return t.skip("no running Hyprland")
  const out = JSON.parse(run(["--targets"]))
  assert.ok(Array.isArray(out.monitors), "monitors should be an array")
  assert.ok(Array.isArray(out.specials), "specials should be an array")
})

test("--targets monitor keys match --monitor-keys exactly", (t) => {
  if (!hyprlandRunning()) return t.skip("no running Hyprland")
  const out = JSON.parse(run(["--targets"]))
  const keys = run(["--monitor-keys"]).split("\n").filter(l => l.length > 0)
  assert.deepEqual(out.monitors.map(m => m.key), keys)
})

test("--targets carries the connector name for display", (t) => {
  if (!hyprlandRunning()) return t.skip("no running Hyprland")
  const out = JSON.parse(run(["--targets"]))
  for (const monitor of out.monitors) {
    assert.equal(typeof monitor.key, "string")
    assert.ok(monitor.key.length > 0, "key should not be empty")
    assert.ok(monitor.name.length > 0, "connector name should not be empty")
  }
})

test("--targets lists special workspaces without their special: prefix", (t) => {
  if (!hyprlandRunning()) return t.skip("no running Hyprland")
  const out = JSON.parse(run(["--targets"]))
  for (const special of out.specials) {
    assert.equal(typeof special, "string")
    assert.ok(special.length > 0, "special name should not be empty")
    assert.ok(!special.startsWith("special:"), `${special} still carries the prefix`)
  }
})

test("--targets reads monitors from stdin when given -", () => {
  const monitors = [
    { name: "DP-2", description: "Acme Screen" },
    { name: "DP-3", description: "Acme Screen" }
  ]
  const out = JSON.parse(run(["--targets", "-"], JSON.stringify(monitors)))
  assert.deepEqual(out.monitors.map(m => m.key), ["Acme Screen@DP-2", "Acme Screen@DP-3"])
})
