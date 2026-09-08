// Tests for the targeting model: numeric workspaces, per-monitor slots and
// special (scratchpad) workspaces.
//
// Run: node --test tests/

const test = require("node:test")
const assert = require("node:assert/strict")
const { loadModel } = require("./load-model.js")

const Model = loadModel()

// The three monitors this was developed against, as `hyprctl monitors -j`
// reports them. All three describe themselves uniquely, which is the ordinary
// case; the ambiguous ones are constructed in the monitorKey tests below.
const LAPTOP = { name: "eDP-1", description: "EDO EF10QBC64.C" }
const WIDE = { name: "DP-1", description: "Dell Inc. DELL S3425DW BPTRR44" }
const SQUARE = { name: "HDMI-A-1", description: "Dell Inc. DELL S2721QSA 6PQLZY3" }
const ALL = [LAPTOP, WIDE, SQUARE]

function assignment(extra) {
  return Object.assign({ name: "Thing", command: "foot", type: "app" }, extra)
}

// ---------------------------------------------------------------------------
// normalizeAssignment: a special assignment must survive a save/load round trip
// ---------------------------------------------------------------------------

test("normalizeAssignment keeps a special workspace name", () => {
  const out = Model.normalizeAssignment(assignment({ special: "scratchpad" }))
  assert.equal(out.special, "scratchpad")
})

test("normalizeAssignment leaves workspace JSON-serialisable for a special assignment", () => {
  // The bug this pins down: parseInt("special:scratchpad") is NaN, and NaN
  // serialises to null, so the whole assignment lost its target on save.
  const out = Model.normalizeAssignment(assignment({ special: "scratchpad" }))
  assert.ok(Number.isInteger(out.workspace), `workspace was ${out.workspace}`)
  assert.equal(JSON.parse(JSON.stringify(out)).special, "scratchpad")
})

test("normalizeAssignment strips a redundant special: prefix", () => {
  const out = Model.normalizeAssignment(assignment({ special: "special:email" }))
  assert.equal(out.special, "email")
})

test("normalizeAssignment keeps a monitor key", () => {
  const out = Model.normalizeAssignment(assignment({ workspace: 3, monitor: LAPTOP.description }))
  assert.equal(out.monitor, "EDO EF10QBC64.C")
  assert.equal(out.workspace, 3)
})

test("normalizeAssignment defaults monitor and special to null when absent", () => {
  const out = Model.normalizeAssignment(assignment({ workspace: 2 }))
  assert.equal(out.monitor, null)
  assert.equal(out.special, null)
})

test("normalizeAssignment still clamps an out-of-range numeric workspace", () => {
  assert.equal(Model.normalizeAssignment(assignment({ workspace: 99 })).workspace, 1)
  assert.equal(Model.normalizeAssignment(assignment({ workspace: 0 })).workspace, 1)
})

// ---------------------------------------------------------------------------
// monitorKey: must match mmsbrggr.per-monitor-workspaces' scheme exactly, or
// launches land on workspaces the bar does not show.
// ---------------------------------------------------------------------------

test("monitorKey uses the description when it is unique", () => {
  assert.equal(Model.monitorKey(LAPTOP, ALL), "EDO EF10QBC64.C")
  assert.equal(Model.monitorKey(WIDE, ALL), "Dell Inc. DELL S3425DW BPTRR44")
})

test("monitorKey appends the connector when two monitors share a description", () => {
  const twinA = { name: "DP-2", description: "Acme Screen" }
  const twinB = { name: "DP-3", description: "Acme Screen" }
  const monitors = [twinA, twinB, LAPTOP]
  assert.equal(Model.monitorKey(twinA, monitors), "Acme Screen@DP-2")
  assert.equal(Model.monitorKey(twinB, monitors), "Acme Screen@DP-3")
})

