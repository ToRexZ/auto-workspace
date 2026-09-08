// Loads Model.js under plain node.
//
// Model.js is a QML JS library: identical to plain JS except for the leading
// `.pragma library` directive, which node cannot parse. Strip that one line and
// the rest evaluates as-is, so the tests exercise the very file QML loads
// rather than a copy that can drift from it.
//
// Compiled as an ordinary CommonJS module rather than inside a vm sandbox: a
// sandbox is its own realm, so objects it returns carry a different
// Object.prototype and assert.deepEqual rejects them as "same structure but
// not reference-equal" even when the values match.

const fs = require("node:fs")
const path = require("node:path")
const Module = require("node:module")

const MODEL_PATH = path.join(__dirname, "..", "Model.js")

function loadModel() {
  const source = fs.readFileSync(MODEL_PATH, "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")

  // Model.js declares plain top-level functions and exports nothing, which is
  // how a QML JS library shares them. Collect the names and export them.
  const names = [...source.matchAll(/^function\s+([A-Za-z_$][\w$]*)\s*\(/gm)].map(m => m[1])
  if (names.length === 0) throw new Error("no top-level functions found in " + MODEL_PATH)

  const wrapped = `${source}\nmodule.exports = { ${names.join(", ")} };\n`

  const mod = new Module(MODEL_PATH, null)
  mod.filename = MODEL_PATH
  mod.paths = Module._nodeModulePaths(path.dirname(MODEL_PATH))
  mod._compile(wrapped, MODEL_PATH)
  return mod.exports
}

module.exports = { loadModel, MODEL_PATH }
