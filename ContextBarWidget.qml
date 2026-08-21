import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import "ContextModel.js" as Model

// Bar-widget: active context name + N workspace slots for the focused monitor.
// Reads state from the Context Switcher service; clicking a slot calls the
// omarchy-context CLI (which routes through the service via IPC).
//
// Vertical bars: the context name collapses to its trigger letter and the
// slots stack in a single column (same as Omarchy's default workspace widget).
// The focused slot uses the shell's active selector color (bar.urgent).
BarWidget {
  id: root
  moduleName: "context-switcher"

  readonly property var service: bar ? bar.shell.firstPartyServiceFor("context-switcher") : null

  readonly property int slots: (service && service.config && service.config.slots) || 10
  readonly property string contextName: service ? Model.contextName(service.config || { contexts: [] }, service.currentContextId || "personal") : ""
  // The shortcut letter that summons this context's menu (shown when vertical).
  readonly property string contextShortcut: {
    if (!service || !service.config) return ""
    var c = Model.contextById(service.config, service.currentContextId || "personal")
    return c ? (c.shortcut || "") : ""
  }
  readonly property bool ready: service && service.configLoaded

  // Bumped on any relevant change so slot property bindings re-evaluate.
  property int revision: 0
  function bump() { root.revision += 1 }

  // Show slots 1..5 always; extend to the highest occupied (or active) slot in
  // the current context so a window on slot 8 shows 1..8 with 2..7 dimmed.
  readonly property var workspaceIds: {
    void root.revision
    var maxVisible = 5
    if (service && service.config) {
      var ctxId = service.currentContextId || "personal"
      var cfg = service.config || { contexts: [], slots: root.slots }
      var base = Model.contextBase(cfg, ctxId)
      var values = Hyprland.workspaces.values
      for (var i = 0; i < values.length; i++) {
        var ws = values[i]
        if (!ws) continue
        var id = ws.id
        if (id < base || id >= base + root.slots) continue  // not in this context
        var slot = id - base + 1
        var occupied = ws.toplevels && ws.toplevels.values && ws.toplevels.values.length > 0
        if (occupied && slot > maxVisible) maxVisible = slot
      }
      // Always keep the active slot visible even if it is empty.
      var active = root.focusedSlot()
      if (active > maxVisible && active <= root.slots) maxVisible = active
    }
    var ids = []
    for (var j = 1; j <= maxVisible; j++) ids.push(j)
    return ids
  }

  // Touching revision here forces re-evaluation when it changes.
  function focusedSlot() {
    var ws = Hyprland.focusedWorkspace
    if (!service || !ws) return 0
    var slot = Model.slotForWorkspace(service.config || { contexts: [], slots: root.slots }, ws.id)
    void root.revision
    return slot
  }

  function occupiedSlot(slot) {
    if (!service || !service.workspacesById) return false
    var base = Model.contextBase(service.config || { contexts: [], slots: root.slots }, service.currentContextId || "personal")
    var occ = !!service.workspacesById[String(base + slot - 1)]
    void root.revision
    return occ
  }

  function slotLabel(slot) {
    return slot === 10 ? "0" : String(slot)
  }

  implicitWidth: grid.implicitWidth
  implicitHeight: grid.implicitHeight

  // Grid so the slots stack vertically (one column) when the bar is vertical.
  GridLayout {
    id: grid
    anchors.fill: parent
    columns: root.vertical ? 1 : (root.workspaceIds.length + 1)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    // Context label — full name horizontally, trigger letter when vertical.
    WidgetButton {
      bar: root.bar
      text: root.vertical ? root.contextShortcut : root.contextName
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : -1
      fixedHeight: root.barSize
      tooltipText: (root.vertical ? root.contextName + "\n" : "") + "Context (click: next)"
      onPressed: function() { if (root.bar) root.bar.run("omarchy-context next") }
    }

    // Slot indicators
    Repeater {
      model: root.workspaceIds

      WidgetButton {
        required property int modelData

        readonly property bool isFocused: root.focusedSlot() === modelData
        readonly property bool isOccupied: root.occupiedSlot(modelData)

        bar: root.bar
        text: root.slotLabel(modelData)
        // Focused slot uses the shell's active selector color.
        active: isFocused
        opacity: (isFocused || isOccupied) ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        tooltipText: isFocused ? "Active" : (isOccupied ? "Occupied" : "Empty")
        onPressed: function() { if (root.bar) root.bar.run("omarchy-context goto " + modelData) }
      }
    }
  }

  Connections {
    target: root.service
    function onStateUpdated() { root.bump() }
    function onRefreshRequested() { root.bump() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "focusedmon" || name === "workspace" || name === "createworkspace" || name === "destroyworkspace" || name === "moveworkspace") {
        root.bump()
      }
    }
  }

  Component.onCompleted: root.bump()
}