test("monitorKey falls back to the connector when the description is empty", () => {
  const bare = { name: "DP-4", description: "" }
  assert.equal(Model.monitorKey(bare, [bare, LAPTOP]), "DP-4")
})

// ---------------------------------------------------------------------------
// resolveTarget: turns an assignment into what the launcher needs.
//
// `selector` is what Hyprland's [workspace ...] rule and window.move take;
// `name` is the bare workspace name that appears in `hyprctl clients` JSON.
// They differ for per-monitor slots, and conflating them breaks the launcher's
// "did the window land?" verification.
// ---------------------------------------------------------------------------

test("resolveTarget maps a special assignment to a special selector", () => {
  const target = Model.resolveTarget(Model.normalizeAssignment(assignment({ special: "scratchpad" })), [])
  assert.deepEqual(target, { selector: "special:scratchpad", name: "special:scratchpad" })
})

test("resolveTarget maps a monitor slot to a name: selector and a bare name", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 3, monitor: LAPTOP.description }))
  const target = Model.resolveTarget(a, ["EDO EF10QBC64.C"])
  assert.deepEqual(target, {
    selector: "name:EDO EF10QBC64.C:3",
    name: "EDO EF10QBC64.C:3"
  })
})

test("resolveTarget returns null when the assigned monitor is not connected", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 2, monitor: WIDE.description }))
  assert.equal(Model.resolveTarget(a, ["EDO EF10QBC64.C"]), null)
})

test("resolveTarget maps a plain numeric assignment to a global workspace", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 4 }))
  assert.deepEqual(Model.resolveTarget(a, ["EDO EF10QBC64.C"]), { selector: "4", name: "4" })
})

test("resolveTarget prefers special over monitor when both are set", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 3, monitor: LAPTOP.description, special: "email" }))
  const target = Model.resolveTarget(a, ["EDO EF10QBC64.C"])
  assert.equal(target.selector, "special:email")
})

// ---------------------------------------------------------------------------
// targetKey: the Panel groups assignments by target. Two monitors' slot 2 are
// different workspaces and must not share a group.
// ---------------------------------------------------------------------------

test("targetKey distinguishes the same slot number on different monitors", () => {
  const onLaptop = Model.normalizeAssignment(assignment({ workspace: 2, monitor: LAPTOP.description }))
  const onWide = Model.normalizeAssignment(assignment({ workspace: 2, monitor: WIDE.description }))
  assert.notEqual(Model.targetKey(onLaptop), Model.targetKey(onWide))
})

test("targetKey groups assignments sharing one target", () => {
  const first = Model.normalizeAssignment(assignment({ workspace: 2, monitor: LAPTOP.description }))
  const second = Model.normalizeAssignment(assignment({ name: "Other", workspace: 2, monitor: LAPTOP.description }))
  assert.equal(Model.targetKey(first), Model.targetKey(second))
})

test("targetKey separates a special from a numeric workspace", () => {
  const special = Model.normalizeAssignment(assignment({ special: "scratchpad" }))
  const global1 = Model.normalizeAssignment(assignment({ workspace: 1 }))
  assert.notEqual(Model.targetKey(special), Model.targetKey(global1))
})

// ---------------------------------------------------------------------------
// sanitizeConfig must carry the new fields through a full config round trip.
// ---------------------------------------------------------------------------

test("sanitizeConfig preserves monitor and special through a round trip", () => {
  const cfg = Model.sanitizeConfig({
    version: 1,
    assignments: [
      { workspace: 3, monitor: "EDO EF10QBC64.C", name: "Term", command: "foot", type: "app" },
      { special: "email", name: "Mail", command: "https://outlook.office.com/mail/", type: "webapp" }
    ]
  })
  const round = JSON.parse(JSON.stringify(cfg))
  assert.equal(round.assignments[0].monitor, "EDO EF10QBC64.C")
  assert.equal(round.assignments[0].workspace, 3)
  assert.equal(round.assignments[1].special, "email")
  assert.ok(Number.isInteger(round.assignments[1].workspace))
})

