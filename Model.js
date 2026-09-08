.pragma library

// Shared helpers for Auto Workspace panel + service
// File paths are resolved in QML via Quickshell.env

function defaultConfig() {
    return {
        version: 1,
        settings: {
            enabled: true,
            launchDelayMs: 1500,
            staggerMs: 400,
            silent: true,
            onlyOnBoot: true,
            lastFormWorkspace: 1
        },
        assignments: []
    }
}

function clone(o) { return JSON.parse(JSON.stringify(o)) }

function makeId() {
    return "aw-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2,6)
}

function defaultOnlyOnBootForType(type) {
    return type === "app" ? false : true
}

function normalizeAssignment(a) {
    // Always a usable slot number. The old guard let a non-numeric workspace
    // through as NaN, which JSON.stringify writes as null -- so a special
    // workspace assignment lost its target the moment it was saved. The target
    // kind now lives in `monitor`/`special`, and `workspace` is only ever the
    // slot number those two are read against.
    var ws = parseInt(a.workspace, 10)
    if (!(ws >= 1 && ws <= 10)) ws = 1

    // A Hyprland special workspace, stored without its "special:" prefix so the
    // stored value is the bare name the user typed and sees.
    //
    // Before the target kind had its own field, `workspace` itself could hold
    // "special:<name>" -- the validators accepted it and normalizeAssignment
    // then threw it away. Migrate that form rather than lose the assignment.
    var rawSpecial = a.special
    if (!rawSpecial && String(a.workspace || "").indexOf("special:") === 0) rawSpecial = a.workspace
    var special = rawSpecial ? String(rawSpecial).replace(/^special:/, "").slice(0, 64) : null
    if (special === "") special = null

    // A monitor key as monitorKey() below computes it -- the prefix that
    // mmsbrggr.per-monitor-workspaces gives that screen's workspace names.
    var monitor = a.monitor ? String(a.monitor).slice(0, 128) : null
    if (monitor === "") monitor = null

    var type = (a.type === "webapp" || a.type === "app" || a.type === "custom") ? a.type : "app"
    var onlyOnBoot = defaultOnlyOnBootForType(type)
    if (typeof a.onlyOnBoot === "boolean") {
        onlyOnBoot = a.onlyOnBoot
    } else if (a.onlyOnBoot === 1 || a.onlyOnBoot === "1" || a.onlyOnBoot === "true") {
        onlyOnBoot = true
    } else if (a.onlyOnBoot === 0 || a.onlyOnBoot === "0" || a.onlyOnBoot === "false") {
        onlyOnBoot = false
    }
    return {
        id: String(a.id || makeId()),
        workspace: ws,
        monitor: monitor,
        special: special,
        name: String(a.name || a.command || "App").slice(0, 80),
        command: String(a.command || a.exec || "").slice(0, 500),
        exec: String(a.exec || a.command || "").slice(0, 500),
        type: type,
        enabled: a.enabled !== false,
        onlyOnBoot: onlyOnBoot
    }
}

function sanitizeConfig(cfg) {
    if (!cfg || typeof cfg !== "object") return defaultConfig()
    var out = clone(defaultConfig())
    if (cfg.settings && typeof cfg.settings === "object") {
        out.settings.enabled = cfg.settings.enabled !== false
        out.settings.launchDelayMs = Math.max(0, Math.min(10000, parseInt(cfg.settings.launchDelayMs) || 1500))
        out.settings.staggerMs = Math.max(0, Math.min(2000, parseInt(cfg.settings.staggerMs) || 400))
        out.settings.silent = cfg.settings.silent !== false
        out.settings.onlyOnBoot = cfg.settings.onlyOnBoot !== false
        out.settings.lastFormWorkspace = Math.max(1, Math.min(10, parseInt(cfg.settings.lastFormWorkspace) || 1))
    }
    if (Array.isArray(cfg.assignments)) {
        out.assignments = cfg.assignments.slice(0, 50).map(function(raw){
            return normalizeAssignment(clone(raw))
        })
    }
    out.version = 1
    return out
}

// The prefix mmsbrggr.per-monitor-workspaces gives a screen's workspace names,
// so a monitor-targeted assignment addresses the same workspace the bar shows.
//
// This mirrors monitor_key() in that plugin's hypr/actions.lua, which warns that
// its own Lua and QML copies "cannot share code -- different runtimes -- and if
// they disagree the dots and the keys quietly address different workspaces".
// This is a third copy, and the same warning applies: the three rules below --
// description, description@connector when two screens describe themselves
// alike, connector when there is no description -- must stay in step with it.
//
// `monitors` is every connected monitor, as `hyprctl monitors -j` reports them.
function monitorKey(monitor, monitors) {
    if (!monitor) return ""
    var description = monitor.description ? String(monitor.description) : ""
    if (description === "") return String(monitor.name || "")

    var list = monitors || []
    for (var i = 0; i < list.length; i++) {
        var other = list[i]
        if (!other) continue
        if (String(other.name) !== String(monitor.name)
            && String(other.description || "") === description) {
            return description + "@" + String(monitor.name)
        }
    }
    return description
}

