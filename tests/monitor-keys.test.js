// The monitor-key algorithm exists twice: Model.js for the panel, and jq inside
// auto-workspace.sh for the launcher. They cannot share code -- different
// runtimes -- which is exactly the drift that
// mmsbrggr.per-monitor-workspaces warns about in its own two copies:
//
//   "if they disagree the dots and the keys quietly address different
//    workspaces"
//
// A disagreement here is silent and awful: apps launch onto workspaces the bar
// does not show. So rather than trust two implementations to stay in step, pin
// them to each other over the same fixtures.

const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { execFileSync } = require("node:child_process")
const { loadModel } = require("./load-model.js")

const Model = loadModel()
const SCRIPT = path.join(__dirname, "..", "auto-workspace.sh")

// Each fixture is one `hyprctl monitors -j` shape worth testing.
const FIXTURES = {
  "three uniquely described screens": [
    { name: "eDP-1", description: "EDO EF10QBC64.C" },
    { name: "DP-1", description: "Dell Inc. DELL S3425DW BPTRR44" },
    { name: "HDMI-A-1", description: "Dell Inc. DELL S2721QSA 6PQLZY3" }
  ],
  "two screens sharing a description": [
    { name: "DP-2", description: "Acme Screen" },
    { name: "DP-3", description: "Acme Screen" },
    { name: "eDP-1", description: "EDO EF10QBC64.C" }
  ],
  "a screen with no description": [
    { name: "DP-4", description: "" },
    { name: "eDP-1", description: "EDO EF10QBC64.C" }
  ],
  "a single screen": [{ name: "eDP-1", description: "EDO EF10QBC64.C" }],
  "descriptions containing a colon": [
    { name: "DP-1", description: "Weird: Panel: 3000" },
    { name: "eDP-1", description: "EDO EF10QBC64.C" }
  ]
}

function keysFromShell(monitors) {
  const out = execFileSync("/usr/bin/bash", [SCRIPT, "--monitor-keys", "-"], {
    input: JSON.stringify(monitors),
    encoding: "utf8"
  })
  return out.split("\n").filter(line => line.length > 0)
}

function keysFromModel(monitors) {
  return monitors.map(m => Model.monitorKey(m, monitors))
}

for (const [label, monitors] of Object.entries(FIXTURES)) {
  test(`monitor keys agree between Model.js and the shell: ${label}`, () => {
    assert.deepEqual(keysFromShell(monitors), keysFromModel(monitors))
  })
}

test("monitor keys are unique per screen even when descriptions collide", () => {
  const keys = keysFromShell(FIXTURES["two screens sharing a description"])
  assert.equal(new Set(keys).size, keys.length, `duplicate keys: ${keys.join(", ")}`)
})

// With no argument the script must query the running Hyprland, not read stdin.
// Getting this wrong is quiet: an empty key list makes every monitor-targeted
// assignment look like "monitor not connected", so nothing launches.
test("monitor keys with no argument read the live compositor", (t) => {
  let expected
  try {
    expected = JSON.parse(execFileSync("hyprctl", ["monitors", "-j"], { encoding: "utf8" })).length
  } catch {
    return t.skip("no running Hyprland")
  }

  const out = execFileSync("/usr/bin/bash", [SCRIPT, "--monitor-keys"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  })
  const keys = out.split("\n").filter(line => line.length > 0)
  assert.equal(keys.length, expected, `got ${keys.length} keys for ${expected} monitors`)
})
