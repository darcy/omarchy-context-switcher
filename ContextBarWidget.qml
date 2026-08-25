import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "ContextModel.js" as Model

// Bar-widget: per-monitor context name + workspace slots.
//
// Each bar surface shows the context of the workspace its own monitor is
// displaying (Hyprland monitor activeWorkspace), so a monitor on Zippy's slot
// 2 reads "Zippy 2" while another on Personal 1 reads "Personal 1" — fully
// independent of which monitor is globally focused.
//
// Vertical bars: the context name collapses to its trigger letter and the
// slots stack in one column (like Omarchy's default workspace widget). The
// active slot uses the shell's active selector color (bar.urgent).
BarWidget {
  id: root
  moduleName: "context-switcher"

  readonly property var service: bar ? bar.shell.firstPartyServiceFor("context-switcher") : null

  readonly property int slots: (service && service.config && service.config.slots) || 10
  readonly property bool ready: service && service.configLoaded

  // The launcher is the system menu; the editor is owned by the service. This
  // widget only manages: show context name + slots. Left click opens the
  // context menu, right click advances context.

  // Bumped on any relevant change so slot property bindings re-evaluate.
  property int revision: 0
  function bump() { root.revision += 1 }

  // ---- Per-monitor identity ----
  // The monitor this bar surface renders on (its Quickshell window's screen).
  readonly property string myMonitor: {
    void root.revision
    var w = root.QsWindow && root.QsWindow.window ? root.QsWindow.window : null
    return (w && w.screen) ? String(w.screen.name || "") : ""
  }

  // The workspace id this monitor is currently displaying.
  // Prefer the service's authoritative hyprctl-derived map (which stays fresh
  // across cross-monitor moves) over the lagging Quickshell monitors model.
  readonly property int myMonitorWorkspaceId: {
    void root.revision
    if (service && service.monitorActiveWorkspace && service.monitorActiveWorkspace[root.myMonitor]) {
      return Number(service.monitorActiveWorkspace[root.myMonitor]) || 0
    }
    var mons = Hyprland.monitors.values
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (m && String(m.name || "") === root.myMonitor && m.activeWorkspace)
        return Number(m.activeWorkspace.id) || 0
    }
    return 0
  }

  // This monitor's context: derived from the workspace it is showing, falling
  // back to the persisted per-monitor context, then the default.
  readonly property string contextId: {
    void root.revision
    if (!service || !service.config) return "personal"
    var derived = root.myMonitorWorkspaceId > 0
      ? Model.contextForWorkspace(service.config, root.myMonitorWorkspaceId)
      : ""
    if (derived) return derived
    var mc = (service.state && service.state.monitor_context) ? service.state.monitor_context : {}
    return (root.myMonitor && mc[root.myMonitor]) ? mc[root.myMonitor] : (service.currentContextId || "personal")
  }

  readonly property string contextName: service ? Model.contextName(service.config || { contexts: [] }, root.contextId) : ""
  // The shortcut letter that summons this context's menu (shown when vertical).
  readonly property string contextShortcut: {
    if (!service || !service.config) return ""
    var c = Model.contextById(service.config, root.contextId)
    return c ? (c.shortcut || "") : ""
  }

  // ---- Slots ----

  // Show slots 1..5 always; extend to the highest occupied/active slot in this
  // monitor's context so a window on slot 8 shows 1..8 with 2..7 dimmed.
  readonly property var workspaceIds: {
    void root.revision
    var maxVisible = 5
    if (service && service.config && service.config.contexts) {
      var cfg = service.config
      var base = Model.contextBase(cfg, root.contextId)
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
      // Always keep this monitor's active slot visible even if it is empty.
      var active = root.activeSlot()
      if (active > maxVisible && active <= root.slots) maxVisible = active
    }
    var ids = []
    for (var j = 1; j <= maxVisible; j++) ids.push(j)
    return ids
  }

  // The active slot = the workspace this monitor is showing, mapped into its
  // context's slot range.
  function activeSlot() {
    var cfg = service && service.config ? service.config : null
    if (!cfg) return 0
    void root.revision
    var wsId = root.myMonitorWorkspaceId
    if (wsId <= 0) return 0
    var base = Model.contextBase(cfg, root.contextId)
    var slot = wsId - base + 1
    return (slot >= 1 && slot <= root.slots) ? slot : 0
  }

  function occupiedSlot(slot) {
    if (!service || !service.workspacesById) return false
    var base = Model.contextBase(service.config || { contexts: [], slots: root.slots }, root.contextId)
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
    // Click opens the context popup (picker), right-click advances context.
    WidgetButton {
      id: contextButton
      bar: root.bar
      text: root.vertical ? root.contextShortcut : root.contextName
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : -1
      fixedHeight: root.barSize
      tooltipText: (root.vertical ? root.contextName + "\n" : "") + "Context (click: menu, right: next)"
      onPressed: function(b) {
        if (b === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-context-switcher next") }
        else if (root.bar) root.bar.run("omarchy menu summon contexts")
      }
    }

    // Slot indicators
    Repeater {
      model: root.workspaceIds

      WidgetButton {
        required property int modelData

        readonly property bool isActive: root.activeSlot() === modelData
        readonly property bool isOccupied: root.occupiedSlot(modelData)

        bar: root.bar
        text: root.slotLabel(modelData)
        // Active slot uses the shell's active selector color.
        active: isActive
        opacity: (isActive || isOccupied) ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        tooltipText: isActive ? "Active" : (isOccupied ? "Occupied" : "Empty")
        onPressed: function() { if (root.bar) root.bar.run("omarchy-context-switcher goto " + modelData) }
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
      if (name === "focusedmon" || name === "workspace" || name === "createworkspace" || name === "destroyworkspace" || name === "moveworkspace" || name === "activewindow") {
        root.bump()
      }
    }
  }

  Component.onCompleted: root.bump()
}
