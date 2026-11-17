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
  // Connector name -> stable hardware identity (Hyprland monitor description).
  property var monitorIdentities: ({})
  property string focusedMonitorIdentity: ""
  property bool migrationStarted: false
  property bool needsReconcile: false
  property bool startupReconciled: false

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
      Qt.callLater(function() { root.maybeMigrate() })
    } catch (e) {
      root.lastError = "config JSON parse failed: " + e
    }
  }

  function applyState(raw) {
    var text = String(raw || "").trim()
    var defaults = Model.defaultState()
    if (!text) {
      root.state = defaults
    } else {
      try {
        root.state = Object.assign({}, defaults, JSON.parse(text))
      } catch (e) {
        root.state = defaults
      }
    }
    root.stateLoaded = true
    root.cleanState()
    Qt.callLater(function() { root.maybeMigrate() })
  }

  // Drop synthetic monitor keys persisted by older versions (a transient
  // focused-monitor name, or Hyprland's synthetic FALLBACK output).
  function cleanState() {
    var mc = Object.assign({}, root.state.monitor_context || {})
    var fake = ["default", "FALLBACK", ""]
    var changed = false
    for (var i = 0; i < fake.length; i++) {
      if (mc[fake[i]] !== undefined) {
        delete mc[fake[i]]
        changed = true
      }
    }
    if (changed) {
      root.state = Object.assign({}, root.state, { monitor_context: mc })
      root.persistState()
    }
  }

  // Move connector-keyed contexts onto their stable hardware identity.
  function migrateMonitorContextKeys() {
    var mc = Object.assign({}, root.state.monitor_context || {})
    var changed = false
    for (var name in root.monitorIdentities) {
      var identity = root.monitorIdentities[name]
      if (identity && identity !== name && mc[name] !== undefined && mc[identity] === undefined) {
        mc[identity] = mc[name]
        delete mc[name]
        changed = true
      }
    }
    if (changed) {
      root.state = Object.assign({}, root.state, { monitor_context: mc })
      root.persistState()
    }
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

  // ---- Context blocks ----
  //
  // Each monitor has a permanent default Omarchy block (its fallback
  // workspace-manager). Each context is a virtual workspace-manager with its
  // own block from 100+, owned by exactly one monitor. The QML service owns
  // the map and writes blocks.lua for the Hyprland-side guard.

  function monitorIdentityOrder() {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    var list = []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (!m) continue
      var name = String(m.name || "")
      if (!name || name === "FALLBACK") continue
      list.push({ name: name, description: String(m.description || "") })
    }
    list.sort(function(a, b) {
      var ai = /^(eDP|LVDS|DSI)/.test(a.name) ? 0 : 1
      var bi = /^(eDP|LVDS|DSI)/.test(b.name) ? 0 : 1
      if (ai !== bi) return ai - bi
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
    })
    var seen = {}
    var out = []
    for (var j = 0; j < list.length; j++) {
      var base = list[j].description !== "" ? list[j].description : list[j].name
      var identity = base
      if (seen[identity]) identity = base + " #" + list[j].name
      seen[identity] = true
      out.push(identity)
    }
    return out
  }

  function monitorIdentityList() {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    var list = []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (!m) continue
      var name = String(m.name || "")
      if (!name || name === "FALLBACK") continue
      list.push({ name: name, description: String(m.description || "") })
    }
    list.sort(function(a, b) {
      var ai = /^(eDP|LVDS|DSI)/.test(a.name) ? 0 : 1
      var bi = /^(eDP|LVDS|DSI)/.test(b.name) ? 0 : 1
      if (ai !== bi) return ai - bi
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
    })
    var seen = {}
    var identities = {}
    for (var j = 0; j < list.length; j++) {
      var base = list[j].description !== "" ? list[j].description : list[j].name
      var identity = base
      if (seen[identity]) identity = base + " #" + list[j].name
      seen[identity] = true
      identities[list[j].name] = identity
    }
    return identities
  }

  function identityForMonitor(name) {
    var identities = root.monitorIdentityList()
    return identities[name] || root.monitorIdentities[name] || name
  }

  function connectedMonitorIdentities() {
    var identities = root.monitorIdentityList()
    var values = []
    for (var name in identities) {
      var identity = identities[name]
      if (values.indexOf(identity) === -1) values.push(identity)
    }
    return values
  }

  function firstMonitorIdentity() {
    var order = root.monitorIdentityOrder()
    return order.length > 0 ? order[0] : ""
  }

  function monitorNameForIdentity(identity) {
    var identities = root.monitorIdentityList()
    for (var name in identities) {
      if (identities[name] === identity) return name
    }
    return ""
  }

  function isMonitorConnected(identity) {
    return root.connectedMonitorIdentities().indexOf(identity) !== -1
  }

  function contextIds() {
    var contexts = root.config.contexts || []
    var ids = []
    for (var i = 0; i < contexts.length; i++) ids.push(contexts[i].id)
    return ids
  }

  function ownedContexts(identity) {
    var owners = root.state.context_monitor || {}
    var ids = root.contextIds()
    var out = []
    for (var i = 0; i < ids.length; i++) {
      if (owners[ids[i]] === identity) out.push(ids[i])
    }
    return out
  }

  function bumpGeneration() {
    root.state = Object.assign({}, root.state, {
      generation: (Number(root.state.generation) || 0) + 1
    })
  }

  function defaultBlockFor(identity) {
    return Model.defaultBlock(root.state, identity)
  }

  function contextBlockFor(contextId) {
    return Model.contextBlock(root.state, contextId)
  }

  function contextOwnerFor(contextId) {
    return Model.contextOwner(root.state, contextId)
  }

  function activeManagerFor(identity) {
    return Model.activeContext(root.state, identity) || "default"
  }

  function managerBlockFor(identity, manager) {
    return Model.managerBlock(root.state, identity, manager)
  }

  function workspaceIdForManager(identity, manager, slot) {
    return Model.workspaceIdForManager(root.state, identity, manager, root.config.slots || 10, slot)
  }

  function contextForWorkspaceId(wsId) {
    var slots = root.config.slots || 10
    var context = Model.contextForWorkspaceBlock(root.state, wsId, slots)
    if (context) return context
    return Model.contextForWorkspace(root.config, wsId)
  }

  function slotForWorkspaceId(wsId) {
    return ((wsId - 1) % (root.config.slots || 10)) + 1
  }

  function managerForWorkspace(identity, wsId) {
    return Model.managerForWorkspace(root.state, identity, wsId, root.config.slots || 10)
  }

  function findFirstEmptySlot(identity, manager) {
    var slots = root.config.slots || 10
    var block = root.managerBlockFor(identity, manager)
    if (block === undefined) return 0
    for (var slot = 1; slot <= slots; slot++) {
      if (!root.workspacesById[String(Model.workspaceIdForBlock(block, slots, slot))]) return slot
    }
    return 0
  }

  function ensureContextBlocks() {
    if (root.state.context_model !== 2) return false
    var next = Model.allocateContextBlocks(root.state, root.contextIds(), 100)
    var changed = (next !== root.state)
    if (changed) {
      root.state = next
      root.bumpGeneration()
      root.persistState()
      root.writeBlocks()
    }
    return changed
  }

  function ensureContextOwners() {
    if (root.state.context_model !== 2) return false
    var owners = Object.assign({}, root.state.context_monitor || {})
    var fallback = root.focusedMonitorIdentity || root.firstMonitorIdentity()
    if (!fallback) return false
    var changed = false
    var ids = root.contextIds()
    for (var i = 0; i < ids.length; i++) {
      if (!owners[ids[i]]) {
        owners[ids[i]] = fallback
        changed = true
      }
    }
    if (changed) {
      root.state = Object.assign({}, root.state, { context_monitor: owners })
      root.bumpGeneration()
      root.persistState()
      root.writeBlocks()
    }
    return changed
  }

  function loadDefaultBlocks() {
    defaultBlocksProbe.command = ["bash", "-lc",
      "F=\"$HOME/.local/state/omarchy/monitor-workspaces\"\n" +
      "[[ -f \"$F\" ]] && cat \"$F\" || true"]
    defaultBlocksProbe.running = true
  }

  function applyDefaultBlocks(raw) {
    var text = String(raw || "").trim()
    var blocks = {}
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var p = line.split("\t")
      if (p.length < 3) continue
      var block = Number(p[0])
      var identity = p[2]
      if (!isFinite(block) || !identity) continue
      blocks[identity] = block
    }
    if (Object.keys(blocks).length === 0) return
    if (JSON.stringify(blocks) === JSON.stringify(root.state.default_blocks || {})) return
    root.state = Object.assign({}, root.state, { default_blocks: blocks })
    root.persistState()
    root.writeBlocks()
    root.syncMonitors()
  }

  function luaString(value) {
    return JSON.stringify(String(value))
  }

  function blocksLua() {
    var slots = root.config.slots || 10
    var contextBlocks = root.state.context_blocks || {}
    var contextMonitor = root.state.context_monitor || {}
    var defaultBlocks = root.state.default_blocks || {}
    var active = root.state.monitor_context || {}
    var lines = [
      "return {",
      "  generation = " + (Number(root.state.generation) || 0) + ",",
      "  slots = " + slots + ",",
      "  context_blocks = {"
    ]
    for (var context in contextBlocks) {
      lines.push("    [" + root.luaString(context) + "] = " + Number(contextBlocks[context]) + ",")
    }
    lines.push("  },")
    lines.push("  context_monitor = {")
    for (var context in contextMonitor) {
      lines.push("    [" + root.luaString(context) + "] = " + root.luaString(contextMonitor[context]) + ",")
    }
    lines.push("  },")
    lines.push("  default_blocks = {")
    for (var identity in defaultBlocks) {
      lines.push("    [" + root.luaString(identity) + "] = " + Number(defaultBlocks[identity]) + ",")
    }
    lines.push("  },")
    lines.push("  active = {")
    for (var identity in active) {
      if (active[identity]) lines.push("    [" + root.luaString(identity) + "] = " + root.luaString(active[identity]) + ",")
    }
    lines.push("  },")
    lines.push("}")
    return lines.join("\n") + "\n"
  }

  function writeBlocks() {
    if (!root.stateLoaded) return
    var path = root.stateDir + "/blocks.lua"
    blocksWriter.command = ["bash", "-lc",
      "mkdir -p " + Util.shellQuote(root.stateDir) + "\n" +
      "T=$(mktemp " + Util.shellQuote(path + ".XXXXXX") + ") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "printf '%s' " + Util.shellQuote(root.blocksLua()) + " > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" " + Util.shellQuote(path)]
    blocksWriter.running = true
  }

  function reconcileWorkspaces(force) {
    var expr = force ? "o.workspaces.reconcile(\"force\")" : "o.workspaces.reconcile()"
    workspaceProc.command = ["bash", "-lc",
      "hyprctl eval '" + expr + "' >/dev/null 2>&1 || true"]
    workspaceProc.running = true
  }

  function setActiveManager(identity, manager) {
    if (!identity) return
    if (manager === "default") {
      var mc = Object.assign({}, root.state.monitor_context || {})
      delete mc[identity]
      root.state = Object.assign({}, root.state, { monitor_context: mc })
    } else {
      root.state = Model.setMonitorContext(root.state, identity, manager)
    }
  }

  // A monitor may only be active in a context it owns. Guests are allowed only
  // while the owner monitor is absent (hotplug); once the owner is connected,
  // drop the guest active manager so the monitor falls back to its own context
  // or its default manager.
  function sanitizeActiveManagers() {
    var mc = Object.assign({}, root.state.monitor_context || {})
    var connected = root.connectedMonitorIdentities()
    var changed = false
    for (var identity in mc) {
      var contextId = mc[identity]
      var owner = root.contextOwnerFor(contextId)
      if (owner && owner !== identity && connected.indexOf(owner) !== -1) {
        delete mc[identity]
        changed = true
      }
    }
    if (changed) {
      root.state = Object.assign({}, root.state, { monitor_context: mc })
      root.persistState()
      root.writeBlocks()
    }
  }

  // Keep every monitor's active manager in sync with the workspace it is
  // actually showing, not just the focused monitor.
  function syncAllMonitors() {
    var mc = Object.assign({}, root.state.monitor_context || {})
    var changed = false
    for (var name in root.monitorActiveWorkspace) {
      var identity = root.identityForMonitor(name)
      var wsId = Number(root.monitorActiveWorkspace[name]) || 0
      if (wsId <= 0) continue
      var info = root.managerForWorkspace(identity, wsId)
      if (!info) continue
      if (info.manager === "default") {
        if (mc[identity] !== undefined) {
          delete mc[identity]
          changed = true
        }
      } else {
        var owner = root.contextOwnerFor(info.manager)
        if (!owner || owner === identity || !root.isMonitorConnected(owner)) {
          if (mc[identity] !== info.manager) {
            mc[identity] = info.manager
            changed = true
          }
        }
      }
    }
    if (changed) {
      root.state = Object.assign({}, root.state, { monitor_context: mc })
      root.persistState()
      root.writeBlocks()
    }
  }

  function monitorHostingContext(contextId) {
    var block = root.contextBlockFor(contextId)
    if (block === undefined) return ""
    var slots = root.config.slots || 10
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws || !ws.monitor) continue
      var id = Number(ws.id)
      if (id > 0 && Math.floor((id - 1) / slots) === block) {
        return root.identityForMonitor(String(ws.monitor.name || ""))
      }
    }
    return ""
  }

  function moveContextWorkspacesToMonitor(contextId, identity) {
    var block = root.contextBlockFor(contextId)
    var name = root.monitorNameForIdentity(identity)
    if (block === undefined || !name) return
    var slots = root.config.slots || 10
    var cmd = ""
    for (var slot = 1; slot <= slots; slot++) {
      var ws = block * slots + slot
      cmd += "hyprctl eval 'hl.dispatch(hl.dsp.workspace.move({ workspace = \"" + ws + "\", monitor = \"" + name + "\" }))' >/dev/null 2>&1 || true\n"
    }
    var p = dispatchProc
    p.command = ["bash", "-lc", cmd]
    p.running = true
  }

  function monitorInDirection(direction) {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    var focusedName = root.focusedMonitorName
    var focused = null
    for (var i = 0; i < mons.length; i++) {
      if (String(mons[i].name || "") === focusedName) { focused = mons[i]; break }
    }
    if (!focused) return ""
    var fx = Number(focused.x) + Number(focused.width) / 2
    var fy = Number(focused.y) + Number(focused.height) / 2
    var best = null
    var bestDist = Infinity
    for (var j = 0; j < mons.length; j++) {
      var m = mons[j]
      if (!m || String(m.name || "") === focusedName) continue
      var cx = Number(m.x) + Number(m.width) / 2
      var cy = Number(m.y) + Number(m.height) / 2
      var dx = cx - fx
      var dy = cy - fy
      var ok = false
      var dist = 0
      if (direction === "left") { ok = dx < 0; dist = Math.abs(dx) }
      else if (direction === "right") { ok = dx > 0; dist = Math.abs(dx) }
      else if (direction === "up") { ok = dy < 0; dist = Math.abs(dy) }
      else if (direction === "down") { ok = dy > 0; dist = Math.abs(dy) }
      if (ok && dist < bestDist) { best = m; bestDist = dist }
    }
    return best ? String(best.name) : ""
  }

  function moveContext(direction) {
    root.syncMonitors()
    var sourceIdentity = root.focusedMonitorIdentity
    var contextId = root.activeManagerFor(sourceIdentity)
    if (contextId === "default") return "ok"

    var targetName = ""
    if (direction === "next" || direction === "prev") {
      var order = root.connectedMonitorIdentities()
      if (order.length <= 1) return "ok"
      var idx = order.indexOf(sourceIdentity)
      if (idx < 0) idx = 0
      var nextIdx = direction === "prev" ? (idx - 1 + order.length) % order.length : (idx + 1) % order.length
      targetName = root.monitorNameForIdentity(order[nextIdx])
    } else {
      targetName = root.monitorInDirection(direction)
    }
    if (!targetName) return "error"
    var targetIdentity = root.identityForMonitor(targetName)
    if (!targetIdentity || targetIdentity === sourceIdentity) return "ok"

    root.moveContextWorkspacesToMonitor(contextId, targetIdentity)

    var owners = Object.assign({}, root.state.context_monitor || {})
    owners[contextId] = targetIdentity
    var mc = Object.assign({}, root.state.monitor_context || {})
    mc[targetIdentity] = contextId
    delete mc[sourceIdentity]
    root.state = Object.assign({}, root.state, { context_monitor: owners, monitor_context: mc })
    root.bumpGeneration()

    var fallback = root.ownedContexts(sourceIdentity)[0] || ""
    if (fallback) root.state = Model.setMonitorContext(root.state, sourceIdentity, fallback)
    root.persistState()
    root.writeBlocks()

    var last = root.state.last_workspace ? root.state.last_workspace[contextId] : 1
    if (last === undefined || last === null) last = 1
    var targetWs = root.workspaceIdForManager(targetIdentity, contextId, last)
    var sourceHome = fallback
      ? root.workspaceIdForManager(sourceIdentity, fallback, 1)
      : root.workspaceIdForManager(sourceIdentity, "default", 1)
    var sourceName = root.monitorNameForIdentity(sourceIdentity)
    var cmd = ""
    if (sourceHome !== undefined && sourceName) {
      cmd += "hyprctl eval 'hl.dispatch(hl.dsp.focus({ monitor = \"" + sourceName + "\" }))'\n"
      cmd += "hyprctl eval 'hl.dispatch(hl.dsp.focus({ workspace = \"" + sourceHome + "\" }))'\n"
    }
    if (targetWs !== undefined) {
      cmd += "hyprctl eval 'hl.dispatch(hl.dsp.focus({ monitor = \"" + targetName + "\" }))'\n"
      cmd += "hyprctl eval 'hl.dispatch(hl.dsp.focus({ workspace = \"" + targetWs + "\" }))'\n"
    }
    var p = dispatchProc
    p.command = ["bash", "-lc", cmd]
    p.running = true

    Qt.callLater(function() {
      root.syncMonitors()
      root.state = Model.setMonitorContext(root.state, targetIdentity, contextId)
      root.persistState()
      root.writeBlocks()
      root.reconcileWorkspaces()
      root.stateUpdated()
    })
    return "ok"
  }

  function cycleContext(direction) {
    root.syncMonitors()
    var identity = root.focusedMonitorIdentity
    var owned = root.ownedContexts(identity)
    if (owned.length === 0) return "ok"
    var current = root.activeManagerFor(identity)
    var idx = owned.indexOf(current)
    if (idx < 0) {
      idx = direction === "prev" ? owned.length - 1 : 0
    } else {
      idx = direction === "prev" ? (idx - 1 + owned.length) % owned.length : (idx + 1) % owned.length
    }
    var target = owned[idx]
    root.setActiveManager(identity, target)
    root.persistState()
    root.writeBlocks()

    var last = root.state.last_workspace ? root.state.last_workspace[target] : 1
    if (last === undefined || last === null) last = 1
    var ws = root.workspaceIdForManager(identity, target, last)
    if (ws === undefined) return "error"
    root.focusWorkspace(ws)
    Qt.callLater(function() {
      root.syncMonitors()
      root.state = Model.setMonitorContext(root.state, identity, target)
      root.persistState()
      root.writeBlocks()
      root.stateUpdated()
    })
    return "ok"
  }

  function maybeMigrate() {
    if (root.migrationStarted) return
    if (!root.configLoaded || !root.stateLoaded) return
    if (root.state.context_model === 2) {
      root.ensureContextBlocks()
      root.ensureContextOwners()
      root.loadDefaultBlocks()
      root.writeBlocks()
      return
    }
    root.migrationStarted = true
    migrateProc.command = ["bash", "-lc", "omarchy-context-switcher-migrate"]
    migrateProc.running = true
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
    var focusedName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var nameChanged = focusedName !== root.focusedMonitorName
    if (focusedName) root.focusedMonitorName = focusedName

    var identity = root.identityForMonitor(root.focusedMonitorName)
    var identityChanged = identity !== root.focusedMonitorIdentity
    root.focusedMonitorIdentity = identity

    // Authoritative: the focused monitor's active workspace from the event/seed
    // map. This is what the bar highlights, so goto/switch must agree with it.
    var map = root.monitorActiveWorkspace || {}
    var activeWs = map[root.focusedMonitorName] ? Number(map[root.focusedMonitorName]) || 0 : 0
    if (!activeWs) {
      var fw = Hyprland.focusedWorkspace
      activeWs = fw ? Number(fw.id) || 0 : 0
    }

    var info = activeWs > 0 ? root.managerForWorkspace(identity, activeWs) : null
    if (info && info.manager !== "default") {
      var owner = root.contextOwnerFor(info.manager)
      if (owner && owner !== identity && root.isMonitorConnected(owner)) info = null
    }
    var changed = nameChanged || identityChanged

    if (info) {
      if (info.manager === "default") {
        if ((root.state.monitor_context || {})[identity] !== undefined) {
          var mc = Object.assign({}, root.state.monitor_context || {})
          delete mc[identity]
          root.state = Object.assign({}, root.state, { monitor_context: mc })
          root.persistState()
          root.writeBlocks()
          changed = true
        }
        if (root.currentContextId !== "") changed = true
        root.currentContextId = ""
      } else {
        if (info.manager !== root.currentContextId) changed = true
        root.currentContextId = info.manager
        var existing = (root.state.monitor_context || {})[identity]
        if (existing !== info.manager) {
          root.state = Model.setMonitorContext(root.state, identity, info.manager)
          root.persistState()
          root.writeBlocks()
          changed = true
        }
      }
    } else {
      var fallback = (root.state.monitor_context || {})[identity] || ""
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

  // Move the active workspace to the next/prev monitor. The guard adopts it
  // into that monitor's active manager (context or default), keeping its slot
  // when free and otherwise taking the first free slot.
  function cycleMonitor(direction) {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    if (mons.length <= 1) return "ok"
    var wsId = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : 0
    if (wsId <= 0) return "ok"

    var sorted = mons.slice().sort(function(a, b) { return Number(a.id) - Number(b.id) })
    var names = []
    for (var i = 0; i < sorted.length; i++) names.push(String(sorted[i].name))

    var idx = -1
    for (i = 0; i < sorted.length; i++) {
      var m = sorted[i]
      if (m.activeWorkspace && Number(m.activeWorkspace.id) === wsId) { idx = i; break }
    }
    if (idx < 0) {
      var focusedName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
      idx = names.indexOf(focusedName)
    }
    if (idx < 0) return "error"

    var nextIdx = direction === "prev" ? (idx - 1 + names.length) % names.length : (idx + 1) % names.length
    var target = names[nextIdx]
    var p = dispatchProc
    p.command = ["bash", "-lc",
      "hyprctl eval 'o.workspaces.move_workspace_to_monitor(\"" + target + "\")' >/dev/null 2>&1 || true"]
    p.running = true

    Qt.callLater(function() {
      root.syncMonitors()
      root.stateUpdated()
    })
    return "ok"
  }

  // Move the active workspace to the monitor in a spatial direction. This uses
  // the same target resolution and guard path as SUPER+backslash, rather than
  // Hyprland's own directional monitor lookup.
  function moveWorkspaceInDirection(direction) {
    root.syncMonitors()
    var targetName = root.monitorInDirection(direction)
    if (!targetName) return "error"
    var p = dispatchProc
    p.command = ["bash", "-lc",
      "hyprctl eval 'o.workspaces.move_workspace_to_monitor(\"" + targetName + "\")' >/dev/null 2>&1 || true"]
    p.running = true
    Qt.callLater(function() {
      root.syncMonitors()
      root.stateUpdated()
    })
    return "ok"
  }

  // ---- Commands (invoked from IPC) ----

  // Go to a context: focus the monitor that owns it and activate it there.
  function switchContext(targetId) {
    if (!Model.contextExists(root.config, targetId)) { root.lastError = "unknown context: " + targetId; return "unknown" }
    root.syncMonitors()
    var focusedIdentity = root.focusedMonitorIdentity
    var owner = root.contextOwnerFor(targetId)
    var targetIdentity = owner
    var adopt = false

    if (!owner || !root.isMonitorConnected(owner)) {
      var host = root.monitorHostingContext(targetId)
      targetIdentity = host || focusedIdentity
      adopt = true
    }
    if (!targetIdentity) { root.lastError = "no monitor for context " + targetId; return "error" }

    if (adopt) {
      var owners = Object.assign({}, root.state.context_monitor || {})
      owners[targetId] = targetIdentity
      root.state = Object.assign({}, root.state, { context_monitor: owners })
      root.bumpGeneration()
      root.moveContextWorkspacesToMonitor(targetId, targetIdentity)
    }

    var targetName = root.monitorNameForIdentity(targetIdentity)
    if (!targetName) { root.lastError = "monitor not found for " + targetIdentity; return "error" }

    var last = root.state.last_workspace ? root.state.last_workspace[targetId] : 1
    if (last === undefined || last === null) last = 1
    var targetWs = root.workspaceIdForManager(targetIdentity, targetId, last)
    if (targetWs === undefined) { root.lastError = "no block for context " + targetId; return "error" }

    var p = dispatchProc
    p.command = ["bash", "-lc",
      "hyprctl eval 'hl.dispatch(hl.dsp.focus({ monitor = \"" + targetName + "\" }))'\n" +
      "hyprctl eval 'hl.dispatch(hl.dsp.focus({ workspace = \"" + targetWs + "\" }))'"]
    p.running = true

    Qt.callLater(function() {
      root.syncMonitors()
      root.state = Model.setMonitorContext(root.state, targetIdentity, targetId)
      root.state = Model.setLastWorkspace(root.state, targetId, last)
      root.persistState()
      root.writeBlocks()
      root.reconcileWorkspaces()
      root.refreshCurrentContext()
      root.stateUpdated()
    })
    return "ok"
  }

  // Go to a slot in the focused monitor's active manager.
  function gotoSlot(slotStr) {
    var slot = Number(slotStr)
    if (!isFinite(slot) || slot < 1 || slot > (root.config.slots || 10)) { root.lastError = "invalid slot"; return "error" }
    root.syncMonitors()
    var identity = root.focusedMonitorIdentity
    var manager = root.activeManagerFor(identity)
    var targetWs = root.workspaceIdForManager(identity, manager, slot)
    if (targetWs === undefined) { root.lastError = "no block for " + manager; return "error" }

    root.focusWorkspace(targetWs)
    Qt.callLater(function() {
      root.syncMonitors()
      if (manager !== "default") {
        root.state = Model.setMonitorContext(root.state, identity, manager)
        root.state = Model.setLastWorkspace(root.state, manager, slot)
      }
      root.persistState()
      root.writeBlocks()
      root.refreshCurrentContext()
      root.stateUpdated()
    })
    return "ok"
  }

  // Move the active window to a slot in the active manager.
  function moveWindow(slotStr, silent) {
    var slot = Number(slotStr)
    if (!isFinite(slot) || slot < 1 || slot > (root.config.slots || 10)) { root.lastError = "invalid slot"; return "error" }
    root.syncMonitors()
    var identity = root.focusedMonitorIdentity
    var manager = root.activeManagerFor(identity)
    var targetWs = root.workspaceIdForManager(identity, manager, slot)
    if (targetWs === undefined) { root.lastError = "no block for " + manager; return "error" }
    var monitor = root.focusedMonitorName

    var moveWs = 'hl.dispatch(hl.dsp.workspace.move({ workspace = "' + targetWs + '", monitor = "' + monitor + '" }))'
    var moveWin = 'hl.dispatch(hl.dsp.window.move({ workspace = "' + targetWs + '", follow = ' + (silent ? "false" : "true") + ' }))'
    var p = dispatchProc
    p.command = ["bash", "-lc", "hyprctl eval '" + moveWs + "'; hyprctl eval '" + moveWin + "'"]
    p.running = true

    Qt.callLater(function() {
      root.syncMonitors()
      if (manager !== "default") {
        root.state = Model.setMonitorContext(root.state, identity, manager)
        root.state = Model.setLastWorkspace(root.state, manager, slot)
      }
      root.persistState()
      root.writeBlocks()
      root.stateUpdated()
    })
    return "ok"
  }

  // Move the active workspace's windows to the first empty slot of targetId.
  function moveWorkspace(targetId) {
    if (!Model.contextExists(root.config, targetId)) { root.lastError = "unknown context: " + targetId; return "unknown" }
    root.refreshWorkspaces()
    root.syncMonitors()
    var owner = root.contextOwnerFor(targetId)
    if (!owner || !root.isMonitorConnected(owner)) {
      owner = root.focusedMonitorIdentity
      var owners = Object.assign({}, root.state.context_monitor || {})
      owners[targetId] = owner
      root.state = Object.assign({}, root.state, { context_monitor: owners })
      root.bumpGeneration()
    }
    var targetName = root.monitorNameForIdentity(owner)
    var slot = root.findFirstEmptySlot(owner, targetId)
    if (slot === 0) { root.lastError = "context is full: " + targetId; return "full" }
    var targetWs = root.workspaceIdForManager(owner, targetId, slot)
    if (targetWs === undefined || !targetName) { root.lastError = "no block for context " + targetId; return "error" }

    var source = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
    if (source > 0 && source !== targetWs) {
      var p = dispatchProc
      p.command = ["bash", "-lc",
        "hyprctl eval 'hl.dispatch(hl.dsp.workspace.move({ workspace = \"" + targetWs + "\", monitor = \"" + targetName + "\" }))' >/dev/null 2>&1 || true\n" +
        "omarchy-context-switcher-move-workspace " + source + " " + targetWs]
      p.running = true
    }

    Qt.callLater(function() {
      root.syncMonitors()
      root.state = Model.setMonitorContext(root.state, owner, targetId)
      root.state = Model.setLastWorkspace(root.state, targetId, slot)
      root.persistState()
      root.writeBlocks()
      root.stateUpdated()
    })
    return "ok"
  }

  // Cycle slots within the focused monitor's active manager.
  function cycleWorkspace(direction) {
    root.syncMonitors()
    root.refreshWorkspaces()
    var identity = root.focusedMonitorIdentity
    var manager = root.activeManagerFor(identity)
    var slots = root.config.slots || 10
    var block = root.managerBlockFor(identity, manager)
    if (block === undefined) return "error"

    var currentWs = Hyprland.focusedWorkspace ? Number(Hyprland.focusedWorkspace.id) : 0
    var slot = 1
    if (currentWs > 0 && Math.floor((currentWs - 1) / slots) === block) {
      slot = Model.slotForBlock(currentWs, slots)
    }
    var targetSlot = direction === "prev" ? slot - 1 : slot + 1
    if (targetSlot < 1) targetSlot = slots
    if (targetSlot > slots) targetSlot = 1
    var targetWs = Model.workspaceIdForBlock(block, slots, targetSlot)

    root.focusWorkspace(targetWs)
    Qt.callLater(function() {
      root.syncMonitors()
      if (manager !== "default") {
        root.state = Model.setMonitorContext(root.state, identity, manager)
        root.state = Model.setLastWorkspace(root.state, manager, targetSlot)
      }
      root.persistState()
      root.writeBlocks()
      root.stateUpdated()
    })
    return "ok"
  }

  function nextContext() { return root.cycleContext("next") }
  function prevContext() { return root.cycleContext("prev") }

  function currentContextName() {
    root.syncMonitors()
    root.refreshWorkspaces()
    if (!root.currentContextId) return "Default"
    return Model.contextName(root.config, root.currentContextId)
  }

  function listContexts() {
    var out = []
    var contexts = root.config.contexts || []
    for (var i = 0; i < contexts.length; i++) {
      var c = contexts[i]
      var owner = root.contextOwnerFor(c.id)
      out.push(c.id + "\t" + (c.name || c.id) + "\t" + (c.shortcut || "") + "\t" + owner)
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
    var target = ""
    if (contextId) {
      if (!Model.contextExists(root.config, contextId)) {
        root.lastError = "unknown context: " + contextId
        return "unknown"
      }
      target = "contexts." + contextId
    } else {
      target = "contexts"
    }
    summonProc.command = ["bash", "-lc",
      "EXT=\"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc\"\n" +
      "T=$(mktemp \"$EXT.XXXXXX\") || exit 1\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "omarchy-context-switcher-generate --menu --context " + Util.shellQuote(root.currentContextId) + " --merge \"$EXT\" > \"$T\" && chmod 0644 \"$T\" && mv \"$T\" \"$EXT\" && " +
      "omarchy menu refresh >/dev/null 2>&1 && " +
      "omarchy menu summon " + Util.shellQuote(target)]
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
      "T=$(mktemp \"$SJ.XXXXXX\") || exit 0\n" +
      "trap 'rm -f \"$T\"' EXIT\n" +
      "jq '(.bar.layout.left) = ([.bar.layout.left[]? | select(.id != \"omarchy.workspaces\" and .id != \"context-switcher\")] + [{\"id\": \"context-switcher\"}])' \"$SJ\" > \"$T\"\n" +
      "if cmp -s \"$SJ\" \"$T\"; then rm -f \"$T\"; exit 0; fi\n" +
      "chmod 0644 \"$T\" && mv \"$T\" \"$SJ\"\n" +
      "omarchy-shell shell reloadConfig >/dev/null 2>&1 || true"]
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

  // Reads Omarchy's monitor -> default block assignment for the permanent
  // fallback workspace-managers.
  Process {
    id: defaultBlocksProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDefaultBlocks(text)
    }
  }

  Process {
    id: dispatchProc
  }

  // Writes ~/.local/state/context-switcher/blocks.lua for the Hyprland guard.
  Process { id: blocksWriter }

  // Runs the guard's reconcile/reload via hyprctl eval (no config reload).
  Process { id: workspaceProc }

  // One-time migration to context-owned virtual workspace-managers.
  Process {
    id: migrateProc
    onExited: function(exitCode, exitStatus) {
      root.migrationStarted = false
      if (exitCode === 0 && exitStatus === 0) {
        root.lastError = ""
        root.loadState()
        Qt.callLater(function() {
          root.seedMonitors()
          root.reconcileWorkspaces()
        })
      } else {
        root.lastError = "workspace migration failed"
      }
    }
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
        Qt.callLater(function() {
          root.writeBlocks()
          root.reconcileWorkspaces()
        })
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
      "hyprctl monitors -j 2>/dev/null | jq -r '.[] | \"\\(.name)\\t\\(.activeWorkspace.id)\\t\\(.focused)\\t\\(.description)\"'"]
  }

  function seedMonitors() {
    seedProbe.command = root.seedProbeCommand()
    seedProbe.running = true
  }

  function applySeed(raw) {
    var text = String(raw || "").trim()
    var map = {}
    var identities = {}
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var p = line.split("\t")
      if (p.length < 2) continue
      var name = p[0]
      if (!name || name === "FALLBACK") continue
      map[name] = Number(p[1]) || 0
      identities[name] = (p.length >= 4 && p[3]) ? p[3] : name
    }
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    root.monitorActiveWorkspace = map
    root.monitorIdentities = identities
    if (focused) root.focusedMonitorName = focused
    root.migrateMonitorContextKeys()
    if (root.state.context_model === 2) {
      var blocksChanged = root.ensureContextBlocks()
      var ownersChanged = root.ensureContextOwners()
      root.loadDefaultBlocks()
      root.sanitizeActiveManagers()
      root.writeBlocks()
      if (blocksChanged || ownersChanged) root.reconcileWorkspaces()
    }
    root.syncAllMonitors()
    root.syncMonitors()
    if (!root.startupReconciled && root.state.context_model === 2) {
      root.startupReconciled = true
      root.reconcileWorkspaces(true)
    } else if (root.needsReconcile) {
      root.needsReconcile = false
      root.reconcileWorkspaces(true)
    }
    root.stateUpdated()
    Qt.callLater(function() { root.maybeMigrate() })
  }

  // Debounce monitor/config events into a single re-probe. A hotplug emits a
  // burst of workspace/moveworkspace events; probing once after it settles
  // avoids persisting intermediate contexts.
  function scheduleSeed() {
    seedTimer.restart()
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
      if (name === "moveworkspace") root.needsReconcile = true
      // The source monitor's fallback workspace is not in the event, so do a
      // one-shot re-probe to refresh the full map. Event-triggered only (not
      // polling), so it does not stall interaction.
      if (!seedProbe.running) { seedProbe.command = root.seedProbeCommand(); seedProbe.running = true }
    } else if (name === "monitoradded" || name === "monitoraddedv2" ||
               name === "monitorremoved" || name === "monitorremovedv2" ||
               name === "configreloaded") {
      root.scheduleSeed()
    }
  }

  Timer {
    id: seedTimer
    interval: 400
    repeat: false
    onTriggered: root.seedMonitors()
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

    // Update the monitor that changed, not whichever monitor happens to be
    // focused. Otherwise a workspace move on the other monitor rewrites this
    // monitor's context.
    var identity = root.identityForMonitor(monitor)
    var info = wsId > 0 ? root.managerForWorkspace(identity, wsId) : null
    var changed = mapChanged

    if (info) {
      if (info.manager === "default") {
        var mc = Object.assign({}, root.state.monitor_context || {})
        if (mc[identity] !== undefined) {
          delete mc[identity]
          root.state = Object.assign({}, root.state, { monitor_context: mc })
          root.persistState()
          root.writeBlocks()
          changed = true
        }
      } else {
        var owner = root.contextOwnerFor(info.manager)
        // A guest context owned by a connected other monitor is not this
        // monitor's active manager.
        if (!owner || owner === identity || !root.isMonitorConnected(owner)) {
          var existing = (root.state.monitor_context || {})[identity]
          if (existing !== info.manager) {
            root.state = Model.setMonitorContext(root.state, identity, info.manager)
            root.persistState()
            root.writeBlocks()
            changed = true
          }
        }
      }
    }

    if (focused) {
      var manager = root.activeManagerFor(identity)
      var nextContext = manager === "default" ? "" : manager
      if (nextContext !== root.currentContextId) changed = true
      root.currentContextId = nextContext
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
    root.loadDefaultBlocks()
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
    function moveWorkspaceToMonitor(direction: string): string { return root.moveWorkspaceInDirection(direction) }
    function contextNext(): string { return root.nextContext() }
    function contextPrev(): string { return root.prevContext() }
    function moveContext(direction: string): string { return root.moveContext(direction) }
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
        focusedMonitor: root.focusedMonitorName, focusedMonitorIdentity: root.focusedMonitorIdentity,
        currentContext: root.currentContextId, activeManager: root.activeManagerFor(root.focusedMonitorIdentity),
        contexts: (root.config.contexts || []).length,
        contextModel: Number(root.state.context_model) || 0,
        migrated: !!root.state.migrated, generation: Number(root.state.generation) || 0,
        error: root.lastError })
    }
  }
}
