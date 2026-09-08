import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    moduleName: "tenzin.auto-workspace"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    readonly property string pluginId: "tenzin.auto-workspace"
    // Outside the plugin dir: the shell reloads the plugin on any file change there
    readonly property string configFile: stateHome + "/omarchy/auto-workspace/config.json"
    readonly property string legacyConfigFile: configHome + "/omarchy/plugins/" + pluginId + "/config.json"
    readonly property string script: home + "/.config/omarchy/plugins/" + pluginId + "/auto-workspace.sh"

    signal countsChanged()

    property var config: Model.defaultConfig()
    property var assignments: []
    property bool loading: true
    property string errorText: ""
    property string statusText: ""
    property var appList: []
    property string appFilter: ""
    property bool adding: false
    property int formWorkspace: 1
    property bool workspacePicked: false
    property string formName: ""
    property string formCommand: ""
    property string formType: "app"

    // Where an assignment goes. Three kinds, and `special` wins over `monitor`:
    //   formMonitor "" + formSpecial ""  -> a global workspace (upstream default)
    //   formMonitor set                  -> that screen's workspace formWorkspace
    //   formSpecial set                  -> that special (scratchpad) workspace
    property string formMonitor: ""
    property string formSpecial: ""

    // The scratchpad dropdown's own selection. Distinct from formSpecial because
    // one option is a mode ("New scratchpad...") rather than a workspace name;
    // in that mode formSpecial comes from the text field instead.
    readonly property string newSpecialSentinel: "\u0000new"
    property string specialChoice: ""

    // Offered in the pickers, from `auto-workspace.sh --targets`.
    // liveMonitors: [{ key, name, description }]; liveSpecials: ["scratchpad"]
    property var liveMonitors: []
    property var liveSpecials: []

    // Which half the right column shows. The panel otherwise only ever displays
    // the assignments on the selected target, so seeing all of them means
    // clicking through every screen x workspace x scratchpad combination.
    property string rightView: "preview"

    // Just the keys, for Model.resolveTarget.
    readonly property var liveMonitorKeys: {
        var out = []
        for (var i = 0; i < liveMonitors.length; i++) out.push(String(liveMonitors[i].key))
        return out
    }

    // The form's current target, shaped like an assignment so the Model helpers
    // apply to it unchanged.
    readonly property var formTarget: ({
        workspace: root.formWorkspace,
        monitor: root.formSpecial !== "" ? null : (root.formMonitor !== "" ? root.formMonitor : null),
        special: root.formSpecial !== "" ? root.formSpecial : null
    })
    readonly property string formTargetKey: Model.targetKey(root.formTarget)
    readonly property string formTargetLabel: Model.targetLabel(root.formTarget, root.liveMonitors)
    property string formExecPreview: ""
    property bool formNameEdited: false
    property string autoName: ""
    property bool fillingName: false
    onFormTypeChanged: { updateFormPreview(); updateAutofillName() }

    // Global default plus per-workspace tiledLayout (Super+L / workspace_rule).
    property string hyprLayoutDefault: "dwindle"
    property var workspaceLayouts: ({})
    readonly property string hyprLayout: {
        // Per-workspace layouts are keyed by Hyprland's numeric workspace id, so
        // they only describe a global slot. A per-monitor or special workspace
        // has no such entry and falls back to the global default.
        if (formSpecial !== "" || formMonitor !== "") return hyprLayoutDefault
        var mapped = workspaceLayouts[String(formWorkspace)]
        return mapped || hyprLayoutDefault
    }
    property real hyprColumnWidth: 0.49
    // Real Hyprland general/decoration/master options (effective values)
    property real hyprGapsIn: 5
    property real hyprGapsOut: 10
    property real hyprBorder: 2
    property int hyprRounding: 0
    property real hyprMfact: 0.55
    // Focused monitor logical size (physical ÷ scale)
    property real hyprScale: 1.0
    property int monW: 0
    property int monH: 0

    // --- keyboard cursor model (plugin-manager pattern) ---
    property bool cursorActive: false
    property int selectedRow: 0
    property int selectedButton: 0

    readonly property color foreground: Color.foreground
    readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
    readonly property string fontFamily: Style.font.family

    readonly property int totalCount: assignments.length
    readonly property int enabledCount: (function(){
        var n = 0
        for (var i = 0; i < assignments.length; i++) if (assignments[i].enabled !== false) n++
        return n
    })()

    function open() { root.controller.show(); loadConfig(); layoutProc.running = true; targetsProc.running = true; root.workspacePicked = true }


    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() { root.close() }
    function switchPanel(dir) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.hostWidget || root, dir)
        return false
    }

    function loadConfig() { loading=true; errorText=""; loadProc.running=true; if (!layoutProc.running) layoutProc.running = true }
    function saveConfig() {
        var cfg = Model.sanitizeConfig(config)
        cfg.assignments = assignments.slice(0, 50)
        for (var i=0;i<cfg.assignments.length;i++) {
            var a=cfg.assignments[i]
            if (a.type==="webapp" && a.command.indexOf("http")===0) {
                a.exec = "omarchy-launch-webapp '" + a.command.replace(/'/g,"'\\''") + "'"
                if (!a.name || a.name===a.command) a.name = Model.displayNameForExec(a.exec, "Web App")
            } else if (a.exec==="" && a.command!=="") a.exec=a.command
            cfg.assignments[i]=a
        }
        config=cfg; assignments=cfg.assignments.slice()
        saveProc.pendingJson = JSON.stringify(cfg,null,2)
        if (saveProc.running) { saveProc.wantsSave = true; return }
        saveProc.command=["/usr/bin/bash","-c","dir=\"$(dirname \"$1\")\"; if [[ -L \"$1\" || -L \"$dir\" ]]; then echo \"refusing symlink: $1\" >&2; exit 1; fi; mkdir -p \"$dir\"; if [[ -L \"$dir\" ]]; then echo \"refusing symlink (race): $dir\" >&2; exit 1; fi; if [[ $(/usr/bin/stat -c%s \"$1\" 2>/dev/null || echo 0) -gt 1048576 && -f \"$1\" ]]; then echo \"refusing oversized config\" >&2; exit 1; fi; tmp=$(/usr/bin/mktemp \"$1.tmp.XXXXXX\") || exit 1; trap 'rm -f \"$tmp\"' EXIT; printf '%s' \"$2\" > \"$tmp\" || exit 1; if [[ -L \"$1\" ]]; then rm -f \"$tmp\"; echo \"refusing symlink (race): $1\" >&2; exit 1; fi; mv -f \"$tmp\" \"$1\"; trap - EXIT; /usr/bin/head -c 1048576 \"$1\" | /usr/bin/jq empty && echo OK || echo FAIL", "_", root.configFile, saveProc.pendingJson]
        saveProc.running=true
    }
    function addAssignment() {
        var name=formName.trim(), cmd=formCommand.trim()
        if (!cmd.length) { errorText="Command / URL is required"; return }
        if (!name.length) {
            if (formType==="webapp") name=Model.displayNameForExec("omarchy-launch-webapp '"+cmd+"'", "Web App")
            else name=Model.displayNameForExec(cmd, "App")
        }
        var execStr=cmd
        if (formType==="webapp" && (cmd.indexOf("http://")===0 || cmd.indexOf("https://")===0))
            execStr="omarchy-launch-webapp '" + cmd.replace(/'/g,"'\\''") + "'"
        var item=Model.normalizeAssignment({
            workspace:formWorkspace,
            monitor:root.formTarget.monitor,
            special:root.formTarget.special,
            name:name, command:cmd, exec:execStr, type:formType, enabled:true, onlyOnBoot:true
        })
        assignments=assignments.concat([item]); config.assignments=assignments.slice()
        formName=""; formCommand=""; formType="app"; formNameEdited=false
        saveConfig()
        statusText="Added "+item.name+" → "+Model.targetLabel(item, root.liveMonitors)
        clearStatusTimer.restart()
        if (root.bar && typeof root.bar.broadcast === "function") root.bar.broadcast("refreshCounts")
        root.countsChanged()
    }
    function updateFormPreview() {
        if(formType==="webapp" && (formCommand.indexOf("http://")===0 || formCommand.indexOf("https://")===0)) formExecPreview="omarchy-launch-webapp '"+formCommand+"'"
        else formExecPreview=formCommand
    }
    function persistFormWorkspace() {
        var s=Model.clone(root.config); s.settings.lastFormWorkspace=root.formWorkspace; root.config=s; root.saveConfig()
    }
    // Enable or disable one assignment without deleting it.
    function setAssignmentEnabled(id, on) {
        var out = []
        for (var i = 0; i < root.assignments.length; i++) {
            var a = Model.clone(root.assignments[i])
            if (a.id === id) a.enabled = !!on
            out.push(a)
        }
        root.assignments = out
        root.config.assignments = out.slice()
        root.saveConfig()
        root.countsChanged()
    }

    // Move one assignment to a different screen, workspace or scratchpad from
    // its own row, rather than via the pickers plus a re-toggle.
    //
    // Refuses a move that would land the same command on a target that already
    // has it: two identical assignments on one workspace launch the app twice.
    function retargetAssignment(id, target) {
        var current = null
        for (var i = 0; i < root.assignments.length; i++)
            if (root.assignments[i].id === id) current = root.assignments[i]
        if (!current) return

        var moved = Model.applyTarget(current, target)
        var movedKey = Model.targetKey(moved)
        if (movedKey === Model.targetKey(current)) return

        for (var j = 0; j < root.assignments.length; j++) {
            var other = root.assignments[j]
            if (other.id === id) continue
            if (Model.targetKey(other) === movedKey
                && (other.exec === moved.exec || other.command === moved.exec)) {
                root.statusText = moved.name + " is already on " + Model.targetLabel(moved, root.liveMonitors)
                clearStatusTimer.restart()
                return
            }
        }

        var out = []
        for (var k = 0; k < root.assignments.length; k++)
            out.push(root.assignments[k].id === id ? moved : root.assignments[k])
        root.assignments = out
        root.config.assignments = out.slice()
        root.saveConfig()
        root.statusText = "Moved " + moved.name + " → " + Model.targetLabel(moved, root.liveMonitors)
        clearStatusTimer.restart()
        root.countsChanged()
    }

    // Point the pickers at an assignment's target, so its row can be used to
    // navigate to the workspace it belongs to.
    function selectAssignmentTarget(a) {
        if (!a) return
        root.formSpecial = a.special ? String(a.special) : ""
        root.specialChoice = root.formSpecial
        root.formMonitor = a.monitor ? String(a.monitor) : ""
        root.formWorkspace = a.workspace
        root.workspacePicked = true
    }

    // Launch one assignment now, on whatever target it names. Nothing happens
    // for an assignment pinned to a screen that is not connected -- the same
    // rule the boot pass follows.
    function launchAssignmentNow(a) {
        if (!a) return
        var target = Model.resolveTarget(a, root.liveMonitorKeys)
        if (!target) {
            root.statusText = "Skipped " + a.name + " — its screen is not connected"
            clearStatusTimer.restart()
            return
        }
        singleLaunchProc.command = ["/usr/bin/bash", root.script, "--launch", target.selector, a.exec, "true"]
        singleLaunchProc.running = true
        root.statusText = "Launching " + a.name + " → " + Model.targetLabel(a, root.liveMonitors)
        clearStatusTimer.restart()
    }

    function removeAssignment(id) {
        root.assignments=root.assignments.filter(function(a){return a.id!==id})
        root.config.assignments=root.assignments.slice()
        root.saveConfig()
        root.statusText="Removed"; clearStatusTimer.restart()
    }
    function isInList(list, exec) {
        if (!list) return false
        for (var i=0;i<list.length;i++) if (list[i].exec===exec || list[i].command===exec) return true
        return false
    }
    // Add or remove one app on the target currently selected above.
    //
    // Matched and created against the whole target, not the slot number alone:
    // the same number on another screen is a different workspace, and a special
    // workspace is neither. Comparing only `workspace` matched an assignment on
    // a different screen, and creating with only `workspace` wrote to the global
    // workspace whatever the Screen and Scratchpad pickers said -- which then
    // left the toggle reading "off", because the row's checked state comes from
    // the assignments on the selected target.
    function toggleInWorkspace(exec, name) {
        var key = root.formTargetKey
        var label = root.formTargetLabel
        for (var i=0;i<root.assignments.length;i++) {
            var a=root.assignments[i]
            if (Model.targetKey(a)===key && (a.exec===exec || a.command===exec)) {
                root.removeAssignment(a.id)
                root.statusText="Removed "+a.name+" from "+label; clearStatusTimer.restart()
                return
            }
        }
        var item=Model.normalizeAssignment({
            workspace:root.formWorkspace,
            monitor:root.formTarget.monitor,
            special:root.formTarget.special,
            name:name, command:exec, exec:exec,
            // Derived from the command: there is no type picker on this path, and
            // the type decides whether the app relaunches after being closed.
            type:Model.typeForExec(exec),
            enabled:true, onlyOnBoot:true
        })
        root.assignments=root.assignments.concat([item]); root.config.assignments=root.assignments.slice()
        root.saveConfig()
        root.statusText="Added "+item.name+" → "+Model.targetLabel(item, root.liveMonitors)
        clearStatusTimer.restart()
        if (root.bar && typeof root.bar.broadcast === "function") root.bar.broadcast("refreshCounts")
        root.countsChanged()
    }
    function updateAutofillName() {
        var cmd=formCommand.trim()
        if (!cmd.length) { autoName=""; if (!formNameEdited) { fillingName=true; formName=""; fillingName=false } return }
        var n
        if (formType==="webapp" && (cmd.indexOf("http://")===0 || cmd.indexOf("https://")===0)) n=Model.displayNameForExec("omarchy-launch-webapp '"+cmd+"'", "Web App")
        else n=Model.displayNameForExec(cmd, "App")
        autoName=n
        if (!formNameEdited) { fillingName=true; formName=n; fillingName=false }
    }
    onFormCommandChanged: { updateFormPreview(); updateAutofillName() }
    Timer { id: clearStatusTimer; interval: 3000; onTriggered: root.statusText="" }

    // --- cursor model helpers (plugin-manager pattern) ---
    function actionCount(app) { return 1 }

    function clampCursor() {
        var rows = filteredApps
        if (rows.length === 0) { selectedRow = 0; selectedButton = 0; return }
        selectedRow = Math.max(0, Math.min(selectedRow, rows.length - 1))
        selectedButton = Math.max(0, Math.min(selectedButton, actionCount(rows[selectedRow]) - 1))
    }

    function setCursor(row, button) {
        cursorActive = true
        selectedRow = row
        selectedButton = button
        clampCursor()
    }

    function moveCursor(dx, dy) {
        var rows = filteredApps
        if (rows.length === 0) return
        if (!cursorActive) { setCursor(0, 0); return }
        if (dy !== 0) {
            if (dy < 0 && selectedRow === 0) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            if (dy > 0 && selectedRow === rows.length - 1) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow = Math.max(0, Math.min(rows.length - 1, selectedRow + dy))
            selectedButton = Math.min(selectedButton, actionCount(rows[selectedRow]) - 1)
        } else if (dx !== 0) {
            selectedButton = Math.max(0, Math.min(actionCount(rows[selectedRow]) - 1, selectedButton + dx))
        }
        cursorActive = true
    }

    function moveTabCursor(direction) {
        var rows = filteredApps
        if (rows.length === 0) return
        if (!cursorActive) {
            if (direction > 0) setCursor(0, 0)
            else return
            return
        }
        if (direction > 0) {
            if (selectedRow === rows.length - 1) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow++
            selectedButton = 0
        } else {
            if (selectedRow === 0) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow--
            selectedButton = actionCount(rows[selectedRow]) - 1
        }
        cursorActive = true
    }

    function activateCursor() {
        var app = filteredApps[selectedRow]
        if (!app) return
        toggleInWorkspace(app.exec, app.name)
    }

    function ensureCursorVisible(item) {
        if (!item || !resultsScroll) return
        var flick = resultsScroll.contentItem
        var point = item.mapToItem(flick.contentItem || flick, 0, 0)
        var top = point.y
        var bottom = top + item.height
        if (top < flick.contentY) flick.contentY = Math.max(0, top - Style.space(8))
        else if (bottom > flick.contentY + flick.height)
            flick.contentY = bottom - flick.height + Style.space(8)
    }

    Process {
        id: loadProc
        onRunningChanged: if (running) loadWatchdog.restart(); else loadWatchdog.stop()
        command: ["/usr/bin/bash", "-c", "dir=\"$(dirname \"$1\")\"; if [[ -L \"$1\" || -L \"$dir\" ]]; then echo \"refusing symlink: $1\" >&2; exit 1; fi; mkdir -p \"$dir\"; if [[ -L \"$dir\" ]]; then echo \"refusing symlink (race): $dir\" >&2; exit 1; fi; if [[ ! -f \"$1\" && -f \"$3\" ]]; then if [[ -L \"$3\" ]]; then echo \"refusing symlink source: $3\" >&2; exit 1; fi; if [[ $(/usr/bin/stat -c%s \"$3\" 2>/dev/null || echo 0) -gt 1048576 ]]; then echo \"refusing oversized legacy config\" >&2; exit 1; fi; tmp=$(/usr/bin/mktemp \"$1.tmp.XXXXXX\") || exit 1; cp -- \"$3\" \"$tmp\" || { rm -f \"$tmp\"; exit 1; }; if [[ -L \"$1\" ]]; then rm -f \"$tmp\"; echo \"refusing symlink (race): $1\" >&2; exit 1; fi; mv -f \"$tmp\" \"$1\"; fi; if [[ ! -f \"$1\" ]]; then tmp=$(/usr/bin/mktemp \"$1.tmp.XXXXXX\") || exit 1; trap 'rm -f \"$tmp\"' EXIT; printf '%s' '{\"version\":1,\"settings\":{\"enabled\":true,\"launchDelayMs\":800,\"staggerMs\":400,\"silent\":true,\"onlyOnBoot\":true,\"lastFormWorkspace\":1},\"assignments\":[]}' > \"$tmp\" || exit 1; if [[ -L \"$1\" ]]; then rm -f \"$tmp\"; echo \"refusing symlink (race): $1\" >&2; exit 1; fi; mv -f \"$tmp\" \"$1\"; trap - EXIT; fi; if [[ $(/usr/bin/stat -c%s \"$1\" 2>/dev/null || echo 0) -gt 1048576 ]]; then echo \"config too large\" >&2; exit 1; fi; /usr/bin/head -c 1048576 \"$1\"", "_", root.configFile, "", root.legacyConfigFile]
        stdout: StdioCollector { id: loadOut; waitForEnd: true }
        stderr: StdioCollector { id: loadErr; waitForEnd: true }
        onExited: function(code){
            loadWatchdog.stop()
            root.loading=false; var txt=loadOut.text||""
            if (txt.length > 1048576) { root.errorText="Config too large"; txt = txt.slice(0, 1048576) }
            if(code!==0){ root.errorText="Failed to load config ("+code+")"; return}
            try{ var j=JSON.parse(txt); var sane=Model.sanitizeConfig(j); root.config=sane; root.assignments=sane.assignments.slice(); root.formWorkspace=sane.settings.lastFormWorkspace; root.countsChanged() }catch(e){ root.errorText="Invalid config JSON: "+e}
        }
    }
    Process {
        id: saveProc
        onRunningChanged: if (running) saveWatchdog.restart(); else saveWatchdog.stop()
        property string pendingJson: ""
        property bool wantsSave: false
        stdout: StdioCollector { id: saveOut; waitForEnd: true }
        stderr: StdioCollector { id: saveErr; waitForEnd: true }
        onExited: function(code){
            saveWatchdog.stop()
            if(code!==0){ root.errorText="Save failed ("+code+"): "+(saveErr.text||""); }
            else root.errorText=""
            if (saveProc.wantsSave) {
                saveProc.wantsSave=false
                saveProc.command=["/usr/bin/bash","-c","dir=\"$(dirname \"$1\")\"; if [[ -L \"$1\" || -L \"$dir\" ]]; then echo \"refusing symlink: $1\" >&2; exit 1; fi; mkdir -p \"$dir\"; if [[ -L \"$dir\" ]]; then echo \"refusing symlink (race): $dir\" >&2; exit 1; fi; if [[ $(/usr/bin/stat -c%s \"$1\" 2>/dev/null || echo 0) -gt 1048576 && -f \"$1\" ]]; then echo \"refusing oversized config\" >&2; exit 1; fi; tmp=$(/usr/bin/mktemp \"$1.tmp.XXXXXX\") || exit 1; trap 'rm -f \"$tmp\"' EXIT; printf '%s' \"$2\" > \"$tmp\" || exit 1; if [[ -L \"$1\" ]]; then rm -f \"$tmp\"; echo \"refusing symlink (race): $1\" >&2; exit 1; fi; mv -f \"$tmp\" \"$1\"; trap - EXIT; /usr/bin/head -c 1048576 \"$1\" | /usr/bin/jq empty && echo OK || echo FAIL", "_", root.configFile, saveProc.pendingJson]
                saveProc.running=true
            } else if (code===0) {
                root.countsChanged(); refreshServiceProc.running=true
            }
        }
    }
    Process { id: refreshServiceProc; command: ["/usr/bin/bash","-c","omarchy-shell -q tenzin.auto-workspace refreshConfig >/dev/null 2>&1 || true"] }
    // ---- watchdogs: hard deadlines for every Process ----
    Timer { id: loadWatchdog; interval: 10000; repeat: false; onTriggered: if (loadProc.running) { root.errorText = "Load timeout"; loadProc.running = false } }
    Timer { id: saveWatchdog; interval: 10000; repeat: false; onTriggered: if (saveProc.running) { root.errorText = "Save timeout"; saveProc.running = false } }
    Timer { id: layoutWatchdog; interval: 10000; repeat: false; onTriggered: if (layoutProc.running) layoutProc.running = false }
    Timer { id: layoutToggleWatchdog; interval: 10000; repeat: false; onTriggered: if (layoutToggleProc.running) layoutToggleProc.running = false }
    Timer { id: appsWatchdog; interval: 15000; repeat: false; onTriggered: if (appsProc.running) appsProc.running = false }
    Process {
        id: singleLaunchProc
        onRunningChanged: if (running) singleLaunchWatchdog.restart(); else singleLaunchWatchdog.stop()
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { id: singleLaunchErr; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) return
            root.statusText = "Launch failed" + (singleLaunchErr.text ? ": " + singleLaunchErr.text.trim().split("\n")[0] : "")
            clearStatusTimer.restart()
        }
    }
    Timer { id: singleLaunchWatchdog; interval: 20000; repeat: false; onTriggered: if (singleLaunchProc.running) singleLaunchProc.running = false }

    Timer { id: targetsWatchdog; interval: 10000; repeat: false; onTriggered: if (targetsProc.running) targetsProc.running = false }
    function parseWorkspaceLayouts(s) {
        var out = {}
        if (!s) return out
        var pairs = s.split(",")
        for (var i = 0; i < pairs.length; i++) {
            var p = pairs[i].trim()
            if (!p) continue
            var idx = p.indexOf(":")
            if (idx < 1) continue
            var id = p.slice(0, idx)
            var lay = p.slice(idx + 1).trim()
            if (id && lay) out[id] = lay
        }
        return out
    }
    Process {
        id: layoutProc
        onRunningChanged: if (running) layoutWatchdog.restart(); else layoutWatchdog.stop()

        // Global options plus per-workspace tiledLayout (and Super+L persist files).
        command: ["/usr/bin/bash", root.script, "--hypr-facts"]
        stdout: StdioCollector { id: layoutOut; waitForEnd: true }
        onExited: function(code) {
            if (code !== 0) return
            var txt = (layoutOut.text || "").trim()
            if (!txt) return
            var parts = txt.split("|")
            if (parts[0]) root.hyprLayoutDefault = parts[0].trim()
            var num = function(s, def) { var v = parseFloat(s); return isNaN(v) ? def : v }
            var cw = num(parts[1], 0.49); if (cw > 0.1 && cw < 1.0) root.hyprColumnWidth = cw
            var gi = num(parts[2], 5);   if (gi >= 0 && gi < 100) root.hyprGapsIn = gi
            var go = num(parts[3], 10);  if (go >= 0 && go < 200) root.hyprGapsOut = go
            var b = num(parts[4], 2);    if (b >= 0 && b < 20) root.hyprBorder = b
            var r = num(parts[5], 0);    if (r >= 0 && r < 50) root.hyprRounding = Math.round(r)
            var mf = num(parts[6], 0.55); if (mf > 0.05 && mf < 0.95) root.hyprMfact = mf
            var sc = num(parts[7], 1);   if (sc >= 0.5 && sc <= 4) root.hyprScale = sc
            var mw = Math.round(num(parts[8], 0) / root.hyprScale); if (mw > 100) root.monW = mw
            var mh = Math.round(num(parts[9], 0) / root.hyprScale); if (mh > 100) root.monH = mh
            if (parts.length > 10) root.workspaceLayouts = root.parseWorkspaceLayouts(parts.slice(10).join("|"))
        }
    }
    // Switch the selected workspace's layout (same persist path as Super+L).
    Process {
        id: layoutToggleProc
        onRunningChanged: if (running) layoutToggleWatchdog.restart(); else layoutToggleWatchdog.stop()

        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { id: layoutToggleErr; waitForEnd: true }
        onExited: function(code) {
            if (code !== 0) {
                root.statusText = "Layout switch failed" + (layoutToggleErr.text ? ": " + layoutToggleErr.text.trim() : "")
                clearStatusTimer.restart()
                if (!layoutProc.running) layoutProc.running = true
                return
            }
            clearStatusTimer.restart()
            if (!layoutProc.running) layoutProc.running = true
        }
    }
    function toggleHyprLayout() {
        // Layouts persist per numeric workspace id, so there is nothing to write
        // for a per-monitor or special workspace. Say so rather than write the
        // wrong file.
        if (root.formSpecial !== "" || root.formMonitor !== "") {
            root.statusText = "Layout is per global workspace only"
            clearStatusTimer.restart()
            return
        }
        var ws = root.formWorkspace
        var target = root.hyprLayout === "scrolling" ? "dwindle" : "scrolling"
        var map = {}
        for (var k in root.workspaceLayouts) map[k] = root.workspaceLayouts[k]
        map[String(ws)] = target
        root.workspaceLayouts = map
        statusText = "WS" + ws + " → " + target
        layoutToggleProc.command = ["/usr/bin/bash", root.script, "--set-workspace-layout", String(ws), target]
        layoutToggleProc.running = true
    }
    // The screens that can be targeted, and the special workspaces that exist.
    // Read through the script so the panel and the launcher compute monitor keys
    // with the same code -- see monitor_keys() in auto-workspace.sh.
    Process {
        id: targetsProc
        onRunningChanged: if (running) targetsWatchdog.restart(); else targetsWatchdog.stop()

        command: ["/usr/bin/bash", root.script, "--targets"]
        stdout: StdioCollector { id: targetsOut; waitForEnd: true }
        onExited: function(code) {
            if (code !== 0) return
            var txt = (targetsOut.text || "").trim()
            if (!txt) return
            try {
                var parsed = JSON.parse(txt)
                root.liveMonitors = Array.isArray(parsed.monitors) ? parsed.monitors : []
                root.liveSpecials = Array.isArray(parsed.specials) ? parsed.specials : []
            } catch (e) {
                console.log("[auto-workspace] could not parse --targets: " + e)
            }
        }
    }

    // Keep layout facts fresh while the panel is visible
    Timer { id: layoutRefreshTimer; interval: 5000; repeat: true; running: root.opened; onTriggered: if (!layoutProc.running) layoutProc.running = true }
    Process {
        id: appsProc
        onRunningChanged: if (running) appsWatchdog.restart(); else appsWatchdog.stop()

        command: ["/usr/bin/bash", root.script, "--list-apps"]
        stdout: StdioCollector { id: appsOut; waitForEnd: true }
        onExited: function(code){
            if(code!==0) return
            var txt=appsOut.text||"", lines=txt.split("\n"), list=[]
            for(var i=0;i<lines.length;i++){ var l=lines[i].trim(); if(!l) continue; var p=l.split("\t"); if(p.length<2) continue; list.push({name:p[0],exec:p[1],icon:p[2]||"",iconPath:p[3]||"",score:Number(p[5])||0}); if(list.length>600) break}
            root.appList=list
        }
    }
    function alphabeticalCompare(a, b) {
        var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
        return na.localeCompare(nb, undefined, { numeric: true })
    }
    readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
    function iconSourceFor(app) {
        if (!app) return ""
        if (app.iconPath && app.iconPath !== "") return "file://" + app.iconPath
        var icon = String(app.icon || "")
        if (root.appLibrary && typeof root.appLibrary.iconSource === "function") return root.appLibrary.iconSource(icon)
        if (icon !== "" && icon.charAt(0) === "/") return "file://" + icon
        var themed = ""
        try { themed = Quickshell.iconPath(icon, true) } catch(e) { themed = "" }
        if (themed && themed.length > 0) return themed
        try { return Quickshell.iconPath("application-x-executable", true) } catch(e) { return "" }
    }
    property var filteredApps: {
        var f = appFilter.trim().toLowerCase()
        var list = []
        for (var i=0;i<appList.length;i++){
            list.push(appList[i])
        }
        if (!f) {
            // Apps assigned to THIS workspace → show them; otherwise show
            // the commonly used list
            var act = list.filter(function(a){ return root.isInList(root.addedApps, a.exec) })
            var pool = act.length > 0 ? act : list
            pool.sort(function(a, b){
                if (b.score !== a.score) return b.score - a.score
                return root.alphabeticalCompare(a, b)
            })
            return pool.slice(0, 8)
        }
        var exact = [], prefix = [], sub = []
        for (var j=0;j<list.length;j++){
            var b = list[j]
            var n = b.name.toLowerCase(), e = b.exec.toLowerCase()
            if (n === f || e === f) exact.push(b)
            else if (n.indexOf(f) === 0) prefix.push(b)
            else if (n.indexOf(f) !== -1 || e.indexOf(f) !== -1) sub.push(b)
        }
        exact.sort(root.alphabeticalCompare)
        prefix.sort(root.alphabeticalCompare)
        sub.sort(root.alphabeticalCompare)
        return exact.concat(prefix, sub).slice(0, 6)
    }
    // Grouped by target rather than by workspace number: slot 2 on one screen
    // and slot 2 on another are different workspaces, and a special workspace is
    // neither. `key` is a Model.targetKey.
    function getAppsForTarget(key) {
        var out=[]
        for(var i=0;i<assignments.length;i++) if(Model.targetKey(assignments[i])===key) out.push(assignments[i])
        return out
    }
    // Move an app within a workspace's launch/tiling order (drag & drop on preview).
    // fromLocal/toLocal are indices into that workspace's filtered list.
    function reorderAssignment(key, fromLocal, toLocal) {
        var wsIdx = []
        for (var i = 0; i < assignments.length; i++)
            if (Model.targetKey(assignments[i]) === key) wsIdx.push(i)
        if (fromLocal < 0 || fromLocal >= wsIdx.length || toLocal < 0 || toLocal >= wsIdx.length || fromLocal === toLocal) return
        console.log("[auto-workspace] reorder target=" + key + " " + fromLocal + " -> " + toLocal + " (items=" + wsIdx.length + ")")
        var arr = assignments.slice()
        var seq = []
        for (var j = 0; j < wsIdx.length; j++) seq.push(arr[wsIdx[j]])
        var moved = seq.splice(fromLocal, 1)[0]
        seq.splice(toLocal, 0, moved)
        for (var k = 0; k < wsIdx.length; k++) arr[wsIdx[k]] = seq[k]
        assignments = arr
        config.assignments = arr.slice()
        saveConfig()
        statusText = "Moved " + (moved.name || "app") + " to position " + (toLocal + 1)
        clearStatusTimer.restart()
    }
    property var addedApps: {
        var key = root.formTargetKey
        var out=[]
        for(var i=0;i<assignments.length;i++) if(Model.targetKey(assignments[i])===key) out.push(assignments[i])
        return out
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        centerOnBar: true
        focusTarget: keyCatcher
        padding: Style.space(24)
        contentWidth: panel.fittedContentWidth(Style.space(900))
        contentHeight: panel.fittedContentHeight(content.implicitHeight + Style.space(40), panel.screenH - Style.gapsOut*2 - Style.space(16))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: filterField.activeFocus
            onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
            onActivateRequested: root.activateCursor()
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.moveTabCursor(direction) }
            onTextKey: function(t) {
                if (t === "/") {
                    cursorActive = false
                    filterField.forceActiveFocus()
                    filterField.selectAll()
                }
            }

            ColumnLayout {
                id: content
                anchors.fill: parent
                spacing: Style.space(14)

                // ——— Header ———
                PanelHero {
                    Layout.fillWidth: true
                    title: "Auto Workspace"
                    meta: root.totalCount + " assignments · " + root.enabledCount + " enabled"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    iconComponent: Component {
                        Text {
                            textFormat: Text.PlainText
                            text: "󱂬"
                            color: Color.accent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.display
                        }
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    text: "↑↓ navigate · Enter toggles · / searches · Esc closes"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // ——— Body: 2 columns — pick+search | preview ———
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(Style.space(440), Math.round(panel.screenH * 0.5))
                    Layout.maximumHeight: Layout.preferredHeight
                    Layout.minimumHeight: Layout.preferredHeight
                    spacing: Style.space(14)

                    // ——— Col 1: workspace picker + app search ———
                    ColumnLayout {
                        id: leftStack
                        Layout.fillWidth: false
                        Layout.preferredWidth: Math.round(content.width * 0.30)
                        Layout.minimumWidth: Style.space(240)
                        Layout.alignment: Qt.AlignTop
                        spacing: Style.space(10)

                        // Target pickers.
                        //
                        // Dropdowns rather than rows of buttons on purpose: this
                        // column is ~255px wide, so a button per screen wraps to
                        // two lines, and a button per scratchpad to two more. That
                        // cost 233px of fixed height and starved the app-results
                        // list below, which is the only Layout.fillHeight item
                        // here -- it collapsed to 8px and the search looked
                        // broken. A dropdown is one row whatever the option count.
                        Dropdown {
                            Layout.fillWidth: true
                            label: "Screen"
                            fontFamily: root.fontFamily
                            enabled: root.formSpecial === ""
                            opacity: enabled ? 1.0 : 0.4
                            // "" is Omarchy's global workspaces, the upstream
                            // behaviour. A named screen pins the assignment, and
                            // it is skipped when that screen is not connected.
                            options: {
                                var out = [{ value: "", label: "Any screen (global)" }]
                                for (var i = 0; i < root.liveMonitors.length; i++) {
                                    var m = root.liveMonitors[i]
                                    out.push({ value: String(m.key), label: String(m.name) })
                                }
                                return out
                            }
                            value: root.formMonitor
                            onChanged: function(v) { root.formMonitor = String(v) }
                        }

                        Dropdown {
                            id: specialDropdown
                            Layout.fillWidth: true
                            label: "Scratchpad"
                            fontFamily: root.fontFamily
                            // The specials Hyprland has right now, plus an escape
                            // hatch: a special workspace exists only while it holds
                            // a window, so one not yet opened cannot be listed.
                            options: {
                                var out = [{ value: "", label: "None (use workspace)" }]
                                for (var i = 0; i < root.liveSpecials.length; i++) {
                                    var name = String(root.liveSpecials[i])
                                    out.push({ value: name, label: name })
                                }
                                out.push({ value: root.newSpecialSentinel, label: "New scratchpad..." })
                                return out
                            }
                            value: root.specialChoice
                            onChanged: function(v) {
                                root.specialChoice = String(v)
                                // The sentinel is a mode, not a name: the field
                                // below supplies the actual name.
                                root.formSpecial = root.specialChoice === root.newSpecialSentinel
                                    ? specialNameField.text.trim()
                                    : root.specialChoice
                            }
                        }

                        TextField {
                            id: specialNameField
                            Layout.fillWidth: true
                            visible: root.specialChoice === root.newSpecialSentinel
                            verticalPadding: Style.space(9)
                            placeholderText: "new scratchpad name (e.g. email)"
                            foreground: root.foreground
                            accent: Color.accent
                            font.family: root.fontFamily
                            onTextChanged: {
                                if (root.specialChoice === root.newSpecialSentinel)
                                    root.formSpecial = text.trim()
                            }
                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Escape) {
                                    root.close()
                                    event.accepted = true
                                }
                            }
                        }

                        PanelSectionHeader {
                            text: "PICK A WORKSPACE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        // Workspace picker 1-10 (5 per row).
                        //
                        // Which screen's workspace 1-10 these mean is the Screen
                        // dropdown above. A special workspace is not a numbered
                        // slot, so the grid is disabled when one is chosen.
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 5
                            columnSpacing: Style.space(4)
                            rowSpacing: Style.space(4)
                            enabled: root.formSpecial === ""
                            opacity: enabled ? 1.0 : 0.4
                            Repeater {
                                model: 10
                                delegate: Button {
                                    required property int index
                                    text: String(index+1)
                                    selected: root.workspacePicked && root.formWorkspace===(index+1)
                                    horizontalPadding: 0
                                    verticalPadding: 0
                                    onClicked: { root.workspacePicked = true; root.formWorkspace=index+1; root.persistFormWorkspace() }
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Style.space(34)
                                }
                            }
                        }

                        PanelSeparator {
                            Layout.fillWidth: true
                            foreground: root.foreground
                        }

                        PanelSectionHeader {
                            text: "SEARCH APPS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        // App picker
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)
                            TextField {
                                id: filterField
                                Layout.fillWidth: true
                                verticalPadding: Style.space(9)
                                placeholderText: "Search installed apps..."
                                foreground: root.foreground
                                accent: Color.accent
                                font.family: root.fontFamily
                                text: root.appFilter
                                onTextChanged: { root.appFilter = text; root.cursorActive = false }
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Escape) {
                                        root.close()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                        var direction = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1
                                        if (direction < 0 && !root.cursorActive) {
                                            var rows = root.filteredApps
                                            if (rows.length > 0) {
                                                root.setCursor(rows.length - 1, 0)
                                                keyCatcher.forceActiveFocus()
                                            }
                                        } else {
                                            root.moveTabCursor(direction)
                                            if (root.cursorActive) keyCatcher.forceActiveFocus()
                                        }
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Down) {
                                        root.setCursor(0, 0)
                                        keyCatcher.forceActiveFocus()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Up) {
                                        var rows = root.filteredApps
                                        if (rows.length > 0) {
                                            root.setCursor(rows.length - 1, 0)
                                            keyCatcher.forceActiveFocus()
                                            event.accepted = true
                                        }
                                    }
                                }
                            }
                            Button { text: "⟳"; tooltipText: "Refresh app list"; verticalPadding: Style.space(9); onClicked: appsProc.running=true }
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length>0
                            Layout.fillWidth: true
                            text: "No matches"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length===0
                            Layout.fillWidth: true
                            text: "No apps assigned yet — type to search and add"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        // Results — scrollable (plugin-manager pattern)
                        ScrollView {
                            id: resultsScroll
                            visible: root.filteredApps.length>0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            // A floor, because this is the only fillHeight item in
                            // the column: anything added above it otherwise eats
                            // its height silently and the search looks broken with
                            // no error anywhere.
                            Layout.minimumHeight: Style.space(120)
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ScrollBar.vertical.policy: ScrollBar.AsNeeded

                            Column {
                                width: resultsScroll.width
                                spacing: Style.space(6)

                                Repeater {
                                    model: root.filteredApps
                                    delegate: AppRow {
                                        app: modelData
                                        rowIndex: index
                                        width: parent.width
                                    }
                                }
                            }
                        }
                    }

                    // ——— Col 2: preview ———
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: Math.round(content.width * 0.70)
                        Layout.alignment: Qt.AlignTop
                        spacing: Style.space(10)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)
                            Button {
                                text: "Preview"
                                selected: root.rightView === "preview"
                                verticalPadding: Style.space(4)
                                onClicked: root.rightView = "preview"
                            }
                            Button {
                                text: "Assignments (" + root.assignments.length + ")"
                                tooltipText: "Every assignment, on every screen and scratchpad"
                                selected: root.rightView === "assignments"
                                verticalPadding: Style.space(4)
                                onClicked: root.rightView = "assignments"
                            }
                            Item { Layout.fillWidth: true }
                            Button {
                                visible: root.rightView === "preview"
                                text: root.hyprLayout === "scrolling" ? "⇄ dwindle" : "⇄ scrolling"
                                tooltipText: root.formSpecial !== "" || root.formMonitor !== ""
                                    ? "Layouts are saved per global workspace, so this does not apply to " + root.formTargetLabel
                                    : "Toggle WS" + root.formWorkspace + " between dwindle and scrolling (saved, same as Super+L)"
                                enabled: root.formSpecial === "" && root.formMonitor === ""
                                opacity: enabled ? 1.0 : 0.4
                                verticalPadding: Style.space(4)
                                onClicked: root.toggleHyprLayout()
                            }
                        }

                        WorkspacePreview {
                            visible: root.rightView === "preview"
                            Layout.fillWidth: true
                            Layout.fillHeight: root.rightView === "preview"
                            Layout.preferredHeight: root.rightView === "preview" ? -1 : 0
                            Layout.minimumHeight: root.rightView === "preview"
                                ? Math.min(Style.space(200), Math.round(panel.screenH * 0.3)) : 0
                            bar: root.bar
                            workspace: root.formWorkspace
                            targetLabel: root.formTargetLabel
                            assignedApps: root.addedApps
                            appList: root.appList
                            screenW: panel.screenW
                            screenH: panel.screenH
                            hyprLayout: root.hyprLayout
                            columnWidth: root.hyprColumnWidth
                            hyprGapsIn: root.hyprGapsIn
                            hyprGapsOut: root.hyprGapsOut
                            hyprBorder: root.hyprBorder
                            hyprRounding: root.hyprRounding
                            hyprMfact: root.hyprMfact
                            hyprScale: root.hyprScale
                            monW: root.monW
                            monH: root.monH
                            barPos: panel.barPos
                            barSizeH: panel.barH
                            barSizeW: panel.barW
                            onMoveApp: function(fromIdx, toIdx) { root.reorderAssignment(root.formTargetKey, fromIdx, toIdx) }
                        }

                        // Every assignment, whatever screen or scratchpad it is
                        // on. The rest of the panel is scoped to one target, so
                        // this is the only place the whole set is visible.
                        ScrollView {
                            id: assignmentsScroll
                            visible: root.rightView === "assignments"
                            Layout.fillWidth: true
                            Layout.fillHeight: root.rightView === "assignments"
                            Layout.minimumHeight: root.rightView === "assignments"
                                ? Math.min(Style.space(200), Math.round(panel.screenH * 0.3)) : 0
                            Layout.preferredHeight: root.rightView === "assignments" ? -1 : 0
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ScrollBar.vertical.policy: ScrollBar.AsNeeded

                            Column {
                                width: assignmentsScroll.width
                                spacing: Style.space(4)

                                Repeater {
                                    model: root.assignments
                                    delegate: Rectangle {
                                        required property var modelData
                                        required property int index
                                        readonly property bool isCurrent: Model.targetKey(modelData) === root.formTargetKey

                                        width: parent ? parent.width : 0
                                        height: Style.space(52)
                                        radius: Style.space(6)
                                        // The rows on the target the pickers point at are
                                        // the ones the rest of the panel is acting on.
                                        color: isCurrent ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                                                         : "transparent"

                                        // Behind the controls: a click on the row's
                                        // empty space navigates, a click on a
                                        // dropdown or button does its own thing.
                                        MouseArea {
                                            anchors.fill: parent
                                            z: -1
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.selectAssignmentTarget(modelData)
                                        }

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: Style.space(10)
                                            anchors.rightMargin: Style.space(8)
                                            spacing: Style.space(8)

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    elide: Text.ElideRight
                                                    text: modelData.name
                                                    color: modelData.enabled === false ? root.dim : root.foreground
                                                    font.family: root.fontFamily
                                                    font.pixelSize: Style.font.body
                                                }
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    elide: Text.ElideRight
                                                    text: modelData.type
                                                        + (modelData.onlyOnBoot ? " · once per boot" : " · every restart")
                                                    color: root.dim
                                                    font.family: root.fontFamily
                                                    font.pixelSize: Style.font.caption - 1
                                                }
                                            }

                                            // Where this assignment launches. One
                                            // control for the screen-or-scratchpad
                                            // axis and one for the slot, mirroring
                                            // the pickers on the left but scoped to
                                            // this row.
                                            Dropdown {
                                                Layout.preferredWidth: Style.space(150)
                                                showLabel: false
                                                fontFamily: root.fontFamily
                                                rowHeight: Style.space(30)
                                                options: {
                                                    var out = [{ value: "", label: "Any screen" }]
                                                    for (var i = 0; i < root.liveMonitors.length; i++) {
                                                        var m = root.liveMonitors[i]
                                                        out.push({ value: "mon:" + m.key, label: String(m.name) })
                                                    }
                                                    for (var j = 0; j < root.liveSpecials.length; j++) {
                                                        var sp = String(root.liveSpecials[j])
                                                        out.push({ value: "special:" + sp, label: "⬒ " + sp })
                                                    }
                                                    // An assignment can sit on a special that no
                                                    // longer exists -- a scratchpad is deleted when
                                                    // its last window closes -- so keep its own
                                                    // value selectable.
                                                    if (modelData.special
                                                        && root.liveSpecials.indexOf(modelData.special) === -1)
                                                        out.push({ value: "special:" + modelData.special,
                                                                   label: "⬒ " + modelData.special })
                                                    return out
                                                }
                                                value: modelData.special ? ("special:" + modelData.special)
                                                     : (modelData.monitor ? ("mon:" + modelData.monitor) : "")
                                                onChanged: function(v) {
                                                    var val = String(v)
                                                    root.retargetAssignment(modelData.id, {
                                                        monitor: val.indexOf("mon:") === 0 ? val.substring(4) : null,
                                                        special: val.indexOf("special:") === 0 ? val.substring(8) : null,
                                                        workspace: modelData.workspace
                                                    })
                                                }
                                            }

                                            Dropdown {
                                                Layout.preferredWidth: Style.space(74)
                                                showLabel: false
                                                fontFamily: root.fontFamily
                                                rowHeight: Style.space(30)
                                                // A special workspace is not a numbered slot.
                                                enabled: !modelData.special
                                                opacity: enabled ? 1.0 : 0.35
                                                options: {
                                                    var out = []
                                                    for (var i = 1; i <= 10; i++)
                                                        out.push({ value: String(i), label: "WS" + i })
                                                    return out
                                                }
                                                value: String(modelData.workspace)
                                                onChanged: function(v) {
                                                    root.retargetAssignment(modelData.id, {
                                                        monitor: modelData.monitor,
                                                        special: modelData.special,
                                                        workspace: parseInt(String(v), 10)
                                                    })
                                                }
                                            }

                                            Button {
                                                text: "↗"
                                                tooltipText: "Launch " + modelData.name + " now"
                                                horizontalPadding: Style.space(8)
                                                verticalPadding: Style.space(2)
                                                onClicked: root.launchAssignmentNow(modelData)
                                            }

                                            ToggleSwitch {
                                                checked: modelData.enabled !== false
                                                onToggled: root.setAssignmentEnabled(modelData.id, !(modelData.enabled !== false))
                                            }

                                            Button {
                                                text: "✕"
                                                tooltipText: "Remove " + modelData.name + " from " + Model.targetLabel(modelData, root.liveMonitors)
                                                horizontalPadding: Style.space(8)
                                                verticalPadding: Style.space(2)
                                                onClicked: {
                                                    root.statusText = "Removed " + modelData.name
                                                    clearStatusTimer.restart()
                                                    root.removeAssignment(modelData.id)
                                                }
                                            }
                                        }
                                    }
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    visible: root.assignments.length === 0
                                    width: parent ? parent.width : 0
                                    text: "No assignments yet — search for an app and toggle it on."
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                }
                            }
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: root.rightView === "assignments"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: "Change where an app launches with its two dropdowns · click a row to point the pickers at it · ↗ launches now · ✕ removes"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption - 1
                        }

                        Text {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: (root.hyprLayout === "scrolling"
                                  ? root.formTargetLabel + " scrolling: windows sit side-by-side (" + Math.round(root.hyprColumnWidth*100) + "% cols) — scroll horizontally to see all " + root.addedApps.length + "."
                                  : root.hyprLayout === "master"
                                  ? root.formTargetLabel + " master: left master + right stack."
                                  : root.formTargetLabel + " dwindle: binary split tiling.")
                                  + " Tip: drag a tile onto another to reorder · ⇄ button switches this workspace only."
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption - 1
                            visible: root.rightView === "preview" && root.addedApps.length > 1
                        }
                    }
                }

                // ——— Footer: status ———
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(12)

                    Text {
                        textFormat: Text.PlainText
                        visible: root.statusText!==""
                        text: "✓ " + root.statusText
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    Text {
                        textFormat: Text.PlainText
                        visible: root.errorText!==""
                        text: root.errorText
                        color: Color.urgent || "#ff4444"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }

    component AppRow: CursorSurface {
        property var app: null
        property int rowIndex: 0
        readonly property bool rowSelected: root.cursorActive && root.selectedRow === rowIndex
        hasCursor: rowSelected
        foreground: root.foreground
        implicitHeight: Style.space(44)

        onRowSelectedChanged: if (rowSelected) root.ensureCursorVisible(this)

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Item {
                Layout.preferredWidth: Style.space(22)
                Layout.alignment: Qt.AlignVCenter
                Image {
                    id: rowIcon
                    anchors.centerIn: parent
                    visible: source !== ""
                    width: 16
                    height: 16
                    source: app ? root.iconSourceFor(app) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    onStatusChanged: if (status === Image.Error) source = ""
                }
                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: rowIcon.source === ""
                    text: "󰐱"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    textFormat: Text.PlainText
                    text: app ? app.name : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    textFormat: Text.PlainText
                    text: app ? (app.exec.indexOf("omarchy-launch-webapp") !== -1 ? "web app" : app.exec.split(" ")[0].split("/").pop()) : ""
                    color: root.dim
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            ToggleSwitch {
                Layout.alignment: Qt.AlignVCenter
                checked: app ? root.isInList(root.addedApps, app.exec) : false
                cursorRing: true
                cursorPad: Style.space(3)
                foreground: root.foreground
                accent: Color.accent
                hasCursor: rowSelected && root.selectedButton === 0
                onHovered: function(on) {
                    if (on) root.setCursor(rowIndex, 0)
                }
                onToggled: if (app) root.toggleInWorkspace(app.exec, app.name)
            }
        }
    }

    Component.onCompleted: { loadConfig(); appsProc.running = true; layoutProc.running = true }
}