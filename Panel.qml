import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fault Line: what broke since boot. Failed units and the journal's error
// lines, folded so a message that repeats is one row, with a handoff to your
// agent. The bar icon only shows when there is something new.
Panel {
  id: root
  moduleName: "cgranier.faultline"
  ipcTarget: "cgranier.faultline"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showInBar: faults.counts.fresh > 0 || opened || setting("alwaysShow", false) === true

  readonly property var rows: Model.buildRows(faults.failed, faults.problems, faults.mutedItems)
  readonly property var cursorRows: Model.cursorRows(rows)

  function clampCursor() {
    cursorIndex = Math.max(0, Math.min(cursorIndex, Math.max(0, cursorRows.length - 1)))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
    scrollCursorIntoView()
  }

  function selectedItem() {
    if (cursorRows.length === 0) return null
    clampCursor()
    return cursorRows[cursorIndex].item
  }

  function diagnose(item) {
    if (!item || !faults.agentAvailable) return
    faults.diagnose(item)
    root.close()
  }

  function moveCursorToItem(item) {
    for (var i = 0; i < cursorRows.length; i++) if (cursorRows[i].item.key === item.key) { cursorIndex = i; return }
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      for (var i = 0; i < rowColumn.children.length; i++) {
        var item = rowColumn.children[i]
        if (!item || item.cursorIndex !== root.cursorIndex) continue
        var margin = Style.space(6)
        var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottom = top + item.height
        var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
        if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
        else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        return
      }
    })
  }

  visible: showInBar
  implicitWidth: showInBar ? button.implicitWidth : 0
  implicitHeight: showInBar ? button.implicitHeight : 0

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      panelFlick.contentY = 0
      faults.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      faults.markSeen()
    }
  }

  Service {
    id: faults
    settings: root.settings
  }

  onCursorRowsChanged: clampCursor()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { faults.refresh(); return "ok" }
    function status(): string { return faults.summary }
    function state(): string {
      return JSON.stringify({ loaded: faults.loaded, counts: faults.counts, window: faults.window, muted: faults.muted,
        seenMs: faults.seenMs, agent: faults.agentAvailable, rows: root.rows.length })
    }
    function markSeen(): string { faults.markSeen(); return "ok" }
    function window(): string { faults.cycleWindow(); return faults.window }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barLabel(faults.counts, root.vertical)
    active: faults.counts.fresh > 0
    dimmed: faults.counts.fresh === 0
    tooltipText: root.opened ? "" : (faults.counts.fresh > 0 ? faults.counts.fresh + " new · " : "") + faults.summary

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) faults.markSeen()
      else if (buttonCode === Qt.MiddleButton) faults.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + footer.implicitHeight + Style.space(12), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.diagnose(root.selectedItem())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") faults.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "t" || t === "T") faults.cycleWindow()
        else if (t === "c" || t === "C") faults.copyReport(root.selectedItem())
        else if (t === "i" || t === "I") { faults.showLog(root.selectedItem()); root.close() }
        else if (t === "m" || t === "M") {
          var item = root.selectedItem()
          faults.toggleMute(item)
          if (item) Qt.callLater(function() { root.moveCursorToItem(item); root.scrollCursorIntoView() })
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(8)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Fault Line"
            meta: faults.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.rows.length > 0 ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.GLYPHS.fault
                color: faults.counts.fresh > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: faults.actionStatus !== "" ? faults.actionStatus
              : !faults.agentAvailable && faults.loaded ? "No default coding agent is set, so enter is off. i still opens the log."
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: faults.loaded && root.rows.length === 0
            width: parent.width
            text: "Nothing has gone wrong. Enjoy it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: rowColumn
            visible: root.rows.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              Loader {
                required property var modelData
                readonly property int cursorIndex: modelData.cursorIndex === undefined ? -1 : modelData.cursorIndex
                width: rowColumn.width
                sourceComponent: modelData.type === "header" ? headerRow : itemRow
                onLoaded: item.row = modelData
              }
            }
          }
        }
      }

      // Stays put while the list scrolls.
      Text {
        id: footer
        textFormat: Text.PlainText
        visible: root.rows.length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        text: (faults.agentAvailable ? "enter diagnose · " : "") + "i log · m mute · t " + Model.windowById(faults.window).label + " · c copy · r refresh"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: headerRow

    Item {
      property var row: null
      implicitHeight: headerText.implicitHeight + Style.space(10)

      PanelSectionHeader {
        id: headerText
        anchors.bottom: parent.bottom
        text: row ? row.text : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  // One component for a failed unit and for a folded problem.
  Component {
    id: itemRow

    CursorSurface {
      id: surface
      property var row: null
      readonly property var item: row ? row.item : null
      readonly property bool isFailed: row ? row.type === "failed" : false
      readonly property bool isNew: item !== null && !row.muted && (isFailed ? item.fresh : item.fresh > 0)

      hasCursor: root.cursorActive && row !== null && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
      opacity: row && row.muted ? 0.55 : 1.0

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (surface.row) { root.cursorActive = true; root.cursorIndex = surface.row.cursorIndex }
        onClicked: root.diagnose(surface.item)
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: !surface.item ? "" : surface.row.muted ? Model.GLYPHS.muted : surface.isFailed ? Model.GLYPHS.failed : Model.scopeGlyph(surface.item.scope)
          color: surface.isFailed && !surface.row.muted ? root.urgent : root.foreground
          opacity: surface.isFailed ? 1.0 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
        }

        ColumnLayout {
          id: content
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: !surface.item ? "" : surface.isFailed ? surface.item.unit : surface.item.sample
            color: surface.isNew ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.Wrap
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: !surface.item ? "" : surface.isFailed
              ? (surface.item.description !== "" ? surface.item.description + " · " : "") + surface.item.scope + " · " + surface.item.sub
              : Model.problemMeta(surface.item, faults.now) + (surface.row.muted ? " · " + surface.item.unit : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
