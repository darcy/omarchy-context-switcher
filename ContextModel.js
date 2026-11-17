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
  return {
    last_workspace: {},
    monitor_context: {},
    context_blocks: {},
    context_monitor: {},
    default_blocks: {},
    monitor_order: [],
    next_block: 100,
    manual: {},
    generation: 0,
    context_model: 0,
    migrated: false
  }
}

// Default Omarchy workspace-manager block for a monitor identity.
function defaultBlock(state, identity) {
  var blocks = (state && state.default_blocks) || {}
  return blocks[identity]
}

// A context's own block (a virtual workspace-manager).
function contextBlock(state, contextId) {
  var blocks = (state && state.context_blocks) || {}
  return blocks[contextId]
}

// The monitor that owns a context.
function contextOwner(state, contextId) {
  var owners = (state && state.context_monitor) || {}
  return owners[contextId] || ""
}

// The active context on a monitor, or "" when the default manager is active.
function activeContext(state, identity) {
  var active = (state && state.monitor_context) || {}
  return active[identity] || ""
}

// The block for a monitor's active manager (context id or "default").
function managerBlock(state, identity, manager) {
  if (!manager || manager === "default") return defaultBlock(state, identity)
  return contextBlock(state, manager)
}

function workspaceIdForManager(state, identity, manager, slots, slot) {
  var block = managerBlock(state, identity, manager)
  if (block === undefined) return undefined
  return block * slots + slot
}

// Resolve a workspace id to the manager block that owns it. Returns
// { manager, slot } or null when the id is not covered by a known block.
function managerForWorkspace(state, identity, wsId, slots) {
  var block = Math.floor((wsId - 1) / slots)
  var slot = ((wsId - 1) % slots) + 1
  var defaults = (state && state.default_blocks) || {}
  if (defaults[identity] === block) return { manager: "default", slot: slot }

  var contexts = (state && state.context_blocks) || {}
  for (var contextId in contexts) {
    if (contexts[contextId] === block) return { manager: contextId, slot: slot }
  }
  return null
}

// The context whose block contains a workspace id, or "".
function contextForWorkspaceBlock(state, wsId, slots) {
  var block = Math.floor((wsId - 1) / slots)
  var contexts = (state && state.context_blocks) || {}
  for (var contextId in contexts) {
    if (contexts[contextId] === block) return contextId
  }
  return ""
}

// Allocate one block per context, starting at `startBlock` (default 100).
// Existing blocks are never renumbered.
function allocateContextBlocks(state, contextIds, startBlock) {
  var next = Object.assign({}, state)
  var blocks = Object.assign({}, state.context_blocks || {})
  var nextBlock = Math.max(Number(startBlock) || 100, Number(state.next_block) || 0)
  var changed = false

  for (var i = 0; i < contextIds.length; i++) {
    var contextId = contextIds[i]
    if (blocks[contextId] === undefined) {
      blocks[contextId] = nextBlock++
      changed = true
    }
  }

  if (!changed) return state
  next.context_blocks = blocks
  next.next_block = nextBlock
  return next
}

// Per-monitor context blocks. Each physical monitor owns a block of `slots`
// workspace ids per context. The block map is keyed by monitor identity
// (Hyprland's monitor description, falling back to the connector name).
function blockFor(state, identity, context) {
  var blocks = (state && state.workspace_blocks) || {}
  var monitor = blocks[identity]
  if (!monitor) return undefined
  return monitor[context]
}

function workspaceIdForBlock(block, slots, slot) {
  return block * slots + slot
}

// Resolve a workspace id back to its monitor identity + context via the block
// map. Returns null when the id is not covered by a known block.
function blockOwnerForWorkspace(state, wsId, slots) {
  var blocks = (state && state.workspace_blocks) || {}
  var block = Math.floor((wsId - 1) / slots)
  for (var identity in blocks) {
    var contexts = blocks[identity]
    for (var context in contexts) {
      if (contexts[context] === block) return { identity: identity, context: context }
    }
  }
  return null
}

// Slot (1-based) of a workspace id within its block.
function slotForBlock(wsId, slots) {
  return ((wsId - 1) % slots) + 1
}

// Allocate a block for every (monitor identity, context) pair that does not
// have one yet. Existing blocks are never renumbered; new blocks append to
// next_block so adding a context or a monitor does not disturb live workspaces.
function allocateBlocks(state, identities, contexts) {
  var next = Object.assign({}, state)
  var blocks = Object.assign({}, state.workspace_blocks || {})
  var order = (state.monitor_order || []).slice()
  var nextBlock = Number(state.next_block) || 0
  var changed = false

  for (var i = 0; i < identities.length; i++) {
    var identity = identities[i]
    if (order.indexOf(identity) === -1) {
      order.push(identity)
      changed = true
    }
    if (!blocks[identity]) {
      blocks[identity] = {}
      changed = true
    }
    for (var j = 0; j < contexts.length; j++) {
      var context = contexts[j]
      if (blocks[identity][context] === undefined) {
        blocks[identity][context] = nextBlock++
        changed = true
      }
    }
  }

  if (!changed) return state
  next.workspace_blocks = blocks
  next.monitor_order = order
  next.next_block = nextBlock
  return next
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
    blockFor: blockFor,
    workspaceIdForBlock: workspaceIdForBlock,
    blockOwnerForWorkspace: blockOwnerForWorkspace,
    slotForBlock: slotForBlock,
    allocateBlocks: allocateBlocks,
    defaultBlock: defaultBlock,
    contextBlock: contextBlock,
    contextOwner: contextOwner,
    activeContext: activeContext,
    managerBlock: managerBlock,
    workspaceIdForManager: workspaceIdForManager,
    managerForWorkspace: managerForWorkspace,
    contextForWorkspaceBlock: contextForWorkspaceBlock,
    allocateContextBlocks: allocateContextBlocks,
    slugify: slugify,
    normalizeShortcut: normalizeShortcut
  }
}
