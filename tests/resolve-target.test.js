// resolve_target also exists twice: Model.js for the panel, bash for the
// launcher. Same reasoning as tests/monitor-keys.test.js -- a disagreement is
// silent, so pin the two implementations to each other rather than trust them.
//
// The case that matters most is the skip: an assignment pinned to a screen that
// is not connected must resolve to nothing, so it is left alone instead of
// launched onto whichever screen happens to be present.

const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { execFileSync } = require("node:child_process")
const { loadModel } = require("./load-model.js")

const Model = loadModel()
const SCRIPT = path.join(__dirname, "..", "auto-workspace.sh")

const LIVE_KEYS = ["EDO EF10QBC64.C", "Dell Inc. DELL S3425DW BPTRR44"]

// Sourcing the script runs its argument dispatch, which prints help with no
// arguments; discard that, then call the function directly.
function shellResolve({ workspace = 1, monitor = "", special = "" }) {
  const script = `source ${JSON.stringify(SCRIPT)} >/dev/null 2>&1
resolve_target ${JSON.stringify(String(workspace))} ${JSON.stringify(monitor)} ${JSON.stringify(special)} "$KEYS"`
  return execFileSync("/usr/bin/bash", ["-c", script], {
    encoding: "utf8",
    env: { ...process.env, KEYS: LIVE_KEYS.join("\n") }
  }).trim()
}

function modelResolve(fields) {
  const a = Model.normalizeAssignment(Object.assign({ name: "X", command: "foot", type: "app" }, fields))
  const target = Model.resolveTarget(a, LIVE_KEYS)
  return target === null ? "" : target.selector
}

const CASES = [
  { label: "a global slot", fields: { workspace: 3 } },
  { label: "a connected monitor's slot", fields: { workspace: 3, monitor: "EDO EF10QBC64.C" } },
  { label: "a monitor whose description has spaces", fields: { workspace: 10, monitor: "Dell Inc. DELL S3425DW BPTRR44" } },
  { label: "a special workspace", fields: { special: "scratchpad" } },
  { label: "a special workspace given with its prefix", fields: { special: "special:email" } },
  { label: "special winning over monitor", fields: { workspace: 2, monitor: "EDO EF10QBC64.C", special: "email" } },
  { label: "a monitor that is not connected", fields: { workspace: 2, monitor: "Some Absent Screen" } }
]

for (const { label, fields } of CASES) {
  test(`resolve_target agrees with Model.resolveTarget: ${label}`, () => {
    assert.equal(shellResolve(fields), modelResolve(fields))
  })
}

test("an absent monitor resolves to nothing in both implementations", () => {
  const fields = { workspace: 2, monitor: "Some Absent Screen" }
  assert.equal(shellResolve(fields), "", "shell should print nothing")
  assert.equal(modelResolve(fields), "", "Model should return null")
})

test("a monitor key is matched whole, not as a substring", () => {
  // "EDO EF10QBC64" is a prefix of a live key but is not itself a live monitor,
  // so it must not resolve. A substring match here would launch onto a
  // workspace belonging to a different screen.
  assert.equal(shellResolve({ workspace: 1, monitor: "EDO EF10QBC64" }), "")
})
