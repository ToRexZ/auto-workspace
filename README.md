# Auto Workspace

Auto-launch apps on workspaces at boot/login for Omarchy Quattro + Hyprland.

Assign YouTube to workspace 1 so it always opens there, put Code + Terminal on workspace 2, etc. Supports multiple apps per workspace, silent launch, and per-boot dedup.

> **This is a fork** of [yesheytenzin/auto-workspace](https://github.com/yesheytenzin/auto-workspace)
> adding per-monitor and scratchpad targets — see [Targets](#targets).
> `origin` is this fork, `upstream` is tenzin's.

## Install

```sh
omarchy plugin add https://github.com/ToRexZ/auto-workspace.git --enable
# or manual drop-in for dev:
mkdir -p ~/.config/omarchy/plugins/tenzin.auto-workspace
cp -r /path/to/auto_workspace/* ~/.config/omarchy/plugins/tenzin.auto-workspace/
omarchy-shell shell rescanPlugins
omarchy plugin enable tenzin.auto-workspace
# bar widget appears in left section; move if desired:
omarchy bar move tenzin.auto-workspace --section left
```

## Usage

1. Click the 󰨧 icon in the bar (left) → **Auto Workspace** panel.
2. Click **+ Add**, pick workspace 1-10, type name + command/URL, choose type:
   - **App** — `.desktop` Exec like `code`, `spotify`, `foot`, `chromium`
   - **Web App** — URL like `https://youtube.com` (uses `omarchy-launch-webapp`)
   - **Custom** — raw command as-is
3. **Add to WS** — saved to `~/.local/state/omarchy/auto-workspace/config.json` (legacy plugin-folder config is auto-migrated).
4. Click **Launch all** to test now, or `↗` on a single rule. On next boot/login it launches automatically.

Tips:
- Centered panel: icon may be left/center/right — panel always opens centered (`centerOnBar: true`, 720 wide) for a full workspace overview.
- **Workspace list (1-10):** each WS shows count, assigned apps, and a live preview. Expand a WS to see its apps, drag tiles to reorder launch order or drag between workspaces to move assignments — preview updates live (dwindle mock for 1-4 apps, grid for >4). **Hypr live preview (maybe):** shows `● live N` + chips for windows currently on that WS from `hyprctl clients -j` (polls every 2s when open), updates as you launch/move windows.
- Multiple apps on same workspace → they tile/float per that workspace's Hyprland layout. Preview follows the selected workspace. The ⇄ dwindle/scrolling button sets **this workspace only** (same persist path as Super+L: `~/.local/state/omarchy/workspace-layouts/<id>.lua`).
- Use filter box to pick from installed `.desktop` apps quickly.
- Per-workspace launch is `hyprctl eval 'hl.exec_cmd("[workspace N silent] <cmd>")'` — doesn't steal focus.
- **Launch timing is now per-app by type:** `Web App` (Chromium zygote) defaults to `Once per boot` (no duplicate on rescan), `App` (native foot/ghostty/code) defaults to `Every restart` (closed windows come back), `Custom` defaults to `Once per boot`. Change via `Once/Every` toggle per row or `Launch: Once per boot / Every restart` when adding.

## Targets

An assignment can go to one of three places. `workspace` is the slot number it
always was; two optional fields say what to read it against.

| Config | Launches on |
| --- | --- |
| `"workspace": 3` | global workspace 3 — Omarchy's default, unchanged |
| `"workspace": 3, "monitor": "<key>"` | that screen's workspace 3 |
| `"special": "scratchpad"` | the `scratchpad` special workspace |

`special` wins if both are set. In the panel these are the **Place on** and
**Or a scratchpad** pickers above the numbered grid.

### Per-monitor workspaces

`monitor` is a screen's *workspace-name key*, as
[mmsbrggr.per-monitor-workspaces](https://github.com/mmsbrggr/omarchy-per-monitor-workspaces)
builds it — that plugin names each screen's workspaces `<key>:<slot>`, and this
targets the same names, so an assignment lands on the workspace that plugin's
bar actually shows.

The key is the monitor's description, with the connector appended when two
screens describe themselves alike, or the connector alone when there is no
description. List them with:

```sh
./auto-workspace.sh --monitor-keys
```

The panel shows connectors (`eDP-1`) and stores keys, so there is nothing to
type. Per-monitor targeting works without that plugin installed — it is only
the naming scheme that is shared — but the bar will not show those workspaces.

**An assignment whose monitor is not connected is skipped, not moved.** Boot
undocked and your external screens' assignments simply do not launch, rather
than piling onto the laptop.

### Scratchpads

`special` is a Hyprland special workspace — what `SUPER+S` toggles. The panel
lists the ones that exist right now, and takes a typed name for one that does
not; a special workspace only exists while it holds a window, so a name you
have not used yet will not be offered until something is in it.

With Omarchy's `hide_special_on_workspace_change`, an app launched into a
scratchpad stays out of the way until you press its key.

## Tests

The targeting model, the monitor-key algorithm and the selector validation are
plain JS and bash, and are tested without a compositor:

```sh
node --test tests/
```

The monitor-key and target-resolution logic exists twice — `Model.js` for the
panel, jq and bash in `auto-workspace.sh` for the launcher — because the two
runtimes cannot share code. `tests/monitor-keys.test.js` and
`tests/resolve-target.test.js` run both over the same fixtures and assert they
agree, because a disagreement is silent: assignments would launch onto
workspaces the bar does not show. Run them after touching either copy.

## Config

`~/.local/state/omarchy/auto-workspace/config.json`:
```json
{
  "version": 1,
  "settings": {
    "enabled": true,
    "launchDelayMs": 800,
    "staggerMs": 400,
    "silent": true,
    "onlyOnBoot": true
  },
  "assignments": [
    { "id": "aw-...", "workspace": 1, "name": "YouTube", "command": "https://youtube.com", "exec": "omarchy-launch-webapp 'https://youtube.com'", "type": "webapp", "enabled": true, "onlyOnBoot": true },
    { "id": "aw-...", "workspace": 2, "name": "Foot", "command": "foot --app-id=foot-work", "exec": "foot --app-id=foot-work", "type": "app", "enabled": true, "onlyOnBoot": false }
  ]
}
```

## CLI

Helper script at `~/.config/omarchy/plugins/tenzin.auto-workspace/auto-workspace.sh`:

```sh
auto-workspace.sh --status
auto-workspace.sh --list-apps
auto-workspace.sh --launch 1 "chromium --app=https://youtube.com"
auto-workspace.sh --launch-all
auto-workspace.sh --force-launch-all
omarchy-shell -q tenzin.auto-workspace launchAll
omarchy-shell -q tenzin.auto-workspace forceLaunchAll
omarchy-shell -q tenzin.auto-workspace status
```

## How it works

- `Service.qml` (kind `service`) runs on shell start (`Component.onCompleted`). It ensures config exists, then after `launchDelayMs` spawns `auto-workspace.sh --launch-all` via `Process`. Respects `onlyOnBoot` by remembering `/proc/sys/kernel/random/boot_id` in `~/.local/state/omarchy/auto-workspace/last_boot_id` and dedups against `hyprctl clients -j`.
- `BarWidget.qml` + `Panel.qml` (kind `bar-widget`) provides the management UI. No sudo, no network.

## Update

```sh
omarchy plugin update tenzin.auto-workspace
# update all plugins
omarchy plugin update
```

## Remove

```sh
omarchy plugin remove tenzin.auto-workspace
rm -rf ~/.config/omarchy/plugins/tenzin.auto-workspace ~/.local/state/omarchy/auto-workspace
```

## License

MIT
