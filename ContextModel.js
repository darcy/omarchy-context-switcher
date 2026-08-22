// Pure helpers for the Context Switcher plugin.
// All functions are side-effect free; they operate on parsed config/state.
// Top-level functions are exposed to QML via `import "ContextModel.js" as Model`;
// the guarded module.exports keeps them unit-testable under node.

// Resolve a context's base workspace id from its index and slot count.
function contextBase(config, id) {
  var idx = contextIndex(config, id)
  var slots = config.slots || 10
  return idx * slots + 1
}

function contextIndex(config, id) {
  var contexts = config.contexts || []
  for (var i = 0; i < contexts.length; i++) {
    if (contexts[i].id === id) return i
  }
  return -1
}

function contextById(config, id) {
  var contexts = config.contexts || []
  for (var i = 0; i < contexts.length; i++) {
    if (contexts[i].id === id) return contexts[i]
  }
  return null
}

function contextName(config, id) {
  var c = contextById(config, id)
  return c ? (c.name || id) : id
}

function contextExists(config, id) {
  return contextIndex(config, id) !== -1
}

// Real Hyprland workspace id for a context + slot (1-based slot).
function realWorkspaceId(config, id, slot) {
  var base = contextBase(config, id)
  return base + slot - 1
}

// The context whose workspace range contains a given workspace id, or "".
function contextForWorkspace(config, wsId) {
  var slots = config.slots || 10
  var contexts = config.contexts || []
  for (var i = 0; i < contexts.length; i++) {
    var base = i * slots + 1
    if (wsId >= base && wsId < base + slots) return contexts[i].id
  }
  return ""
}

// First empty slot in a context (a workspace with no clients).
function findFirstEmptySlot(workspacesById, config, id) {
  var slots = config.slots || 10
  var base = contextBase(config, id)
  for (var s = 1; s <= slots; s++) {
    if (!workspacesById[base + s - 1]) return s
  }
  return 1
}

// Default state when none exists yet.
function defaultState() {
  return { last_workspace: {}, monitor_context: {} }
}

// Safe accessor for monitor context with a default.
function monitorContext(state, monitor, fallback) {
  var mc = state.monitor_context || {}
  return mc[monitor] || fallback
}

// Set a monitor's context, returning a new state object.
function setMonitorContext(state, monitor, context) {
  var mc = Object.assign({}, state.monitor_context || {})
  mc[monitor] = context
  return Object.assign({}, state, { monitor_context: mc })
}

// Set the last-used slot for a context, returning a new state object.
function setLastWorkspace(state, context, slot) {
  var lw = Object.assign({}, state.last_workspace || {})
  lw[context] = slot
  return Object.assign({}, state, { last_workspace: lw })
}

// The slot (1-based) within a context that a workspace id occupies.
function slotForWorkspace(config, wsId) {
  var id = contextForWorkspace(config, wsId)
  if (!id) return 0
  var base = contextBase(config, id)
  return wsId - base + 1
}

// Normalize a name into a kebab-case context id.
function slugify(value) {
  return String(value || "").trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "")
}

// A single uppercase letter shortcut, or "" if the input is empty/invalid.
function normalizeShortcut(value) {
  var s = String(value || "").trim().toUpperCase()
  return s ? s.charAt(0) : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    contextBase: contextBase,
    contextIndex: contextIndex,
    contextById: contextById,
    contextName: contextName,
    contextExists: contextExists,
    realWorkspaceId: realWorkspaceId,
    contextForWorkspace: contextForWorkspace,
    findFirstEmptySlot: findFirstEmptySlot,
    defaultState: defaultState,
    monitorContext: monitorContext,
    setMonitorContext: setMonitorContext,
    setLastWorkspace: setLastWorkspace,
    slotForWorkspace: slotForWorkspace,
    slugify: slugify,
    normalizeShortcut: normalizeShortcut
  }
}
