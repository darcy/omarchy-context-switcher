import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "ContextModel.js" as Model

// Context Switcher service.
//
// Owns per-monitor workspace-context state and implements the slot/context
// switching commands. Exposes them over IPC (target "context") so the
// omarchy-context-switcher CLI and keybindings can drive it, and keeps the bar-widget
// in sync by emitting `stateUpdated` and `refreshRequested`.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/context-switcher"
  readonly property string configFile: configDir + "/config.json"
  readonly property string stateDir: home + "/.local/state/context-switcher"
  readonly property string stateFile: stateDir + "/context.json"
  readonly property string defaultContextId: "personal"

  property var config: ({ contexts: [], slots: 10 })
  property var state: Model.defaultState()
  property bool configLoaded: false
  property bool stateLoaded: false
  property string focusedMonitorName: ""
  property string currentContextId: root.defaultContextId
  property string lastError: ""

  // Workspaces by id -> true when occupied (has clients). Refreshed on demand.
  property var workspacesById: ({})
  // Authoritative monitor name -> active workspace id (from the hyprctl probe).
  property var monitorActiveWorkspace: ({})

  // Emitted when context state changes so the bar-widget can re-render.
  signal stateUpdated()
  // Ask the bar-widget to re-render (e.g. after a slot command).
  signal refreshRequested()

  // ---- Config / state loading (via Process + SplitParser) ----

  // Bounded reads: only regular files up to 256 KiB are streamed into QML, and
  // a `timeout` caps any FIFO swapped in between the checks, so a replaced or
  // planted file can neither stall the shell nor inflate its memory. The
  // config probe emits sentinels so applyConfig can tell "missing" (bootstrap)
  // apart from "present but unreadable" (error, never overwrite).
  function loadConfig() {
    configProbe.command = ["bash", "-lc",
      "F=" + Util.shellQuote(root.configFile) + "\n" +
      "[[ -e \"$F\" ]] || exit 0\n" +
      "[[ -f \"$F\" ]] || { echo '__CTX_NOT_REGULAR__'; exit 0; }\n" +
      "S=$(stat -c %s \"$F\" 2>/dev/null)\n" +
      "[[ -n \"${S:-0}\" && \"${S:-0}\" =~ ^[0-9]+$ && \"${S:-0}\" -le 262144 ]] || { echo '__CTX_OVERSIZE__'; exit 0; }\n" +
      "timeout 5 cat \"$F\" 2>/dev/null"]
    configProbe.running = true
  }

  function loadState() {
    stateProbe.command = ["bash", "-lc",
      "F=" + Util.shellQuote(root.stateFile) + "\n" +
      "[[ -e \"$F\" ]] || exit 0\n" +
      "[[ -f \"$F\" ]] || exit 0\n" +
      "S=$(stat -c %s \"$F\" 2>/dev/null)\n" +
      "[[ -n \"${S:-0}\" && \"${S:-0}\" =~ ^[0-9]+$ && \"${S:-0}\" -le 262144 ]] || exit 0\n" +
      "timeout 5 cat \"$F\" 2>/dev/null"]
    stateProbe.running = true
  }

  function applyConfig(raw) {
    var text = String(raw || "").trim()
    if (text === "__CTX_NOT_REGULAR__") {
      // Present but not a regular file (e.g. a planted FIFO): never bootstrap
      // over it, and never let a later read block on it.
      root.lastError = "config path is not a regular file: " + root.configFile
      root.configBootstrapDone = true
      return
    }
    if (text === "__CTX_OVERSIZE__") {
      root.lastError = "config exceeds the 256 KiB read limit"
      root.configBootstrapDone = true
      return
    }
    if (!text) {
      // First run: bootstrap the default config (Personal + Work; existing
      // workspaces fall into Personal as context 0), then reload + build the
      // generated files.
      if (!root.configBootstrapDone) {
        root.configBootstrapDone = true
        initProc.command = ["bash", "-lc", "omarchy-context-switcher-init >/dev/null 2>&1"]
        initProc.running = true
      }
      return
    }
    try {
      var parsed = JSON.parse(text)
      if (!parsed.contexts || !Array.isArray(parsed.contexts)) {
        root.lastError = "config has no contexts array"
        return
      }
      root.config = parsed
      root.configLoaded = true
      root.lastError = ""
      // The menu bakes in the active context (hiding Go to / Move to for the
      // context you are in); the first context-sync may run before the config
      // loads, so ensure a regeneration happens once it has.
      Qt.callLater(function() { root.maybeRegenerateMenu() })
    } catch (e) {
      root.lastError = "config JSON parse failed: " + e
    }
  }

  function applyState(raw) {
    var text = String(raw || "").trim()
    if (!text) { root.state = Model.defaultState(); return }
    try { root.state = JSON.parse(text) } catch (e) { root.state = Model.defaultState() }
    root.stateLoaded = true
  }

  // ---- Persist state ----

  function persistState() {
    var json = JSON.stringify(root.state)
    // Atomic via an unpredictable temp (mktemp) + rename: a planted symlink at
    // the state path can never redirect the write, and a crash mid-write can
    // never leave a truncated state file behind.
    stateWriter.command = ["bash", "-lc",
      "mkdir -p " + Util.shellQuote(root.stateDir) + "\n" +
      "T=$(mktemp " + Util.shellQuote(root.stateFile + ".XXXXXX") + ") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "printf '%s' " + JSON.stringify(json) + " > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" " + Util.shellQuote(root.stateFile)]
    stateWriter.running = true
  }

  // ---- Current focused monitor + context ----
  //
  // Event-driven: rebuilt from the live Quickshell Hyprland.monitors model,
  // which exposes activeWorkspaceChanged / focusedChanged signals on each
  // monitor. No hyprctl polling (hyprctl is a blocking compositor IPC and
  // stalls interaction), so updates ride on the model's own change signals.

  // Rebuild the monitorActiveWorkspace map, focused monitor name, and derived
  // context from the live monitors model. Called on startup and whenever a
  // monitor's active workspace or focused state changes.
  // Update the focused monitor name and derive the current context from the
  // authoritative monitorActiveWorkspace map (maintained from raw events / the
  // seed), falling back to the focusedWorkspace singleton only if the map has
  // no entry for the focused monitor. Does NOT rebuild the per-monitor map.
  function syncMonitors() {
    var prevCtx = root.currentContextId
    var focusedName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var nameChanged = (focusedName || "default") !== root.focusedMonitorName
    root.focusedMonitorName = focusedName || "default"

    // Authoritative: the focused monitor's active workspace from the event/seed
    // map. This is what the bar highlights, so goto/switch must agree with it.
    var map = root.monitorActiveWorkspace || {}
    var activeWs = map[focusedName] ? Number(map[focusedName]) || 0 : 0
    if (!activeWs) {
      var fw = Hyprland.focusedWorkspace
      activeWs = fw ? Number(fw.id) || 0 : 0
    }
    var derived = activeWs > 0 ? Model.contextForWorkspace(root.config, activeWs) : ""
    var changed = nameChanged
    if (derived) {
      if (derived !== root.currentContextId) changed = true
      root.currentContextId = derived
      var existing = (root.state.monitor_context || {})[root.focusedMonitorName]
      if (existing !== derived) {
        root.state = Model.setMonitorContext(root.state, root.focusedMonitorName, derived)
        root.persistState()
      }
    } else {
      var fallback = Model.monitorContext(root.state, root.focusedMonitorName, root.defaultContextId)
      if (fallback !== root.currentContextId) changed = true
      root.currentContextId = fallback
    }
    if (changed) root.stateUpdated()
  }

  // (Monitor change handling is wired via Hyprland singleton signals below —
  // focusedWorkspaceChanged / focusedMonitorChanged / rawEvent — which fire
  // after the monitors model updates, so no polling is needed.)

  // ---- Workspace occupancy ----

  function refreshWorkspaces() {
    var byId = {}
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws) continue
      var occupied = ws.toplevels && ws.toplevels.values && ws.toplevels.values.length > 0
      byId[String(ws.id)] = occupied
    }
    root.workspacesById = byId
  }

  // ---- Workspace dispatch helpers ----
  // Hyprland 0.56's Lua config requires dispatch through hl.dsp / hl.dispatch
  // via `hyprctl eval`, not the old `hyprctl dispatch <kw> <args>` form.

  function runEval(luaExpr) {
    var p = dispatchProc
    p.command = ["bash", "-lc", "hyprctl eval 'hl.dispatch(" + luaExpr + ")'"]
    p.running = true
  }

  // Focus/switch to a workspace id. If that workspace is already shown on a
  // monitor, focus that monitor instead of moving the workspace to the
  // currently-focused monitor ("go to where it already is").
  function focusWorkspace(wsId) {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (m && m.activeWorkspace && Number(m.activeWorkspace.id) === Number(wsId)) {
        runEval('hl.dsp.focus({ monitor = "' + m.name + '" })')
        return
      }
    }
    runEval('hl.dsp.focus({ workspace = "' + wsId + '" })')
  }

  // Move the active window to a workspace id (follow=false => silent).
  function moveWindowTo(wsId, silent) {
    runEval('hl.dsp.window.move({ workspace = "' + wsId + '", follow = ' + (silent ? "false" : "true") + ' })')
  }

  // Move a workspace id to a monitor by name.
  function moveWorkspaceToMonitor(wsId, monitor) {
    runEval('hl.dsp.workspace.move({ workspace = "' + wsId + '", monitor = "' + monitor + '" })')
  }

  // Cycle the active workspace to the next/prev monitor and focus it there.
  // Context is context-aware: the target monitor takes the moved workspace's
  // context, and every monitor's context is re-derived live.
  function cycleMonitor(direction) {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    if (mons.length <= 1) return "ok"
    var wsId = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : 0
    if (wsId <= 0) return "ok"

    // Stable monitor order by id; find the one currently hosting the workspace.
    var sorted = mons.slice().sort(function(a, b) { return Number(a.id) - Number(b.id) })
    var names = []
    var ids = []
    for (var i = 0; i < sorted.length; i++) { names.push(String(sorted[i].name)); ids.push(String(sorted[i].id)) }

    var idx = -1
    for (i = 0; i < sorted.length; i++) {
      var m = sorted[i]
      if (m.activeWorkspace && Number(m.activeWorkspace.id) === wsId) { idx = i; break }
    }
    if (idx < 0) {
      var focusedName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
      for (i = 0; i < names.length; i++) { if (names[i] === focusedName) { idx = i; break } }
    }
    if (idx < 0) return "error"

    var count = names.length
    var nextIdx = direction === "prev" ? ((idx - 1 + count) % count) : ((idx + 1) % count)
    var target = names[nextIdx]

    // Move the workspace to the target monitor, then focus it there — chained
    // in a single bash line so the focus happens only after the move lands
    // (avoids the two async evals racing each other).
    var moveEval = 'hl.dispatch(hl.dsp.workspace.move({ workspace = "' + wsId + '", monitor = "' + target + '" }))'
    var focusEval = 'hl.dispatch(hl.dsp.focus({ monitor = "' + target + '" }))'
    var p = dispatchProc
    p.command = ["bash", "-lc", "hyprctl eval '" + moveEval + "'; hyprctl eval '" + focusEval + "'"]
    p.running = true

    // Wait a beat for the move to land, then probe hyprctl for the focused
    // monitor's real workspace so the context follows correctly. The poll
    // timer also re-probes, so this self-heals even if the move is slow.
    Qt.callLater(function() {
      root.syncMonitors()
      root.stateUpdated()
    })
    return "ok"
  }

  function targetWorkspaceForMonitor(targetId, activeMonitor) {
    var last = root.state.last_workspace ? root.state.last_workspace[targetId] : undefined
    if (last === undefined || last === null) last = 1
    return Model.realWorkspaceId(root.config, targetId, last)
  }

  // ---- Commands (invoked from IPC) ----

  // Switch the active monitor's context to targetId, restoring its last slot.
  function switchContext(targetId) {
    if (!Model.contextExists(root.config, targetId)) { root.lastError = "unknown context: " + targetId; return "unknown" }
    root.syncMonitors()
    var monitor = root.focusedMonitorName
    var last = root.state.last_workspace ? root.state.last_workspace[targetId] : 1
    if (last === undefined || last === null) last = 1
    var targetWs = Model.realWorkspaceId(root.config, targetId, last)

    root.focusWorkspace(targetWs)

    // The context belongs to whichever monitor actually ends up showing it.
    Qt.callLater(function() {
      root.syncMonitors()
      var activeMonitor = root.focusedMonitorName
      root.state = Model.setMonitorContext(root.state, activeMonitor, targetId)
      root.state = Model.setLastWorkspace(root.state, targetId, last)
      root.persistState()
      root.refreshCurrentContext()
      root.stateUpdated()
    })
    return "ok"
  }

  // Go to a slot within the active monitor's current context.
  function gotoSlot(slotStr) {
    var slot = Number(slotStr)
    if (!isFinite(slot) || slot < 1 || slot > (root.config.slots || 10)) { root.lastError = "invalid slot"; return "error" }
    root.syncMonitors()
    var current = root.currentContextId
    var targetWs = Model.realWorkspaceId(root.config, current, slot)

    root.focusWorkspace(targetWs)
    Qt.callLater(function() {
      root.syncMonitors()
      var activeMonitor = root.focusedMonitorName
      root.state = Model.setMonitorContext(root.state, activeMonitor, current)
      root.state = Model.setLastWorkspace(root.state, current, slot)
      root.persistState()
      root.refreshCurrentContext()
      root.stateUpdated()
    })
    return "ok"
  }

  // Move the active window to a slot in the current context.
  function moveWindow(slotStr, silent) {
    var slot = Number(slotStr)
    if (!isFinite(slot) || slot < 1 || slot > (root.config.slots || 10)) { root.lastError = "invalid slot"; return "error" }
    root.syncMonitors()
    var current = root.currentContextId
    var targetWs = Model.realWorkspaceId(root.config, current, slot)
    var monitor = root.focusedMonitorName

    // Move the window to the slot workspace; keep it on the active monitor.
    root.moveWorkspaceToMonitor(targetWs, monitor)
    root.moveWindowTo(targetWs, silent)
    Qt.callLater(function() {
      root.syncMonitors()
      var activeMonitor = root.focusedMonitorName
      root.state = Model.setMonitorContext(root.state, activeMonitor, current)
      root.state = Model.setLastWorkspace(root.state, current, slot)
      root.persistState()
      root.stateUpdated()
    })
    return "ok"
  }

  // Move the active workspace's windows to the first empty slot of targetId.
  // Moves every window in the active workspace (by address) to the target
  // workspace, then focuses it — matching the legacy move-workspace behaviour.
  // The window-move loop lives in a helper script to avoid fragile QML->bash
  // string escaping.
  function moveWorkspace(targetId) {
    if (!Model.contextExists(root.config, targetId)) { root.lastError = "unknown context: " + targetId; return "unknown" }
    root.refreshWorkspaces()
    var slot = Model.findFirstEmptySlot(root.workspacesById, root.config, targetId)
    var targetWs = Model.realWorkspaceId(root.config, targetId, slot)

    var source = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
    if (source > 0 && source !== targetWs) {
      var p = dispatchProc
      p.command = ["bash", "-lc", "omarchy-context-switcher-move-workspace " + source + " " + targetWs]
      p.running = true
    }

    Qt.callLater(function() {
      root.syncMonitors()
      var activeMonitor = root.focusedMonitorName
      root.state = Model.setMonitorContext(root.state, activeMonitor, targetId)
      root.state = Model.setLastWorkspace(root.state, targetId, slot)
      root.persistState()
      root.stateUpdated()
    })
    return "ok"
  }

  // Cycle to next/prev workspace globally, updating the active monitor context.
  function cycleWorkspace(direction) {
    root.syncMonitors()
    root.refreshWorkspaces()
    var currentWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
    var slots = root.config.slots || 10
    var maxWs = 0
    var contexts = root.config.contexts || []
    for (var i = 0; i < contexts.length; i++) {
      var b = i * slots + 1
      var top = b + slots - 1
      if (top > maxWs) maxWs = top
    }
    var targetWs = direction === "prev" ? currentWs - 1 : currentWs + 1
    if (targetWs < 1) targetWs = maxWs
    if (targetWs > maxWs) targetWs = 1

    root.focusWorkspace(targetWs)
    Qt.callLater(function() {
      root.syncMonitors()
      var activeMonitor = root.focusedMonitorName
      var targetCtx = Model.contextForWorkspace(root.config, targetWs)
      var slot = Model.slotForWorkspace(root.config, targetWs)
      if (targetCtx) {
        root.state = Model.setMonitorContext(root.state, activeMonitor, targetCtx)
        root.state = Model.setLastWorkspace(root.state, targetCtx, slot)
        root.persistState()
        root.stateUpdated()
      }
    })
    return "ok"
  }

  // Switch to next/prev context.
  function switchRelative(delta) {
    root.syncMonitors()
    var monitor = root.focusedMonitorName
    var current = root.currentContextId
    var contexts = root.config.contexts || []
    if (contexts.length === 0) return "unknown"
    var idx = Model.contextIndex(root.config, current)
    if (idx < 0) idx = 0
    var n = contexts.length
    var nextIdx = ((idx + delta) % n + n) % n
    return root.switchContext(contexts[nextIdx].id)
  }

  function nextContext() { return root.switchRelative(1) }
  function prevContext() { return root.switchRelative(-1) }

  function currentContextName() {
    root.syncMonitors()
    root.refreshWorkspaces()
    return Model.contextName(root.config, root.currentContextId)
  }

  function listContexts() {
    var out = []
    var contexts = root.config.contexts || []
    for (var i = 0; i < contexts.length; i++) {
      var c = contexts[i]
      out.push(c.id + "\t" + (c.name || c.id) + "\t" + (c.shortcut || ""))
    }
    return out.join("\n")
  }

  function validateConfig() {
    // Minimal validation; returns config-valid string.
    if (root.configLoaded) return "Config is valid"
    return "Config is invalid: " + root.lastError
  }

  function refreshCurrentContext() {
    root.syncMonitors()
    root.refreshWorkspaces()
  }

  // ---- Config editing (used by the popup) ----
  //
  // Mutations rewrite ~/.config/context-switcher/config.json atomically via
  // jq (temp file + rename), then reload the config and — for structural
  // changes that move keybindings — regenerate the Hyprland binds. Callers
  // get their changes reflected through configLoaded / refreshRequested.

  Process {
    id: mutateProc
    property bool regen: false
    property var onDone: null
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        root.lastError = "config write failed"
        return
      }
      root.lastError = ""
      root.loadConfig()
      if (mutateProc.regen) root.regenerateBindings()
      root.regenerateMenu()
      root.refreshCurrentContext()
      root.refreshRequested()
      root.stateUpdated()
      var cb = mutateProc.onDone
      mutateProc.onDone = null
      if (cb) cb()
    }
  }

  // Runs a jq filter against the config, passing caller values via --arg so
  // no value is ever embedded inside a quoted shell/jq literal (avoids nested
  // quoting entirely). On success reloads config and, optionally, regenerates
  // keybindings.
  function runMutation(jqFilter, args, regen, onDone) {
    var argv = ["jq"]
    for (var k in (args || {})) argv.push("--arg", k, String(args[k]))
    argv.push(jqFilter, root.configFile)
    var quoted = []
    for (var i = 0; i < argv.length; i++) quoted.push(Util.shellQuote(argv[i]))
    // mktemp (O_EXCL, unpredictable) + rename: no fixed .tmp path an attacker
    // can pre-plant as a symlink to redirect the write into another file.
    var cmd = "T=$(mktemp " + Util.shellQuote(root.configFile + ".XXXXXX") + ") || exit 1\n" +
              "trap 'rm -f \"$T\"' EXIT\n" +
              quoted.join(" ") + " > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" " + Util.shellQuote(root.configFile)
    mutateProc.regen = regen
    mutateProc.onDone = onDone || null
    mutateProc.command = ["bash", "-lc", cmd]
    mutateProc.running = true
  }

  function renameContext(id, name) {
    runMutation("(.contexts = [.contexts[] | if .id == $id then .name = $name else . end])",
      { id: id, name: name }, false)
  }
  // Path-scoped item mutations. scope "" = the context's top-level menu;
  // "1.0" = .menu[1].items[0].items (submenu nesting; invalid hops are a
  // no-op). The jq walk passes only value args: the runtime jq (jaq)
  // evaluates filter-type function arguments against the caller's input,
  // which breaks recursion, and lacks setpath/getpath — hence the op-switch
  // inside the def. ops: add | delete | update | reorder (a/b = --arg values).
    function scopeMutationFilter(op) {
    return "def apply_into($idx; $op; $a; $b):\n" +
      "  if ($idx | length) == 0 then\n" +
      "    if   $op == \"add\"    then . + [ $a | fromjson ]\n" +
      "    elif $op == \"delete\" then map(select(.label != $a))\n" +
      "    elif $op == \"update\" then map(if .label == $a then ($b | fromjson) else . end)\n" +
      "    elif $op == \"move\"   then ( $a | fromjson ) as $mv\n" +
      "        | if ($mv.sourceLabel // \"\") == \"\" then .\n" +
      "          else\n" +
      "            ( (map(.label) | index($mv.sourceLabel)) as $si\n" +
      "              | if $si == null then .\n" +
      "                else\n" +
      "                  ( .[$si] ) as $it\n" +
      "                  | (.[:$si] + .[$si+1:]) as $rest\n" +
      "                  | (if ($mv.newLabel // \"\") != \"\" then\n" +
      "                       ($rest + [{label: $mv.newLabel, icon: \"\", type: \"submenu\", items: []}])\n" +
      "                     else $rest end) as $arr2\n" +
      "                  | (($arr2 | map(.label) | index(if ($mv.newLabel // \"\") != \"\" then $mv.newLabel else $mv.targetLabel end)) as $ti\n" +
      "                     | if (($mv.newLabel // \"\") == \"\" and $ti == null) or\n" +
      "                          ($ti != null and (($arr2[$ti].type // \"\") != \"submenu\" or $arr2[$ti].label == $it.label)) then .\n" +
      "                       else\n" +
      "                         ($arr2[$ti] as $target\n" +
      "                          | ($arr2 | map(\n" +
      "                              if .label == $target.label then\n" +
      "                                .items = ((.items // []) + [$it])\n" +
      "                              else . end)))\n" +
      "                       end)\n" +
      "                end)\n" +
      "          end\n" +
      "    else                      ( $a | fromjson )\n" +
      "    end\n" +
      "  else\n" +
      "    ($idx[0] as $i\n" +
      "     | if $i >= length then .\n" +
      "       else .[0:$i] + [ (.[$i] | if has(\"items\") then .items |= apply_into($idx[1:]; $op; $a; $b) else . end) ] + .[$i+1:]\n" +
      "       end)\n" +
      "  end;\n" +
      "(if $scope == \"\" then [] else ($scope | split(\".\") | map(tonumber)) end) as $idx\n" +
      "| (.contexts = [.contexts[] | if .id == $cid then\n" +
      "      .menu = (.menu | apply_into($idx; \"" + op + "\"; $a; $b))\n" +
      "    else . end])"
  }

  function setContextShortcut(id, shortcut) {
    runMutation("(.contexts = [.contexts[] | if .id == $id then .shortcut = $shortcut else . end])",
      { id: id, shortcut: Model.normalizeShortcut(shortcut) }, true)
  }

  function setContextIcon(id, icon) {
    runMutation("(.contexts = [.contexts[] | if .id == $id then .icon = $icon else . end])",
      { id: id, icon: icon || "" }, false)
  }

  // Store a context's Chrome profile directory. "" means "use the default"
  // (stored as null so it is absent).
  function setContextChromeProfile(id, profile) {
    runMutation("(.contexts = [.contexts[] | if .id == $id then .chrome_profile = (if $profile == \"\" then null else $profile end) else . end])",
      { id: id, profile: profile }, false)
  }

  function addContext(name, shortcut, icon, chromeProfile) {
    var slug = Model.slugify(name)
    if (!slug) { root.lastError = "context name must not be empty"; return "error" }
    if (Model.contextExists(root.config, slug)) { root.lastError = "context already exists: " + slug; return "error" }
    runMutation(".contexts += [{id: $slug, name: $name, shortcut: $shortcut, icon: $icon, chrome_profile: (if $profile == \"\" then null else $profile end), menu: []}]",
      { slug: slug, name: name, shortcut: Model.normalizeShortcut(shortcut), icon: icon || "", profile: chromeProfile || "" }, true)
    return "ok"
  }

  function deleteContext(id, targetId) {
    if (!Model.contextExists(root.config, id)) { root.lastError = "unknown context: " + id; return "unknown" }
    var cmd = "omarchy-context-switcher-delete-context " + Util.shellQuote(id)
    if (targetId && targetId !== id) cmd += " " + Util.shellQuote(targetId)
    deleteProc.command = ["bash", "-lc", cmd]
    deleteProc.running = true
    return "ok"
  }

  function addItem(contextId, label, url, icon) {
    if (!Model.contextExists(root.config, contextId)) { root.lastError = "unknown context: " + contextId; return "unknown" }
    if (!label) { root.lastError = "item title must not be empty"; return "error" }
    runMutation("(.contexts = [.contexts[] | if .id == $cid then .menu += [{label: $label, icon: $icon, type: \"web\", url: $url}] else . end])",
      { cid: contextId, label: label, url: url, icon: icon || "" }, false)
    return "ok"
  }

  function renameItem(contextId, oldLabel, newLabel) {
    runMutation("((.contexts[] | select(.id == $cid)).menu = [(.contexts[] | select(.id == $cid)).menu[] | if .label == $old then .label = $new else . end])",
      { cid: contextId, old: oldLabel, new: newLabel }, false)
  }

  function setItemIcon(contextId, label, icon) {
    runMutation("(.contexts = [.contexts[] | if .id == $cid then .menu = [.menu[] | if .label == $label then .icon = $icon else . end] else . end])",
      { cid: contextId, label: label, icon: icon || "" }, false)
  }

  // Delete the item labelled `label` from the menu array at `scope` ("" =
  // top level). Labels must be unique within a scope.
  function deleteItem(contextId, label, scope) {
    runMutation(root.scopeMutationFilter("delete"),
      { cid: contextId, scope: scope || "", a: label, b: "" }, false)
  }

  // Move the item labelled `sourceLabel` of the menu array at `scope` into a
  // submenu in the same scope: an existing one (targetLabel) or a freshly
  // created one (newLabel). Resolution by label (not position) makes the move
  // immune to stale panel snapshots — the service always operates on its
  // current config. One atomic write: the source is removed from the scope
  // and appended to the target submenu's items.
  function moveItemIntoSubmenu(contextId, scope, sourceLabel, targetLabel, newLabel) {
    runMutation(root.scopeMutationFilter("move"),
      { cid: contextId, scope: scope || "", a: JSON.stringify({ sourceLabel: sourceLabel || "", targetLabel: targetLabel || "", newLabel: newLabel || "" }), b: "" }, false)
    return "ok"
  }

  // Add a fully-formed item (label, icon, type + type-specific fields) to
  // the menu array at `scope` ("" = top level). itemJson is the complete
  // item object.
  function addItemObject(contextId, itemJson, scope) {
    if (!Model.contextExists(root.config, contextId)) { root.lastError = "unknown context: " + contextId; return "unknown" }
    runMutation(root.scopeMutationFilter("add"),
      { cid: contextId, scope: scope || "", a: itemJson, b: "" }, false)
    return "ok"
  }

  // Replace the menu array at `scope` ("" = top level) with a reordered
  // list of item objects (serialized as menuJson).
  function reorderItems(contextId, scope, menuJson) {
    if (!Model.contextExists(root.config, contextId)) { root.lastError = "unknown context: " + contextId; return "unknown" }
    runMutation(root.scopeMutationFilter("reorder"),
      { cid: contextId, scope: scope || "", a: menuJson, b: "" }, false)
    return "ok"
  }

  // Replace the item labelled `oldLabel` in the menu array at `scope` (""
  // = top level) with a fully-formed object.
  function updateItem(contextId, scope, oldLabel, itemJson) {
    runMutation(root.scopeMutationFilter("update"),
      { cid: contextId, scope: scope || "", a: oldLabel, b: itemJson }, false)
    return "ok"
  }

  // Regenerate the Hyprland keybindings from the current config and reload.
  // hyprctl reload is async: it returns before the compositor finishes
  // re-parsing, and a second reload fired in quick succession can be dropped,
  // leaving the regenerated binds unloaded. Verify the regenerated binding
  // actually landed in `hyprctl binds` and retry the reload until it does.
  function regenerateBindings() {
    var p = dispatchProc
    p.command = ["bash", "-lc",
      "B=\"$HOME/.config/hypr/context-bindings.lua\"\n" +
      "T=$(mktemp \"$B.XXXXXX\") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "omarchy-context-switcher-generate --bindings > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" \"$B\"\n" +
      "for i in $(seq 1 25); do\n" +
      "  hyprctl reload >/dev/null 2>&1\n" +
      "  sleep 0.1\n" +
      "  if hyprctl binds 2>/dev/null | grep -q 'omarchy-context-switcher menu'; then exit 0; fi\n" +
      "done\nexit 1"]
    p.running = true
  }

  // Regenerate the system-menu extension and tell the Menu plugin to reload
  // it, so the launcher reflects config edits (add/edit/delete items, renames,
  // shortcut/icon changes). Uses its own Process so it never collides with the
  // binding regeneration on dispatchProc.
  // Context baked into the last menu generation ("" = none yet). The menu
  // hides "Go to <ctx>" / "Move to <ctx>" for the context you are already
  // in, so it must be regenerated when the active context changes. Set at
  // call time so a context change during an in-flight generation triggers a
  // follow-up one (last write wins).
  property string menuContextId: ""
  // Set once the first-run init has run, to avoid bootstrap loops.
  property bool configBootstrapDone: false

  function regenerateMenu() {
    root.menuContextId = root.currentContextId
    var p = menuProc
    // Write atomically via an unpredictable temp: a failed generation (e.g. a
    // temporarily invalid config being hand-edited) must never truncate the
    // live extension out from under the launcher, and no fixed .tmp path can
    // be pre-planted as a symlink to redirect the write. Moved over only on
    // success.
    p.command = ["bash", "-lc",
      "EXT=\"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc\"\n" +
      "T=$(mktemp \"$EXT.XXXXXX\") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "omarchy-context-switcher-generate --menu --context " + Util.shellQuote(root.currentContextId) + " --merge \"$EXT\" > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" \"$EXT\" && " +
      "omarchy menu refresh >/dev/null 2>&1"]
    p.running = true
  }

  // Regenerate the launcher menu only when the active context changed.
  function maybeRegenerateMenu() {
    if (root.currentContextId !== root.menuContextId && root.configLoaded)
      root.regenerateMenu()
  }

  // Re-read config + state after an external edit (the "Edit Config" picker
  // action) and regenerate the launcher menu and keybindings so they reflect
  // it — the menu is also stale until the freshly loaded config propagates.
  function reloadConfig() {
    root.lastError = ""
    root.loadConfig()
    root.loadState()
    root.regenerateBindings()
    root.regenerateMenu()
    root.refreshCurrentContext()
    root.refreshRequested()
    return "ok"
  }

    Process {
    id: menuProc
  }

  // Rebuild the system-menu extension for the focused monitor's current context
  // (it hides "Go to <ctx>" / "Move to <ctx>" for that context), refresh the
  // launcher, then summon the picker or a specific context's submenu — all in
  // one bash chain so the freshly-written/refreshed menu is guaranteed present
  // before it is summoned. Triggered from the `menu` keybinding, so the menu
  // always reflects the monitor it is opened on; no regeneration on focus
  // changes (that would run/file-write continuously across monitors).
  function openMenu(contextId) {
    var target = contextId
      ? "contexts." + contextId
      : "contexts"
    summonProc.command = ["bash", "-lc",
      "EXT=\"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc\"\n" +
      "T=$(mktemp \"$EXT.XXXXXX\") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "omarchy-context-switcher-generate --menu --context " + Util.shellQuote(root.currentContextId) + " --merge \"$EXT\" > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" \"$EXT\" && " +
      "omarchy menu refresh >/dev/null 2>&1 && " +
      "omarchy menu summon " + target]
    summonProc.running = true
    return "ok"
  }

  Process {
    id: summonProc
  }

  // First-run config bootstrap: on success reload the config and regenerate
  // the bindings + menu that depend on it existing.
  Process {
    id: initProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0) {
        root.loadConfig()
        Qt.callLater(function() {
          root.regenerateBindings()
          root.regenerateMenu()
        })
      }
    }
  }

  // The bar layout (which workspace widget is shown) is enforced by Omarchy's
  // own bar tooling, which rewrites shell.json — so re-apply the invariant on
  // a short interval: the left section must end in exactly context-switcher
  // with no omarchy.workspaces, then tell the running shell to reload it.
  function enforceBarLayout() {
    barFixProc.command = ["bash", "-lc",
      "SJ=\"$HOME/.config/omarchy/shell.json\"\n" +
      "[[ -f \"$SJ\" ]] || exit 0\n" +
      "B=$(md5sum \"$SJ\" | cut -d' ' -f1)\n" +
      "T=$(mktemp \"$SJ.XXXXXX\") || exit 0\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "jq '(.bar.layout.left) = ([.bar.layout.left[]? | select(.id != \"omarchy.workspaces\" and .id != \"context-switcher\")] + [{\"id\": \"context-switcher\"}])' \"$SJ\" > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" \"$SJ\"\n" +
      "A=$(md5sum \"$SJ\" | cut -d' ' -f1)\n" +
      "if [[ \"$B\" != \"$A\" ]]; then omarchy-shell shell reloadConfig >/dev/null 2>&1 || true; fi"]
    barFixProc.running = true
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.configLoaded
    onTriggered: root.enforceBarLayout()
  }

  Process { id: barFixProc }

  // ---- Context popup (centered overlay) ----
  //
  // Hosted here (the service is keepLoaded) so the popup is a standalone,
  // screen-centered menu — not anchored to or rendered by the bar widget.
  // The bar widget only summons it; everything else lives here.
  property var popup: popupLoader.item

  function openPopup(contextId) {
    var p = root.popup
    if (!p) return "error"
    p.requestContext = contextId || ""
    p.open()
    return "ok"
  }
  function togglePopup() { if (root.popup) root.popup.toggle(); return "ok" }
  function closePopup() { if (root.popup) root.popup.close(); return "ok" }

  // Open the editor at a specific management view (used by the system menu's
  // management actions). view: editContextNew | editContext | editItem |
  // reorder. itemPath addresses the item relative to the context's menu:
  // "" (top level / add), "2", "2.1", "2.add" (add into scope "2").
  function openEditor(view, contextId, itemPath) {
    var p = root.popup
    if (!p) return "error"
    p.requestMode = view
    p.requestContext = contextId || ""
    p.requestItemPath = String(itemPath === undefined || itemPath === null ? "" : itemPath)
    p.open()
    return "ok"
  }

  Loader {
    id: popupLoader
    active: true
    source: Qt.resolvedUrl("ContextMenuPanel.qml")
    onLoaded: {
      popupLoader.item.service = root
    }
  }

  // ---- Setup / wiring ----

  Process {
    id: configProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyConfig(text)
    }
  }

  Process {
    id: stateProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }

  Process {
    id: stateWriter
  }

  Process {
    id: dispatchProc
  }

  // Owns the delete-context helper, which moves workspaces into a target
  // context and rewrites config + state in one detached pass. Reloads on
  // success so the popup/bar reflect the removal.
  Process {
    id: deleteProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0) {
        root.lastError = ""
        root.loadConfig()
        root.loadState()
        root.regenerateMenu()
      } else {
        root.lastError = "context delete failed"
      }
      root.refreshCurrentContext()
      root.refreshRequested()
      root.stateUpdated()
    }
  }

  // One-time startup seed of the authoritative monitor -> activeWorkspace map.
  // Runs exactly once; ongoing updates come from raw events (no polling).
  Process {
    id: seedProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySeed(text)
    }
  }

  function seedProbeCommand() {
    return ["bash", "-lc",
      "hyprctl monitors -j 2>/dev/null | jq -r '.[] | \"\\(.name)\\t\\(.activeWorkspace.id)\\t\\(.focused)\"'"]
  }

  function seedMonitors() {
    seedProbe.command = root.seedProbeCommand()
    seedProbe.running = true
  }

  function applySeed(raw) {
    var text = String(raw || "").trim()
    var map = {}
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var p = line.split("\t")
      if (p.length < 2) continue
      map[p[0]] = Number(p[1]) || 0
    }
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    root.monitorActiveWorkspace = map
    if (focused) root.focusedMonitorName = focused
    root.syncMonitors()
    root.stateUpdated()
  }

  // Event-driven monitor tracking driven by raw Hyprland events, which carry
  // authoritative per-monitor workspace data directly from the compositor
  // event stream — no hyprctl polling (blocking IPC) and no reliance on the
  // lagging Quickshell monitors model.
  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    var parts = []
    try { parts = (event && event.parse) ? event.parse(2) : [] } catch (e) { parts = [] }
    // focusedmon <monitor> <workspace>: focus moved to <workspace> on <monitor>.
    if (name === "focusedmon") {
      if (parts.length >= 2) root.setMonitorWorkspace(parts[0], Number(parts[1]) || 0, true)
    // workspace / moveworkspace <workspace> <monitor>: a workspace is now on a monitor.
    } else if (name === "workspace" || name === "moveworkspace") {
      if (parts.length >= 2) root.setMonitorWorkspace(parts[1], Number(parts[0]) || 0, false)
      // The source monitor's fallback workspace is not in the event, so do a
      // one-shot re-probe to refresh the full map. Event-triggered only (not
      // polling), so it does not stall interaction.
      if (!seedProbe.running) { seedProbe.command = root.seedProbeCommand(); seedProbe.running = true }
    }
  }

  // Update one monitor's active workspace from authoritative event data and
  // re-derive focus + context, bumping bars when anything changed.
  function setMonitorWorkspace(monitor, wsId, focused) {
    if (!monitor) return
    var map = Object.assign({}, root.monitorActiveWorkspace || {})
    map[monitor] = wsId
    if (focused) root.focusedMonitorName = monitor
    var mapChanged = JSON.stringify(map) !== JSON.stringify(root.monitorActiveWorkspace)
    root.monitorActiveWorkspace = map

    var activeWs = wsId
    if (focused) activeWs = wsId
    var derived = activeWs > 0 ? Model.contextForWorkspace(root.config, activeWs) : ""
    var changed = mapChanged
    if (derived) {
      if (derived !== root.currentContextId) changed = true
      root.currentContextId = derived
      var existing = (root.state.monitor_context || {})[root.focusedMonitorName]
      if (existing !== derived) {
        root.state = Model.setMonitorContext(root.state, root.focusedMonitorName, derived)
        root.persistState()
      }
    }
    if (changed) root.stateUpdated()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
    function onFocusedMonitorChanged() { root.syncMonitors() }
  }

  Component.onCompleted: {
    root.loadConfig()
    root.loadState()
    // Seed the authoritative monitor map once from hyprctl; events keep it
    // fresh afterwards (no polling).
    Qt.callLater(function() { root.seedMonitors() })
    // Set up the bar (hide omarchy.workspaces, show context-switcher). This
    // makes enabling via any path (install.sh or omarchy plugin enable) behave
    // identically. execDetached is a Quickshell singleton spawn that survives
    // teardown, matching the disable path.
    Quickshell.execDetached(["bash", "-lc", "omarchy-context-switcher-setup >/dev/null 2>&1"])
  }

  // On destruction (plugin disabled, or shell reload), run the teardown via a
  // static detached spawn. execDetached is a Quickshell singleton method (not a
  // child object), so it survives this component being torn down mid-disable —
  // a child Process would die with us before it could launch.
  //
  // The teardown self-guards: it only acts if the plugin was really disabled
  // (context-switcher gone from the bar layout), and exits immediately on a
  // mere shell reload (where the entry is still present).
  Component.onDestruction: {
    Quickshell.execDetached(["bash", "-lc", "omarchy-context-switcher-teardown >/dev/null 2>&1"])
  }

  IpcHandler {
    target: "context"

    // Note: "switch" is a reserved word in JS/QML, so the IPC method is
    // switchTo; the omarchy-context-switcher CLI maps `switch` -> `switchTo`.
    function switchTo(contextId: string): string { return root.switchContext(contextId) }
    function goto(slot: string): string { return root.gotoSlot(slot) }
    function move(slot: string): string { return root.moveWindow(slot, false) }
    function moveSilent(slot: string): string { return root.moveWindow(slot, true) }
    function moveWorkspace(contextId: string): string { return root.moveWorkspace(contextId) }
    function cycle(direction: string): string { return root.cycleWorkspace(direction) }
    function cycleMonitor(direction: string): string { return root.cycleMonitor(direction) }
    function next(): string { return root.nextContext() }
    function prev(): string { return root.prevContext() }
    function current(): string { return root.currentContextName() }
    function list(): string { return root.listContexts() }
    function validate(): string { return root.validateConfig() }
    function reloadConfig(): string { return root.reloadConfig() }
    function renameContext(id: string, name: string): string { root.renameContext(id, name); return "ok" }
    function setShortcut(id: string, shortcut: string): string { root.setContextShortcut(id, shortcut); return "ok" }
    function setIcon(id: string, icon: string): string { root.setContextIcon(id, icon); return "ok" }
    function setChromeProfile(id: string, profile: string): string { root.setContextChromeProfile(id, profile); return "ok" }
    function addContext(name: string, shortcut: string, icon: string, chromeProfile: string): string { return root.addContext(name, shortcut, icon, chromeProfile) }
    function deleteContext(id: string, targetId: string): string { return root.deleteContext(id, targetId) }
    function addItem(contextId: string, label: string, url: string, icon: string): string { return root.addItem(contextId, label, url, icon) }
    function renameItem(contextId: string, oldLabel: string, newLabel: string): string { root.renameItem(contextId, oldLabel, newLabel); return "ok" }
    function setItemIcon(contextId: string, label: string, icon: string): string { root.setItemIcon(contextId, label, icon); return "ok" }
    function deleteItem(contextId: string, label: string, scope: string): string { root.deleteItem(contextId, label, scope || ""); return "ok" }
    function addItemObject(contextId: string, itemJson: string, scope: string): string { return root.addItemObject(contextId, itemJson, scope || "") }
    function updateItem(contextId: string, scope: string, oldLabel: string, itemJson: string): string { root.updateItem(contextId, scope || "", oldLabel, itemJson); return "ok" }
    function reorderItems(contextId: string, scope: string, menuJson: string): string { return root.reorderItems(contextId, scope || "", menuJson) }
    function moveItem(contextId: string, scope: string, sourceLabel: string, targetLabel: string, newLabel: string): string { return root.moveItemIntoSubmenu(contextId, scope, sourceLabel, targetLabel, newLabel) }
    function menu(contextId: string): string { return root.openPopup(contextId) }
    function openMenu(contextId: string): string { return root.openMenu(contextId) }
    function popup(): string { return root.openPopup("") }
    function openPopup(contextId: string): string { return root.openPopup(contextId) }
    function togglePopup(): string { return root.togglePopup() }
    function closePopup(): string { return root.closePopup() }
    function edit(view: string, contextId: string, itemPath: string): string { return root.openEditor(view, contextId, itemPath) }
    function status(): string {
      return JSON.stringify({ configLoaded: root.configLoaded, stateLoaded: root.stateLoaded,
        focusedMonitor: root.focusedMonitorName, currentContext: root.currentContextId,
        contexts: (root.config.contexts || []).length, error: root.lastError })
    }
  }
}
