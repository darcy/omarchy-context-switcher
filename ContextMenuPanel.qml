import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
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
  // "editContextNew" | "editContext" | "editItem".
  property string requestContext: ""
  property string requestMode: ""
  property int requestItemIndex: -1

  property string view: "editContext"
  property string contextId: ""
  property int itemIndex: -1
  property bool confirmOpen: false
  property var confirmAction: null
  property string confirmMessage: ""

  property bool editingAdd: false
  property bool itemAddMode: false
  property string oldItemLabel: ""
  property string itemType: "web"

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
      if (root.requestItemIndex >= 0) root.startEditItem(root.requestContext, root.requestItemIndex)
      else root.startAddItem(root.requestContext)
    }
    root.requestMode = ""
    root.requestContext = ""
    root.requestItemIndex = -1
    root.controller.show()
    if (root.view === "editContext") root.focusField(ctxNameField)
    else root.focusField(itemTitleField)
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

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
    if (root.view === "editItem") root.returnToSystemMenu("contexts." + root.contextId + ".menu.~items")
    else root.returnToSystemMenu(root.editingAdd ? "" : "contexts." + root.contextId)
  }

  function cancelEdit() { root.goBack() }

  function startAddContext() {
    root.editingAdd = true; root.contextId = ""
    ctxNameField.text = ""; ctxShortcutField.text = ""; ctxIconField.text = ""
    root.view = "editContext"
    root.focusField(ctxNameField)
  }

  function startEditContext(id) {
    var c = root.contextById(id)
    if (!c) return
    root.editingAdd = false; root.contextId = id
    ctxNameField.text = c.name || ""; ctxShortcutField.text = c.shortcut || ""; ctxIconField.text = c.icon || ""
    root.view = "editContext"
    root.focusField(ctxNameField)
  }

  function applyContextSave() {
    var name = ctxNameField.text.trim()
    if (!name) return
    if (root.editingAdd) {
      if (service) service.addContext(name, ctxShortcutField.text, ctxIconField.text)
    } else if (service) {
      service.renameContext(root.contextId, name)
      service.setContextShortcut(root.contextId, ctxShortcutField.text)
      service.setContextIcon(root.contextId, ctxIconField.text)
    }
    root.returnToSystemMenu(root.editingAdd ? "" : "contexts." + root.contextId)
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
      root.returnToSystemMenu("")
    }
    root.confirmOpen = true
    Qt.callLater(function() { confirmGrab.forceActiveFocus() })
  }

  function startAddItem(cid) {
    var c = root.contextById(cid)
    if (!c) return
    root.itemAddMode = true; root.contextId = cid; root.itemIndex = -1; root.oldItemLabel = ""
    root.itemType = "web"
    itemTitleField.text = ""; itemIconField.text = ""
    itemUrlField.text = ""; itemHostField.text = ""; itemCommandField.text = ""; itemWorkdirField.text = ""
    root.view = "editItem"
    root.focusField(itemTitleField)
  }

  function startEditItem(cid, idx) {
    var c = root.contextById(cid)
    if (!c || !c.menu || idx < 0 || idx >= c.menu.length) return
    var item = c.menu[idx]
    root.itemAddMode = false; root.contextId = cid; root.itemIndex = idx
    root.oldItemLabel = item.label || ""
    root.itemType = item.type || (item.url ? "web" : item.host ? "mosh" : item.command ? "script" : "browser")
    itemTitleField.text = item.label || ""; itemIconField.text = item.icon || ""
    itemUrlField.text = item.url || ""; itemHostField.text = item.host || ""
    itemCommandField.text = item.command || ""; itemWorkdirField.text = item.workdir || ""
    root.view = "editItem"
    root.focusField(itemTitleField)
  }

  // Assemble the item object from the current form fields + selected type.
  function buildItemObject() {
    var o = { label: itemTitleField.text.trim(), icon: itemIconField.text.trim() }
    var t = root.itemType
    o.type = t
    if (t === "web") o.url = itemUrlField.text.trim()
    else if (t === "browser") { /* no extra fields */ }
    else if (t === "mosh") {
      o.host = itemHostField.text.trim()
      if (itemCommandField.text.trim()) o.command = itemCommandField.text.trim()
      if (itemWorkdirField.text.trim()) o.workdir = itemWorkdirField.text.trim()
    } else { // terminal, script
      o.command = itemCommandField.text.trim()
    }
    return o
  }

  // First type-specific field for the current item type (Enter target).
  function firstTypeField() {
    if (root.itemType === "web") return itemUrlField
    if (root.itemType === "mosh") return itemHostField
    if (root.itemType === "terminal" || root.itemType === "script") return itemCommandField
    return itemIconField  // browser: no type-specific field
  }

  function applyItemSave() {
    var o = root.buildItemObject()
    if (!o.label) return
    if (root.itemAddMode) {
      if (service) service.addItemObject(root.contextId, JSON.stringify(o))
    } else if (service) {
      service.updateItem(root.contextId, root.oldItemLabel, JSON.stringify(o))
    }
    root.close()
  }

  function requestDeleteItem() {
    var item = root.currentContextMenu[root.itemIndex]
    if (!item) return
    var label = root.oldItemLabel || item.label
    var cname = (root.currentContext && root.currentContext.name) || root.contextId
    root.confirmMessage = "Delete item \u201c" + label + "\u201d from \u201c" + cname + "\u201d?"
    root.confirmAction = function() {
      if (service) service.deleteItem(root.contextId, label)
      root.returnToSystemMenu("contexts." + root.contextId + ".menu.~items")
    }
    root.confirmOpen = true
    Qt.callLater(function() { confirmGrab.forceActiveFocus() })
  }

  readonly property int headerHeight: Style.space(40)
  readonly property int pad: Style.spacing.popupPadding
  readonly property int cardWidth: Math.min(panel.width - Style.gapsOut * 2, Style.space(380))
  readonly property int contentH: root.headerHeight + formColumn.implicitHeight
  readonly property int cardHeight: Math.min(panel.height - Style.gapsOut * 2, contentH + pad * 2)
  readonly property string headerTitle: {
    if (root.view === "editContext") return root.editingAdd ? "New context" : "Edit context"
    return root.itemAddMode ? "Add item" : "Edit item"
  }

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
        blocked: root.confirmOpen || root.editingText
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
                onAccepted: root.applyContextSave()
                Keys.onEscapePressed: root.cancelEdit()
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

              PanelSectionHeader { text: "Type" }
              RowLayout {
                width: parent.width
                spacing: Style.spacing.xs
                Repeater {
                  model: [
                    { value: "web", label: "Web" },
                    { value: "browser", label: "Browser" },
                    { value: "mosh", label: "Mosh" },
                    { value: "terminal", label: "Terminal" },
                    { value: "script", label: "Script" }
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
                onAccepted: root.firstTypeField().forceActiveFocus()
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

              PanelSectionHeader { visible: root.itemType === "mosh"; text: "Host" }
              TextField {
                id: itemHostField
                visible: root.itemType === "mosh"
                width: parent.width
                placeholderText: "user@host"
                onAccepted: itemCommandField.forceActiveFocus()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "mosh" || root.itemType === "terminal" || root.itemType === "script"; text: "Command" }
              TextField {
                id: itemCommandField
                visible: root.itemType === "mosh" || root.itemType === "terminal" || root.itemType === "script"
                width: parent.width
                placeholderText: root.itemType === "mosh" ? "optional remote command" : "command to run"
                onAccepted: root.itemType === "mosh" ? itemWorkdirField.forceActiveFocus() : root.applyItemSave()
                Keys.onEscapePressed: root.cancelEdit()
              }

              PanelSectionHeader { visible: root.itemType === "mosh"; text: "Workdir (optional)" }
              TextField {
                id: itemWorkdirField
                visible: root.itemType === "mosh"
                width: parent.width
                placeholderText: "~/work"
                onAccepted: root.applyItemSave()
                Keys.onEscapePressed: root.cancelEdit()
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