// What the launcher needs to place an assignment, or null to skip it.
//
// `selector` is what Hyprland's [workspace ...] rule and window.move accept;
// `name` is the bare workspace name that turns up in `hyprctl clients` JSON.
// They differ for a per-monitor slot -- only the selector carries the "name:"
// prefix -- and conflating them breaks the launcher's check that the window
// actually landed where it was sent.
//
// A monitor that is not connected resolves to null: its assignments are skipped
// rather than piled onto whichever screen happens to be present.
function resolveTarget(a, liveMonitorKeys) {
    if (!a) return null

    if (a.special) {
        var specialName = "special:" + a.special
        return { selector: specialName, name: specialName }
    }

    if (a.monitor) {
        var keys = liveMonitorKeys || []
        if (keys.indexOf(a.monitor) === -1) return null
        var wsName = a.monitor + ":" + a.workspace
        return { selector: "name:" + wsName, name: wsName }
    }

    return { selector: String(a.workspace), name: String(a.workspace) }
}

// How a target reads in the panel.
//
// A monitor is stored by its description key, which is long and unfamiliar
// ("EDO EF10QBC64.C"), so display prefers the connector the person recognises
// ("eDP-1"). `monitors` is the list from `auto-workspace.sh --targets`; a key
// missing from it means that screen is not connected, and the stored key is
// shown as-is rather than hidden.
function targetLabel(a, monitors) {
    if (!a) return ""
    if (a.special) return a.special

    if (a.monitor) {
        var shown = a.monitor
        var list = monitors || []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].key === a.monitor) {
                shown = list[i].name || a.monitor
                break
            }
        }
        return shown + " \u00b7 WS" + a.workspace
    }

    return "WS" + a.workspace
}

// Is this a workspace selector we are willing to hand to Hyprland?
//
// The selector is interpolated into hl.exec_cmd("[workspace <sel> silent] ...")
// -- a Lua string inside a Hyprland rule -- so the characters that could close
// either are refused here rather than escaped further down. Monitor
// descriptions are free text and legitimately contain spaces and dots, so the
// name forms allow those while excluding quotes, backslashes, brackets,
// newlines and control characters.
//
// Three kinds, matching resolveTarget's output:
//   "<n>"                  a global workspace slot
//   "name:<workspace>"     a named workspace, which is how a per-monitor slot
//                          is addressed
//   "special:<name>"       a special (scratchpad) workspace
function isValidSelector(selector) {
    var s = String(selector == null ? "" : selector)
    if (s.length === 0 || s.length > 200) return false

    // Nothing that could terminate the Lua string or the [workspace ...] rule.
    if (/["'\\\[\]\n\r\t\0]/.test(s)) return false
    if (/[\x00-\x1f\x7f]/.test(s)) return false

    if (/^[0-9]+$/.test(s)) return true
    if (s.indexOf("name:") === 0) return s.length > "name:".length
    if (s.indexOf("special:") === 0) return s.length > "special:".length
    return false
}

// A stable identity for "the workspace this assignment targets", for grouping
// in the panel. Slot 2 on one screen and slot 2 on another are different
// workspaces, so the monitor has to be part of the key.
function targetKey(a) {
    if (!a) return ""
    if (a.special) return "special:" + a.special
    if (a.monitor) return "mon:" + a.monitor + ":" + a.workspace
    return "ws:" + a.workspace
}

function execForAssignment(a) {
    // Prefer explicit exec, else derive
    if (a.exec && String(a.exec).trim().length) return String(a.exec).trim()
    if (a.command && String(a.command).trim().length) {
        var cmd = String(a.command).trim()
        if (a.type === "webapp") {
            // if command is a URL, wrap with omarchy-launch-webapp
            if (cmd.indexOf("http://") === 0 || cmd.indexOf("https://") === 0) {
                return "omarchy-launch-webapp '" + cmd.replace(/'/g, "'\\''") + "'"
            }
            return cmd
        }
        return cmd
    }
    return ""
}

function displayNameForExec(execStr, fallback) {
    var s = String(execStr || "").trim()
    if (!s) return fallback || "App"
    // unwrap webapp
    var m = s.match(/omarchy-launch-webapp\s+'([^']+)'/)
    if (m) {
        try {
            var u = new URL(m[1])
            return u.hostname.replace(/^www\./, "") + u.pathname.split("/").slice(0,2).join("/")
        } catch(e) { return m[1].slice(0, 40) }
    }
    // take basename of first token
    var first = s.split(/\s+/)[0]
    var base = first.split("/").pop()
    return base || fallback || "App"
}