// ---------------------------------------------------------------------------
// Legacy configs: before the target kind moved into its own field, `workspace`
// itself could hold "special:<name>" -- accepted by the validators, then
// destroyed by normalizeAssignment. Migrate rather than drop it.
// ---------------------------------------------------------------------------

test("normalizeAssignment migrates a legacy special: workspace value", () => {
  const out = Model.normalizeAssignment(assignment({ workspace: "special:scratchpad" }))
  assert.equal(out.special, "scratchpad")
  assert.ok(Number.isInteger(out.workspace), `workspace was ${out.workspace}`)
})

// ---------------------------------------------------------------------------
// isValidSelector: the single gate before a selector reaches Hyprland.
//
// The selector is interpolated into hl.exec_cmd("[workspace <sel> silent] ...")
// as a Lua string, so anything that could close that string or the rule has to
// be refused here rather than escaped downstream.
// ---------------------------------------------------------------------------

test("isValidSelector accepts a global slot number", () => {
  assert.equal(Model.isValidSelector("3"), true)
  assert.equal(Model.isValidSelector("10"), true)
})

test("isValidSelector accepts a named per-monitor workspace with spaces", () => {
  assert.equal(Model.isValidSelector("name:EDO EF10QBC64.C:3"), true)
  assert.equal(Model.isValidSelector("name:Dell Inc. DELL S3425DW BPTRR44:10"), true)
})

test("isValidSelector accepts a special workspace", () => {
  assert.equal(Model.isValidSelector("special:scratchpad"), true)
  assert.equal(Model.isValidSelector("special:email"), true)
})

test("isValidSelector rejects an empty or nameless selector", () => {
  assert.equal(Model.isValidSelector(""), false)
  assert.equal(Model.isValidSelector("name:"), false)
  assert.equal(Model.isValidSelector("special:"), false)
})

test("isValidSelector rejects anything that could break out of the Lua string", () => {
  assert.equal(Model.isValidSelector('name:a" .. os.execute("x") .. "'), false)
  assert.equal(Model.isValidSelector("special:a\\b"), false)
  assert.equal(Model.isValidSelector("name:a\nb:1"), false)
  assert.equal(Model.isValidSelector("special:a]b"), false)
})

test("isValidSelector rejects an unknown selector kind", () => {
  assert.equal(Model.isValidSelector("previous"), false)
  assert.equal(Model.isValidSelector("e+1"), false)
})

// ---------------------------------------------------------------------------
// targetLabel: how a target reads in the panel. Monitors are stored by
// description key -- long and unfamiliar -- so display prefers the connector.
// ---------------------------------------------------------------------------

const MONITOR_LIST = [
  { key: "EDO EF10QBC64.C", name: "eDP-1", description: "EDO EF10QBC64.C" },
  { key: "Dell Inc. DELL S3425DW BPTRR44", name: "DP-1", description: "Dell Inc. DELL S3425DW BPTRR44" }
]

test("targetLabel names a special workspace", () => {
  const a = Model.normalizeAssignment(assignment({ special: "scratchpad" }))
  assert.equal(Model.targetLabel(a, MONITOR_LIST), "scratchpad")
})

test("targetLabel shows a global workspace by number", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 4 }))
  assert.equal(Model.targetLabel(a, MONITOR_LIST), "WS4")
})

test("targetLabel prefers the connector name for a known monitor", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 3, monitor: "EDO EF10QBC64.C" }))
  assert.equal(Model.targetLabel(a, MONITOR_LIST), "eDP-1 · WS3")
})

test("targetLabel falls back to the stored key for a monitor that is not connected", () => {
  const a = Model.normalizeAssignment(assignment({ workspace: 2, monitor: "Some Absent Screen" }))
  assert.equal(Model.targetLabel(a, MONITOR_LIST), "Some Absent Screen · WS2")
})
