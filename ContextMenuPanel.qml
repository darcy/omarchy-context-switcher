import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ContextModel.js" as Model

// Context Switcher editor — the centered overlay used ONLY for management
// (add/edit/delete contexts and items). The launcher is the system menu, so
// this panel never shows a launch list; it hosts just the two forms:
//   editContext — add or edit a context (name, shortcut, icon; delete).
//   editItem    — add or edit an item (type, title, icon, type-specific fields).
//
// It is summoned by the system menu's management actions (Add context,
// Edit <ctx>, Modify items -> Edit <item> / Add item). Backing out returns to
// the system menu at the place you came from.
Panel {
  id: root
  moduleName: "context-switcher"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Jump target set by the service before open(). requestMode is one of
  // "editContextNew" | "editContext" | "editItem" | "reorder". requestItemPath
  // addresses an item relative to the context's menu: "add" (top-level add),
  // "2", "2.1" (nested submenu items), "2.add" (add inside submenu 2); for
  // requestMode "reorder" it is the scope path ("" = top level).
  property string requestContext: ""
  property string requestMode: ""
  property string requestItemPath: ""

  property string view: "editContext"
  property string contextId: ""
  property string itemPath: ""
  property string itemScope: ""
  property string reorderPath: ""
  property string managePath: ""
  property bool confirmOpen: false
  property var confirmAction: null
  property string confirmMessage: ""

  property bool editingAdd: false
  property bool itemAddMode: false
  property string oldItemLabel: ""
  property string itemType: "web"
  property string itemRemoteKind: "mosh"
  property string chromeProfile: ""
  property var chromeProfileOptions: []
  property var reorderOrder: []
  property int reorderSelected: 0
  // "Move to submenu" state (reorder view, m key). The move is resolved by
  // label, so no index tracking is needed.
  property string moveSourceLabel: ""
  // An item edit opened from the move/edit list (Enter); after save/cancel/
  // delete the panel returns to that list instead of the system menu.
  property bool editingFromReorder: false
  // Whether Shift is held while the move/edit list has keyboard focus — the
  // highlighted row then shows a move icon instead of the edit pencil.
  property bool shiftHeld: false
  property int moveSelected: 0
  property var moveTargets: []
  property bool moveNewMode: false

  property var service: null
  readonly property var config: (service && service.config) ? service.config : { contexts: [], slots: 10 }
  readonly property var contexts: config.contexts || []
  readonly property var currentContext: contextById(contextId)
  readonly property var currentContextMenu: (currentContext && currentContext.menu) || []

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(fg, 0.55)
  readonly property color acc: bar ? bar.urgent : Color.urgent
  readonly property string fam: bar ? bar.fontFamily : Style.font.family

  readonly property bool editingText: ctxNameField.activeFocus || ctxShortcutField.activeFocus ||
    ctxIconField.activeFocus || itemTitleField.activeFocus || itemIconField.activeFocus ||
    itemUrlField.activeFocus || itemHostField.activeFocus || itemCommandField.activeFocus || itemWorkdirField.activeFocus

  function contextById(id) {
    return Model.contextById(config, id)
  }

  // Available Chrome profiles, loaded on demand into chromeProfileDropdown.
  function loadProfiles() {
    profileProc.command = ["bash", "-lc", "omarchy-context-profiles 2>/dev/null"]
    profileProc.running = true
  }

  function applyProfiles(raw) {
    var opts = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var p = line.split("\t")
      var dir = p[0] || ""
      var name = p[1] || dir
      if (!dir) continue
      opts.push({ value: dir, label: name === dir ? name : name + " (" + dir + ")" })
    }
    root.chromeProfileOptions = opts
    ctxProfileDropdown.options = opts
    ctxProfileDropdown.value = root.chromeProfile
  }

  // Force active focus onto a field, retrying until it lands. The panel window
  // may still be mapping when a caller runs forceActiveFocus, which fails
  // silently and leaves the keyboard on the panel. Retrying each event-loop
  // turn covers the open() race.
  function focusField(target) {
    var n = 0
    function attempt() {
      n++
      if (n > 8) return
      if (!target) { keyCatcher.forceActiveFocus(); return }
      if (target.forceActiveFocus()) return
      Qt.callLater(attempt)
    }
    Qt.callLater(attempt)
  }

  function open() {
    if (root.requestMode === "editContextNew") root.startAddContext()
    else if (root.requestMode === "editContext") root.startEditContext(root.requestContext)
    else if (root.requestMode === "editItem") {
      var p = String(root.requestItemPath || "")
      if (p === "" || p === "add") root.startAddItem(root.requestContext, "")
      else if (p.indexOf(".add") === p.length - 4) root.startAddItem(root.requestContext, p.substring(0, p.length - 4))
      else root.startEditItem(root.requestContext, p)
    }
    else if (root.requestMode === "reorder") root.startReorder(root.requestContext, String(root.requestItemPath || ""))
    root.requestMode = ""
    root.requestContext = ""
    root.requestItemPath = ""
    root.controller.show()
    if (root.view === "editContext") root.focusField(ctxNameField)
    else if (root.view === "editItem") root.focusField(itemTitleField)
    else if (root.view === "manage") root.focusField(manageList)
    else root.focusField(reorderList)
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  Process {
    id: profileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProfiles(text)
    }
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Close the editor and hand control back to the system menu (the regular
  // launcher). route is the system-menu id to reopen; empty = Contexts picker.
  function returnToSystemMenu(route) {
    root.close()
    Qt.callLater(function() {
      Util.execDetached(route ? "omarchy menu summon " + route : "omarchy menu summon contexts")
    })
  }

  function goBack() {
    if (root.confirmOpen) { root.confirmOpen = false; return }
    if (root.view === "reorderMove") { root.cancelMoveToSubmenu(); return }
    if (root.view === "reorder") { root.commitReorder(); return }
    if (root.view === "manage") { root.startEditItem(root.contextId, root.managePath); return }
    if (root.view === "editItem") {
      if (root.editingFromReorder) root.returnToReorder("cancel")
      else root.returnToSystemMenu("contexts." + root.contextId + ".menu")
    }
    else if (root.view === "editContext" && root.editingFromReorder) root.returnToReorder("cancel")
    else root.returnToSystemMenu(root.editingAdd ? "" : "contexts." + root.contextId)
  }

  function cancelEdit() { root.goBack() }

  function startAddContext() {
    root.editingAdd = true; root.contextId = ""
    ctxNameField.text = ""; ctxShortcutField.text = ""; ctxIconField.text = ""
    root.chromeProfile = (config.default_chrome_profile || "Default")
    root.loadProfiles()
    root.view = "editContext"
    root.focusField(ctxNameField)
  }

  function startEditContext(id) {
    var c = root.contextById(id)
    if (!c) return
    root.editingAdd = false; root.contextId = id
    ctxNameField.text = c.name || ""; ctxShortcutField.text = c.shortcut || ""; ctxIconField.text = c.icon || ""
    root.chromeProfile = (c.chrome_profile || config.default_chrome_profile || "Default")
    root.loadProfiles()
    root.view = "editContext"
    root.focusField(ctxNameField)
  }

  // Store the chosen profile; "" when it equals the default, so the context
  // explicitly uses the default (and gets no dedicated Browser item).
  function effectiveProfile() {
    var dflt = (config.default_chrome_profile || "Default")
    return root.chromeProfile === dflt ? "" : root.chromeProfile
  }

  function applyContextSave() {
    var name = ctxNameField.text.trim()
    if (!name) return
    var profile = root.effectiveProfile()
    if (root.editingAdd) {
      if (service) service.addContext(name, ctxShortcutField.text, ctxIconField.text, profile)
    } else if (service) {
      service.renameContext(root.contextId, name)
      service.setContextShortcut(root.contextId, ctxShortcutField.text)
      service.setContextIcon(root.contextId, ctxIconField.text)
      service.setContextChromeProfile(root.contextId, profile)
    }
    if (root.editingFromReorder) root.returnToReorder("cancel")
    else root.close()
  }

  function requestDeleteContext() {
    var c = root.currentContext
    if (!c) return
    var target = ""
    for (var i = 0; i < contexts.length; i++) {
      if (contexts[i].id !== c.id) { target = contexts[i].id; break }
    }
    var msg = "Delete \u201c" + (c.name || c.id) + "\u201d?"
    msg += target
      ? "\nIts windows will be moved to \u201c" + root.contextById(target).name + "\u201d."
      : "\nIt is the only context; its windows will be consolidated."
    root.confirmMessage = msg
    root.confirmAction = function() {
      if (service) service.deleteContext(c.id, target)
      root.close()
    }
    root.confirmOpen = true
    Qt.callLater(function() { confirmGrab.forceActiveFocus() })
  }

  // ---- Scope / path helpers ----
  // Items are addressed by dot-joined indices from the context's menu root:
  // "" (top level), "2", "2.1" (an item of submenu 2), "2.1.0", … A scope is
  // the array an operation targets: "" = the top-level menu, "2" = the items
  // of submenu 2.

  // The item array at a scope path ("" = the context's top-level menu).
  function menuItemsAt(scope) {
    var arr = root.currentContextMenu
    var s = String(scope || "")
    if (!s) return arr
    var idx = s.split(".")
    for (var i = 0; i < idx.length; i++) {
      if (!Array.isArray(arr)) return []
      var it = arr[Number(idx[i])]
      if (!it) return []
      arr = it.items || []
    }
    return arr
  }

  // The item object at a (non-empty) dot path, or null.
  function itemAtPath(path) {
    var s = String(path || "")
    if (!s) return null
    var arr = root.currentContextMenu
    var idx = s.split(".")
    for (var i = 0; i < idx.length; i++) {
      if (!Array.isArray(arr)) return null
      var it = arr[Number(idx[i])]
      if (!it) return null
      if (i === idx.length - 1) return it
      arr = it.items || []
    }
    return null
  }

  // The parent scope of a leaf item path ("2.1" -> "2", "2" -> "").
  function pathScope(path) {
    var s = String(path || "")
    var i = s.lastIndexOf(".")
    return i < 0 ? "" : s.substring(0, i)
  }

  // Populate the item form from an item object (shared by edit + manage-back).
  function fillItemForm(item) {
    root.oldItemLabel = item.label || ""
    var t = item.type || (item.url ? "web" : item.host ? "mosh" : item.command ? "script" : "web")
    if (t === "mosh" || t === "ssh") { root.itemType = "remote"; root.itemRemoteKind = t }
    else root.itemType = t
    itemTitleField.text = item.label || ""; itemIconField.text = item.icon || ""
    itemUrlField.text = item.url || ""; itemHostField.text = item.host || ""
    itemCommandField.text = item.command || ""; itemWorkdirField.text = item.workdir || ""
  }

  function startAddItem(cid, scope) {
    var c = root.contextById(cid)
    if (!c) return
    root.itemAddMode = true; root.contextId = cid; root.itemScope = String(scope || ""); root.oldItemLabel = ""
    root.itemType = "web"; root.itemRemoteKind = "mosh"
    var arr = root.menuItemsAt(root.itemScope)
    if (!Array.isArray(arr)) arr = []
    root.itemPath = root.itemScope ? root.itemScope + "." + arr.length : String(arr.length)
    itemTitleField.text = ""; itemIconField.text = ""
    itemUrlField.text = ""; itemHostField.text = ""; itemCommandField.text = ""; itemWorkdirField.text = ""
    root.view = "editItem"
    root.focusField(itemTitleField)
  }

  function startEditItem(cid, path) {
    if (!root.contextById(cid)) return
    root.contextId = cid // must precede itemAtPath: helpers resolve via contextId
    var item = root.itemAtPath(path)
    if (!item) return
    root.itemAddMode = false; root.itemPath = String(path || "")
    root.fillItemForm(item)
    root.view = "editItem"
    root.focusField(itemTitleField)
  }

  // Activate the highlighted row: rows 0/1 are the list's action entries
  // (Edit details / Add item), the rest open the item's edit form.
  function editReorderSelection() {
    if (root.reorderSelected === 0) { root.editDetailsFromReorder(); return }
    if (root.reorderSelected === 1) { root.addItemFromReorder(); return }
    var itemSel = root.reorderSelected - root.reorderDisplayOffset
    if (itemSel < 0 || itemSel >= root.reorderOrder.length) return
    var path = root.reorderPath ? root.reorderPath + "." + itemSel : String(itemSel)
    root.editingFromReorder = true
    root.startEditItem(root.contextId, path)
  }

  // "Edit details" from the move/edit list: the context's details, or the
  // submenu item's details when editing a nested scope.
  function editDetailsFromReorder() {
    root.editingFromReorder = true
    if (root.reorderPath) root.startEditItem(root.contextId, root.reorderPath)
    else root.startEditContext(root.contextId)
  }

  // "Add item" from the move/edit list: add into the current scope, then
  // return to the list (mirroring the append) after saving.
  function addItemFromReorder() {
    root.editingFromReorder = true
    root.startAddItem(root.contextId, root.reorderPath)
  }

  // After saving/cancelling/deleting an item opened from the move/edit list,
  // return to that list and mirror the change locally (the async config
  // reload is not awaited — same label-based approach as moves).
  function returnToReorder(kind, oldLabel, newObj) {
    root.editingFromReorder = false
    root.shiftHeld = false
    if (kind === "add") {
      root.reorderOrder = root.reorderOrder.slice().concat([newObj])
    } else if (kind === "edit" && oldLabel) {
      var arr = root.reorderOrder.slice()
      for (var i = 0; i < arr.length; i++) {
        if (arr[i].label === oldLabel) { arr[i] = newObj; break }
      }
      root.reorderOrder = arr
    } else if (kind === "delete" && oldLabel) {
      root.reorderOrder = root.reorderOrder.filter(function(x) { return x.label !== oldLabel })
    }
    root.clampReorderSelection()
    root.view = "reorder"
    Qt.callLater(function() { root.focusField(reorderList) })
  }

  // Assemble the item object from the current form fields + selected type.
  // The Remote selector maps to the JSON types mosh/ssh via itemRemoteKind;
  // submenu items keep their existing children when edited.
  function buildItemObject() {
    var o = { label: itemTitleField.text.trim(), icon: itemIconField.text.trim() }
    var t = root.itemType
    o.type = (t === "remote") ? root.itemRemoteKind : t
    if (t === "web") o.url = itemUrlField.text.trim()
    else if (t === "remote") {
      o.host = itemHostField.text.trim()
      if (itemCommandField.text.trim()) o.command = itemCommandField.text.trim()
      if (itemWorkdirField.text.trim()) o.workdir = itemWorkdirField.text.trim()
    } else if (t === "terminal" || t === "script") {
      o.command = itemCommandField.text.trim()
    } else if (t === "submenu") {
      var existing = root.itemAddMode ? null : root.itemAtPath(root.itemPath)
      o.items = (existing && existing.items) ? existing.items : []
    }
    return o
  }

  // First type-specific field for the current item type (Enter target).
  function firstTypeField() {
    if (root.itemType === "web") return itemUrlField
    if (root.itemType === "remote") return itemHostField
    if (root.itemType === "terminal" || root.itemType === "script") return itemCommandField
    return itemIconField // submenu: title -> icon, icon Enter saves
  }

  function applyItemSave() {
    var o = root.buildItemObject()
    if (!o.label) return
    var backToReorder = root.editingFromReorder
    if (root.itemAddMode) {
      if (service) service.addItemObject(root.contextId, JSON.stringify(o), root.itemScope)
    } else if (service) {
      service.updateItem(root.contextId, root.itemPath, root.oldItemLabel, JSON.stringify(o))
    }
    if (backToReorder) root.returnToReorder(root.itemAddMode ? "add" : "edit", root.oldItemLabel, o)
    else root.close()
  }

  function requestDeleteItem() {
    var item = root.itemAtPath(root.itemPath)
    if (!item) return
    var label = root.oldItemLabel || item.label
    var cname = (root.currentContext && root.currentContext.name) || root.contextId
    var scope = root.pathScope(root.itemPath)
    root.confirmMessage = "Delete item \u201c" + label + "\u201d from \u201c" + cname + "\u201d?"
    root.confirmAction = function() {
      if (service) service.deleteItem(root.contextId, label, scope)
      if (root.editingFromReorder) root.returnToReorder("delete", label)
      else root.close()
    }
    root.confirmOpen = true
    Qt.callLater(function() { confirmGrab.forceActiveFocus() })
  }

  // Open the manage view for an existing submenu: add items, reorder, and
  // edit individual children, mirroring the context's own edit menu.
  function startManage(path) {
    var item = root.itemAtPath(path)
    if (!item) return
    root.managePath = String(path || "")
    root.view = "manage"
    root.focusField(manageList)
  }

  // ---- Reorder items ----

  function startReorder(cid, scope) {
    var c = root.contextById(cid)
    if (!c) return
    root.contextId = cid // must precede menuItemsAt: helpers resolve via contextId
    root.reorderPath = String(scope || "")
    var arr = root.menuItemsAt(root.reorderPath)
    if (!Array.isArray(arr)) return
    root.reorderOrder = arr.slice()
    root.reorderSelected = 0
    root.shiftHeld = false
    root.view = "reorder"
    root.focusField(reorderList)
  }

  // Icon for a row in the move/edit list: the highlighted row shows a pencil
  // (Enter edits it) or, while Shift is held (Shift+↑/↓ reorder), a move
  // icon; all other rows keep their own icon.
  // Display-index space: 0/1 = actions, 2 = separator, 3 = hint, 4+ = items.
  // The cursor only ever lands on interactive rows (actions + items), so
  // selection steps map through the compact interactive space.
  function reorderIndexToInteractive(d) {
    return d < root.reorderDisplayOffset ? d : d - 2
  }
  function reorderInteractiveToDisplay(i) {
    return i < root.reorderActionCount ? i : i + 2
  }
  function clampReorderSelection() {
    var cur = root.reorderIndexToInteractive(root.reorderSelected)
    var maxI = root.reorderOrder.length + root.reorderActionCount - 1
    if (cur < 0) cur = 0
    if (cur > maxI) cur = maxI
    root.reorderSelected = root.reorderInteractiveToDisplay(cur)
  }

  // Icon for a row in the move/edit list: rows 0/1 are the list's actions
  // (Edit details / Add item); the highlighted item row shows a pencil
  // (Enter edits it) or, while Shift is held (Shift+↑/↓ reorder), a move
  // icon; other item rows keep their own icon.
  function reorderIconFor(index) {
    if (index === 0) return "\uf044"
    if (index === 1) return "\uf067"
    if (index < root.reorderDisplayOffset) return "" // separator / hint rows
    if (index !== root.reorderSelected) {
      var it = root.reorderOrder[index - root.reorderDisplayOffset]
      return (it && it.icon) || ""
    }
    return root.shiftHeld ? "\uf0dc" : "\uf044"
  }

  function selectReorder(dy) {
    var n = root.reorderOrder.length + root.reorderActionCount
    if (n <= 0) return
    var cur = root.reorderIndexToInteractive(root.reorderSelected)
    cur = (cur + dy + n) % n
    root.reorderSelected = root.reorderInteractiveToDisplay(cur)
    reorderList.positionViewAtIndex(root.reorderSelected, ListView.Contain)
  }

  function moveReorder(dy) {
    var from = root.reorderSelected
    var to = from + dy
    // Item rows only (action/separator/hint rows are not reorderable).
    if (from < root.reorderDisplayOffset || to < root.reorderDisplayOffset || to > root.reorderOrder.length + root.reorderDisplayOffset - 1) return
    var arr = root.reorderOrder.slice()
    var it = arr.splice(from - root.reorderDisplayOffset, 1)[0]
    arr.splice(to - root.reorderDisplayOffset, 0, it)
    root.reorderOrder = arr
    root.reorderSelected = to
    reorderList.positionViewAtIndex(to, ListView.Contain)
  }

  // Commit the reordered list to the config, then close the editor entirely.
  function commitReorder() {
    if (service && root.reorderOrder.length)
      service.reorderItems(root.contextId, root.reorderPath, JSON.stringify(root.reorderOrder))
    root.close()
  }

  // ---- Move an item into a submenu (reorder view, m key) ----

  // Enter the target chooser for the highlighted reorder item. Targets are
  // the submenus in the current scope (minus the item itself) plus a "New
  // submenu" entry; moving creates the submenu when requested.
  function startMoveToSubmenu() {
    var itemSel = root.reorderSelected - root.reorderActionCount
    if (root.reorderOrder.length === 0 || itemSel < 0 || itemSel >= root.reorderOrder.length) return
    var it = root.reorderOrder[itemSel]
    root.moveSourceLabel = it.label || "(untitled)"
    var targets = []
    for (var i = 0; i < root.reorderOrder.length; i++) {
      var m = root.reorderOrder[i]
      if (m && m.label === it.label) continue // exclude the item being moved
      if (m && m.type === "submenu") targets.push({ kind: "submenu", label: m.label || "(untitled)" })
    }
    targets.push({ kind: "new", label: "New submenu\u2026" })
    root.moveTargets = targets
    root.moveSelected = 0
    root.moveNewMode = false
    root.view = "reorderMove"
    Qt.callLater(function() { root.focusField(reorderMoveList) })
  }

  // Abort the move and return to the reorder list (item stays put).
  function cancelMoveToSubmenu() {
    root.moveTargets = []
    root.moveNewMode = false
    root.shiftHeld = false
    root.view = "reorder"
    Qt.callLater(function() { root.focusField(reorderList) })
  }

  function selectMoveTarget(dy) {
    if (root.moveTargets.length === 0) return
    var n = root.moveTargets.length
    root.moveSelected = (root.moveSelected + dy + n) % n
    reorderMoveList.positionViewAtIndex(root.moveSelected, ListView.Contain)
  }

  // Confirm the highlighted target. "New submenu\u2026" reveals the name
  // field; a submenu target moves immediately.
  function executeMoveTarget() {
    var t = root.moveTargets[root.moveSelected]
    if (!t) return
    if (t.kind === "new") {
      root.moveNewMode = true
      Qt.callLater(function() { root.focusField(moveNewField) })
      return
    }
    if (service) service.moveItemIntoSubmenu(root.contextId, root.reorderPath, root.moveSourceLabel, t.label, "")
    root.applyMoveLocally(t)
  }

  // Create a new submenu (named from the move form) and move the item into it.
  function executeNewSubmenuMove(name) {
    var n = (name || "").trim()
    if (!n) return
    if (service) service.moveItemIntoSubmenu(root.contextId, root.reorderPath, root.moveSourceLabel, "", n)
    root.applyMoveLocally({ kind: "new", label: n })
  }

  // Mirror the mutation in the local reorder snapshot so the list updates
  // immediately and a quick "Done" cannot overwrite the moved state. No
  // re-sync from the (async-reloaded) config happens here: the mirror is
  // label-based and semantically identical to the mutation, and re-slicing
  // would clobber uncommitted drag-reorders the user hasn't committed yet.
  function applyMoveLocally(t) {
    var arr = root.reorderOrder.slice()
    var idx = -1
    for (var i = 0; i < arr.length; i++) if (arr[i].label === root.moveSourceLabel) { idx = i; break }
    if (idx < 0) return
    var it = arr.splice(idx, 1)[0]
    if (t.kind === "new") {
      arr.push({ label: t.label, icon: "", type: "submenu", items: [it] })
    } else {
      for (var j = 0; j < arr.length; j++) {
        if (arr[j].type === "submenu" && arr[j].label === t.label) {
          arr[j] = Object.assign({}, arr[j], { items: (arr[j].items || []).concat([it]) })
          break
        }
      }
    }
    root.reorderOrder = arr
    root.reorderSelected = arr.length ? root.reorderInteractiveToDisplay(Math.min(idx + root.reorderActionCount, arr.length + root.reorderActionCount - 1)) : 0
    root.moveTargets = []
    root.moveNewMode = false
    root.shiftHeld = false
    root.view = "reorder"
    Qt.callLater(function() { root.focusField(reorderList) })
  }

  readonly property int headerHeight: Style.space(40)
  readonly property color selectedBg: Util.alpha(fg, 0.10)
  readonly property int pad: Style.spacing.popupPadding
  readonly property int cardWidth: Math.min(panel.width - Style.gapsOut * 2, Style.space(380))
  readonly property int reorderRowHeight: Math.max(Style.space(40), Math.round(Style.font.body * 1.6))
  readonly property int reorderMaxHeight: Math.round((panel.height - Style.gapsOut * 2) * 0.6)
  // The two action rows (Edit details / Add item) lead the list, then a
  // separator and the hint line, then the items. Selection skips the
  // separator/hint rows via reorderIndexToInteractive.
  readonly property int reorderActionCount: 2
  readonly property int reorderDisplayOffset: 4
  readonly property var reorderDisplayModel: {
    var out = []
    out.push({ kind: "action", action: "details", icon: "\uf044", label: "Edit details" })
    out.push({ kind: "action", action: "add", icon: "\uf067", label: "Add item" })
    out.push({ kind: "separator" })
    out.push({ kind: "hint", label: "Shift+\u2191/\u2193 reorder  \u00b7  m move to submenu  \u00b7  Enter edit" })
    for (var i = 0; i < root.reorderOrder.length; i++) out.push(root.reorderOrder[i])
    return out
  }
  readonly property int reorderListHeight: Math.min(
    root.reorderActionCount * (root.reorderRowHeight + Style.spacing.xs)
      + Style.space(16) + Style.spacing.xs
      + Math.max(Style.space(24), Math.round(Style.font.caption * 1.3)) + Style.spacing.xs
      + root.reorderOrder.length * (root.reorderRowHeight + Style.spacing.xs),
    root.reorderMaxHeight)
  readonly property int reorderMoveListHeight: Math.min(root.moveTargets.length * (root.reorderRowHeight + Style.spacing.xs), root.reorderMaxHeight)
  readonly property int reorderMoveExtra: root.moveNewMode ? (Style.space(64)) : 0
  readonly property int reorderMoveColumnHeight: root.reorderMoveListHeight + root.reorderMoveExtra
  readonly property int contentH: root.view === "reorder"
    ? (root.headerHeight + reorderColumn.implicitHeight)
    : (root.view === "reorderMove"
      ? (root.headerHeight + root.reorderMoveColumnHeight)
      : (root.view === "manage"
        ? (root.headerHeight + manageColumn.implicitHeight)
        : (root.headerHeight + formColumn.implicitHeight)))
  readonly property int cardHeight: Math.min(panel.height - Style.gapsOut * 2, contentH + pad * 2)
  readonly property string headerTitle: {
    if (root.view === "reorderMove")
      return "Move \u201c" + (root.moveSourceLabel || "item") + "\u201d to\u2026"
    if (root.view === "reorder") {
      var rt = root.itemAtPath(root.reorderPath)
      var suffix = (root.reorderPath && rt && rt.label) ? " \u203a " + rt.label : ""
      return "Move/Edit Items \u2014 " + ((root.currentContext && root.currentContext.name) || root.contextId || "") + suffix
    }
    if (root.view === "manage") {
      var m = root.itemAtPath(root.managePath)
      return "Manage \u2014 " + ((m && m.label) || "")
    }
    if (root.view === "editContext") return root.editingAdd ? "New context" : "Edit context"
    return root.itemAddMode ? "Add item" : "Edit item"
  }

  // Type row is locked (hidden) for an existing submenu that has children, so
  // a type conversion can never silently drop the subtree.
  readonly property bool itemTypeLocked: {
    if (root.itemType !== "submenu" || root.itemAddMode) return false
    var it = root.itemAtPath(root.itemPath)
    return !!(it && it.items && it.items.length > 0)
  }

  // Children of the submenu being managed (manage view list model).
  readonly property var manageItems: {
    var it = root.managePath ? root.itemAtPath(root.managePath) : null
    return (it && it.items) ? it.items : []
  }
  readonly property int manageListCount: root.manageItems.length

  // Centered overlay, mirroring the omarchy Menu: a full-screen layer-shell
  // with a scrim and a card centered on the screen (not anchored to the bar).
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-context-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Exclusive keyboard focus routes Escape to this surface from any output.
    // Re-grab QML focus each time the window maps so the keyCatcher actually
    // receives it (a just-mapped layer can miss the open()-time forceActiveFocus).
    onBackingWindowVisibleChanged: {
      if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.55)
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: root.pad

      MouseArea { anchors.fill: parent; onClicked: {} }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        blocked: root.confirmOpen || root.editingText || ctxProfileDropdown.popupOpen || root.view === "reorder" || root.view === "reorderMove"
        onMoveRequested: function(dx, dy) { if (dx < 0) root.goBack() }
        onCloseRequested: root.goBack()
        onTabRequested: function(d) { root.switchPanel(d) }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.spacing.xs

          RowLayout {
            width: parent.width
            height: root.headerHeight
            spacing: Style.space(8)

            Button {
              id: backButton
              text: "\uf053"
              Layout.preferredWidth: Style.space(28)
              Layout.preferredHeight: Style.space(28)
              Layout.alignment: Qt.AlignVCenter
              verticalPadding: 0
              horizontalPadding: 0
              onClicked: root.goBack()
            }

            Text {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: root.headerTitle
              color: root.fg
              opacity: 0.92
              font.family: root.fam
              font.pixelSize: Style.font.heading
              font.weight: Font.Medium
              elide: Text.ElideRight
            }
          }

          Column {
            id: formColumn
            width: parent.width
            spacing: Style.spacing.sm

            Column {
              visible: root.view === "editContext"
              width: parent.width
              spacing: Style.spacing.xs

              PanelSectionHeader { text: "Name" }
              TextField {
                id: ctxNameField
                width: parent.width
                placeholderText: "Context name"
                onAccepted: ctxShortcutField.forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { text: "Shortcut (SUPER+ALT+)" }
              TextField {
                id: ctxShortcutField
                width: parent.width
                maximumLength: 1
                placeholderText: "P"
                onAccepted: ctxIconField.forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { text: "Icon (nerd font glyph)" }
              TextField {
                id: ctxIconField
                width: parent.width
                placeholderText: "\uf1d4"
                onAccepted: ctxProfileDropdown.forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { text: "Chrome profile (URLs + Browser)" }
              Dropdown {
                id: ctxProfileDropdown
                width: parent.width
                label: ""
                showLabel: false
                options: root.chromeProfileOptions
                value: root.chromeProfile
                onChanged: function(v) { root.chromeProfile = v }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: "Delete"
                  visible: !root.editingAdd
                  foreground: Color.urgent
                  bordered: true
                  onClicked: root.requestDeleteContext()
                }
                Item { Layout.fillWidth: true }
                Button {
                  text: "Cancel"
                  onClicked: root.cancelEdit()
                }
                Button {
                  text: "Save"
                  accent: Color.accent
                  onClicked: root.applyContextSave()
                }
              }
            }

            Column {
              visible: root.view === "editItem"
              width: parent.width
              spacing: Style.spacing.xs

              PanelSectionHeader { visible: !root.itemTypeLocked; text: "Type" }
              RowLayout {
                visible: !root.itemTypeLocked
                width: parent.width
                spacing: Style.spacing.xs
                Repeater {
                  model: [
                    { value: "web", label: "Web" },
                    { value: "remote", label: "Remote" },
                    { value: "terminal", label: "Terminal" },
                    { value: "script", label: "Script" },
                    { value: "submenu", label: "Submenu" }
                  ]
                  delegate: Button {
                    required property var modelData
                    text: modelData.label
                    Layout.fillWidth: true
                    selected: root.itemType === modelData.value
                    accent: Color.accent
                    onClicked: root.itemType = modelData.value
                  }
                }
              }

              // Remote covers both mosh and ssh (kept distinct in the JSON).
              RowLayout {
                visible: root.itemType === "remote"
                width: parent.width
                spacing: Style.space(8)
                Text {
                  text: "Connect via"
                  color: root.dim
                  font.family: root.fam
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }
                Button {
                  text: "Mosh"
                  selected: root.itemRemoteKind === "mosh"
                  accent: Color.accent
                  onClicked: root.itemRemoteKind = "mosh"
                }
                Button {
                  text: "SSH"
                  selected: root.itemRemoteKind === "ssh"
                  accent: Color.accent
                  onClicked: root.itemRemoteKind = "ssh"
                }
                Item { Layout.fillWidth: true }
              }

              // What the selected type does (Terminal vs Script differs in
              // whether a window is opened; submenu groups items).
              Text {
                width: parent.width
                text: root.itemType === "web" ? "Open a URL in the context's Chrome profile"
                  : root.itemType === "remote" ? "Connect via Mosh or SSH in a new terminal"
                  : root.itemType === "terminal" ? "Run a command in a new terminal window (output stays visible)"
                  : root.itemType === "script" ? "Run a command directly (no window)"
                  : root.itemType === "submenu" ? "Group items under a nested submenu" : ""
                color: root.dim
                font.family: root.fam
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              PanelSectionHeader { text: "Title" }
              TextField {
                id: itemTitleField
                width: parent.width
                placeholderText: "Item title"
                onAccepted: root.firstTypeField().forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { text: "Icon (nerd font glyph)" }
              TextField {
                id: itemIconField
                width: parent.width
                placeholderText: "\uf1d4"
                onAccepted: {
                  if (root.itemType === "submenu") root.applyItemSave()
                  else if (root.firstTypeField()) root.firstTypeField().forceActiveFocus()
                }
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "web"; text: "URL" }
              TextField {
                id: itemUrlField
                visible: root.itemType === "web"
                width: parent.width
                placeholderText: "https://…"
                onAccepted: root.applyItemSave()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "remote"; text: "Host" }
              TextField {
                id: itemHostField
                visible: root.itemType === "remote"
                width: parent.width
                placeholderText: "user@host"
                onAccepted: itemCommandField.forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "remote" || root.itemType === "terminal" || root.itemType === "script"; text: "Command" }
              TextField {
                id: itemCommandField
                visible: root.itemType === "remote" || root.itemType === "terminal" || root.itemType === "script"
                width: parent.width
                placeholderText: (root.itemType === "remote") ? "optional remote command"
                  : (root.itemType === "terminal") ? "command to run in a new terminal window"
                  : "command run directly (no window)"
                onAccepted: (root.itemType === "remote") ? itemWorkdirField.forceActiveFocus() : root.applyItemSave()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "remote"; text: "Workdir (optional)" }
              TextField {
                id: itemWorkdirField
                visible: root.itemType === "remote"
                width: parent.width
                placeholderText: "~/work"
                onAccepted: root.applyItemSave()
                Keys.onEscapePressed: root.cancelEdit()
              }

              // Existing submenus get a manage entry (children live at the
              // same level as this form's parent menu, one scope deeper).
              Button {
                visible: root.itemType === "submenu" && !root.itemAddMode
                width: parent.width
                bordered: true
                text: {
                  var it = root.itemAtPath(root.itemPath)
                  var n = (it && it.items) ? it.items.length : 0
                  return "Manage items (" + n + ")"
                }
                onClicked: root.startManage(root.itemPath)
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: "Delete"
                  visible: !root.itemAddMode
                  foreground: Color.urgent
                  bordered: true
                  onClicked: root.requestDeleteItem()
                }
                Item { Layout.fillWidth: true }
                Button {
                  text: "Cancel"
                  onClicked: root.cancelEdit()
                }
                Button {
                  text: "Save"
                  accent: Color.accent
                  onClicked: root.applyItemSave()
                }
              }
            }
          }

        // Manage view: a submenu's own edit menu (add / reorder / edit
        // individual children), mirroring the context-level edit list.
        Column {
          id: manageColumn
          visible: root.view === "manage"
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            text: root.manageListCount > 0 ? "Click an item to edit it, or add / reorder below."
                                           : "No items yet \u2014 add one below."
            color: root.dim
            font.family: root.fam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          ListView {
            id: manageList
            width: parent.width
            height: Math.min(root.manageListCount * (root.reorderRowHeight + Style.spacing.xs), root.reorderMaxHeight)
            clip: true
            model: root.manageItems
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            focus: true

            delegate: Button {
              required property int index
              required property var modelData
              width: ListView.view.width
              height: root.reorderRowHeight
              horizontalPadding: Style.space(12)
              text: (modelData.icon || "\uf07b") + "  " + (modelData.label || "(untitled)") + "  \uf044"
              onClicked: root.startEditItem(root.contextId, root.managePath + "." + index)
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Add item"
              onClicked: root.startAddItem(root.contextId, root.managePath)
            }
            Button {
              text: "Move/Edit Items"
              onClicked: root.startReorder(root.contextId, root.managePath)
            }
            Item { Layout.fillWidth: true }
          }
        }

        // Move-to-submenu chooser (reorder view, m key): pick an existing
        // submenu in this scope or create a new one, then return to reorder.
        Column {
          visible: root.view === "reorderMove"
          width: parent.width
          spacing: Style.spacing.xs

          ListView {
            id: reorderMoveList
            width: parent.width
            height: root.reorderMoveListHeight
            clip: true
            model: root.moveTargets
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            focus: true

            Keys.onPressed: function(event) {
              if (root.view !== "reorderMove" || root.moveNewMode) return
              if (event.key === Qt.Key_Escape) { root.cancelMoveToSubmenu(); event.accepted = true; return }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.executeMoveTarget(); event.accepted = true; return }
              if (event.key === Qt.Key_Up) { root.selectMoveTarget(-1); event.accepted = true; return }
              if (event.key === Qt.Key_Down) { root.selectMoveTarget(1); event.accepted = true; return }
              if (event.text === "j" || event.text === "J") { root.selectMoveTarget(1); event.accepted = true; return }
              if (event.text === "k" || event.text === "K") { root.selectMoveTarget(-1); event.accepted = true; return }
            }

            delegate: BorderSurface {
              required property int index
              required property var modelData

              readonly property bool hasCursor: root.view === "reorderMove" && root.moveSelected === index

              width: ListView.view.width
              height: root.reorderRowHeight
              radius: Style.cornerRadius
              color: hasCursor ? root.selectedBg : "transparent"
              borderSpec: hasCursor ? Border.flat(root.acc, Math.max(1, Style.normalBorderWidth)) : Border.none()

              RowLayout {
                anchors.fill: parent
                spacing: Style.space(8)

                Text {
                  Layout.preferredWidth: Style.space(24)
                  Layout.alignment: Qt.AlignVCenter
                  text: modelData.kind === "new" ? "\uf067" : "\uf07b"
                  color: root.fg
                  font.family: root.fam
                  font.pixelSize: Style.font.icon
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  text: modelData.label
                  color: root.fg
                  font.family: root.fam
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }
          }

          TextField {
            id: moveNewField
            visible: root.moveNewMode
            width: parent.width
            placeholderText: "New submenu name"
            onAccepted: root.executeNewSubmenuMove(moveNewField.text)
            Keys.onEscapePressed: {
              root.moveNewMode = false
              Qt.callLater(function() { root.focusField(reorderMoveList) })
            }
          }

          Text {
            visible: root.moveNewMode
            width: parent.width
            text: "Enter creates the submenu and moves the item \u00b7 Esc back to the list"
            color: root.dim
            font.family: root.fam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Column {
          id: reorderColumn
          visible: root.view === "reorder"
          width: parent.width
          spacing: Style.spacing.xs

          ListView {
            id: reorderList
            width: parent.width
            height: root.reorderListHeight
            clip: true
            model: root.reorderDisplayModel
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            focus: true

            Keys.onPressed: function(event) {
              if (root.view !== "reorder") return
              var shift = event.modifiers & Qt.ShiftModifier
              if (event.key === Qt.Key_Escape) { root.commitReorder(); event.accepted = true; return }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.editReorderSelection(); event.accepted = true; return }
              if (event.key === Qt.Key_Up) { if (shift) root.moveReorder(-1); else root.selectReorder(-1); event.accepted = true; return }
              if (event.key === Qt.Key_Down) { if (shift) root.moveReorder(1); else root.selectReorder(1); event.accepted = true; return }
              if (event.text === "j" || event.text === "J") { root.selectReorder(1); event.accepted = true; return }
              if (event.text === "k" || event.text === "K") { root.selectReorder(-1); event.accepted = true; return }
              if (event.text === "m" || event.text === "M") { root.startMoveToSubmenu(); event.accepted = true; return }
            }

            Keys.onReleased: function(event) {
              root.shiftHeld = !!(event.modifiers & Qt.ShiftModifier)
            }

            delegate: Item {
              id: reorderRow
              required property int index
              required property var modelData

              readonly property bool hasActionRow: modelData.kind !== "separator" && modelData.kind !== "hint"
              readonly property bool hasCursor: hasActionRow && root.view === "reorder" && root.reorderSelected === index

              width: ListView.view.width
              height: modelData.kind === "separator" ? Style.space(16)
                : (modelData.kind === "hint" ? Math.max(Style.space(24), Math.round(Style.font.caption * 1.3))
                : root.reorderRowHeight)

              BorderSurface {
                visible: reorderRow.hasActionRow
                width: parent.width
                height: parent.height
                radius: Style.cornerRadius
                color: reorderRow.hasCursor ? root.selectedBg : "transparent"
                borderSpec: reorderRow.hasCursor ? Border.flat(root.acc, Math.max(1, Style.normalBorderWidth)) : Border.none()

                RowLayout {
                  anchors.fill: parent
                  spacing: Style.space(8)

                  Text {
                    Layout.preferredWidth: Style.space(24)
                    Layout.alignment: Qt.AlignVCenter
                    text: root.reorderIconFor(index)
                    color: root.fg
                    font.family: root.fam
                    font.pixelSize: Style.font.icon
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: modelData.label || "(untitled)"
                    color: root.fg
                    font.family: root.fam
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }
              }

              Rectangle {
                visible: modelData.kind === "separator"
                width: parent.width
                height: 1
                anchors.verticalCenter: parent.verticalCenter
                color: Util.alpha(root.fg, 0.15)
              }

              Text {
                visible: modelData.kind === "hint"
                width: parent.width
                height: parent.height
                text: modelData.label
                color: root.dim
                font.family: root.fam
                font.pixelSize: Style.font.caption
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Item { Layout.fillWidth: true }
            Button {
              text: "Done"
              accent: Color.accent
              onClicked: root.commitReorder()
            }
          }
        }
      }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.confirmOpen
        message: root.confirmMessage
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.fg
        selectedText: Color.urgent
        onCanceled: { root.confirmOpen = false; root.confirmAction = null; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
        onConfirmed: {
          var a = root.confirmAction
          root.confirmOpen = false
          root.confirmAction = null
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          if (a) a()
        }
      }

      Item {
        id: confirmGrab
        anchors.fill: parent
        focus: root.confirmOpen
        visible: root.confirmOpen
        Keys.onPressed: function(event) {
          if (confirmDialog.handleKey(event)) event.accepted = true
        }
      }
    }
  }
}
