import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "ContextModel.js" as Model

// Context Switcher service.
//
// Owns per-monitor workspace-context state and implements the slot/context
// switching commands. Exposes them over IPC (target "context") so the
// omarchy-context CLI and keybindings can drive it, and keeps the bar-widget
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

  // Emitted when context state changes so the bar-widget can re-render.
  signal stateUpdated()
  // Ask the bar-widget to re-render (e.g. after a slot command).
  signal refreshRequested()

  // ---- Config / state loading (via Process + SplitParser) ----

  function loadConfig() {
    configProbe.command = ["bash", "-lc", "cat \"" + root.configFile + "\" 2>/dev/null || true"]
    configProbe.running = true
  }

  function loadState() {
    stateProbe.command = ["bash", "-lc", "cat \"" + root.stateFile + "\" 2>/dev/null || true"]
    stateProbe.running = true
  }

  function applyConfig(raw) {
    var text = String(raw || "").trim()
    if (!text) { root.lastError = "config not found: " + root.configFile; return }
    try {
      var parsed = JSON.parse(text)
      if (!parsed.contexts || !Array.isArray(parsed.contexts)) {
        root.lastError = "config has no contexts array"
        return
      }
      root.config = parsed
      root.configLoaded = true
      root.lastError = ""
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
    stateWriter.command = ["bash", "-lc",
      "mkdir -p \"" + root.stateDir + "\" && printf '%s' " + JSON.stringify(json) + " > \"" + root.stateFile + "\""]
    stateWriter.running = true
  }

  // ---- Current focused monitor + context ----

  function refreshFocusedMonitor() {
    var m = Hyprland.focusedMonitor
    var next = m ? String(m.name || "") : ""
    if (!next) next = "default"
    var changed = next !== root.focusedMonitorName
    root.focusedMonitorName = next
    root.currentContextId = Model.monitorContext(root.state, root.focusedMonitorName, root.defaultContextId)
    return changed
  }

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

  // Focus/switch to a workspace id.
  function focusWorkspace(wsId) {
    runEval('hl.dsp.focus({ workspace = "' + wsId + '" })')
  }

  // Move the active window to a workspace id (follow=false => silent).
  function moveWindowTo(wsId, silent) {
    runEval('hl.dsp.window.move({ workspace = "' + wsId + '", follow = ' + (silent ? "false" : "true") + ' })')
  }

  // Move a workspace id to a monitor by name.
  function moveWorkspaceToMonitor(wsId, monitor) {
    runEval('hl.dsp.workspace.move({ monitor = "' + monitor + '" })')
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
    root.refreshFocusedMonitor()
    var monitor = root.focusedMonitorName
    var last = root.state.last_workspace ? root.state.last_workspace[targetId] : 1
    if (last === undefined || last === null) last = 1
    var targetWs = Model.realWorkspaceId(root.config, targetId, last)

    root.focusWorkspace(targetWs)

    // The context belongs to whichever monitor actually ends up showing it.
    Qt.callLater(function() {
      root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
    var current = root.currentContextId
    var targetWs = Model.realWorkspaceId(root.config, current, slot)

    root.focusWorkspace(targetWs)
    Qt.callLater(function() {
      root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
    var current = root.currentContextId
    var targetWs = Model.realWorkspaceId(root.config, current, slot)
    var monitor = root.focusedMonitorName

    // Move the window to the slot workspace; keep it on the active monitor.
    root.moveWorkspaceToMonitor(targetWs, monitor)
    root.moveWindowTo(targetWs, silent)
    Qt.callLater(function() {
      root.refreshFocusedMonitor()
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
      p.command = ["bash", "-lc", "omarchy-context-move-workspace " + source + " " + targetWs]
      p.running = true
    }

    Qt.callLater(function() {
      root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
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
      root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
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
    root.refreshFocusedMonitor()
    root.refreshWorkspaces()
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

  // Hyprland.focusedMonitor populates asynchronously; a short poll guarantees
  // the focused monitor is detected even if the initial read happens before
  // Hyprland reports one.
  Timer {
    id: monitorPoll
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      var changed = root.refreshFocusedMonitor()
      if (changed) root.stateUpdated()
    }
  }

  // React to Hyprland raw events so external workspace/monitor changes (mouse
  // wheel, clicking another monitor) keep the context state and indicator in
  // sync without relying on signal-name guesses.
  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name === "focusedmon" || name === "workspace" || name === "createworkspace" || name === "destroyworkspace" || name === "moveworkspace") {
      root.refreshCurrentContext()
      root.stateUpdated()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  Component.onCompleted: {
    root.loadConfig()
    root.loadState()
    root.refreshCurrentContext()
  }

  IpcHandler {
    target: "context"

    // Note: "switch" is a reserved word in JS/QML, so the IPC method is
    // switchTo; the omarchy-context CLI maps `switch` -> `switchTo`.
    function switchTo(contextId: string): string { return root.switchContext(contextId) }
    function goto(slot: string): string { return root.gotoSlot(slot) }
    function move(slot: string): string { return root.moveWindow(slot, false) }
    function moveSilent(slot: string): string { return root.moveWindow(slot, true) }
    function moveWorkspace(contextId: string): string { return root.moveWorkspace(contextId) }
    function cycle(direction: string): string { return root.cycleWorkspace(direction) }
    function next(): string { return root.nextContext() }
    function prev(): string { return root.prevContext() }
    function current(): string { return root.currentContextName() }
    function list(): string { return root.listContexts() }
    function validate(): string { return root.validateConfig() }
    function status(): string {
      return JSON.stringify({ configLoaded: root.configLoaded, stateLoaded: root.stateLoaded,
        focusedMonitor: root.focusedMonitorName, currentContext: root.currentContextId,
        contexts: (root.config.contexts || []).length, error: root.lastError })
    }
  }
}
