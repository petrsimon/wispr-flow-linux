import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget and popup for Wispr Flow. Everything it does goes through the
// app's deep-link routes, so the panel needs no privileged access and no
// window of Wispr's own -- the status bubble can stay hidden.
Panel {
  id: root
  moduleName: "wispr.flow"
  ipcTarget: "wispr.flow"

  // The bar sizes each widget slot from the plugin root's implicit size, so
  // the root has to carry the button's -- an Item with anchored children has
  // none of its own and the slot collapses to nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The helper lives beside this file, so the plugin works from wherever it
  // was installed without the path being configured anywhere.
  readonly property string helper: Qt.resolvedUrl("wispr-state").toString().replace(/^file:\/\//, "")
  readonly property string languages: String(root.setting("languages", "en"))

  property bool appRunning: false
  property string dictation: ""
  property var devices: []
  property var langs: []
  property bool autoLanguage: false

  readonly property bool busy: dictation === "listening" || dictation === "initializing"
      || dictation === "stopping" || dictation === "processing"
  readonly property bool dictating: dictation === "listening" || dictation === "initializing"
  readonly property string stateLabel: {
    if (!appRunning) return "Not running"
    if (dictation === "listening") return "Listening"
    if (dictation === "initializing") return "Starting"
    if (dictation === "stopping" || dictation === "processing") return "Transcribing"
    return "Idle"
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  // One flat cursor over every actionable row, so j/k walks the panel in the
  // order it reads: the dictation button, then microphones, then languages.
  property int cursor: 0
  property bool cursorActive: false
  readonly property var rows: {
    var list = [{ kind: "dictation" }]
    for (var d = 0; d < devices.length; d++) list.push({ kind: "device", index: d })
    list.push({ kind: "auto" })
    for (var l = 0; l < langs.length; l++) list.push({ kind: "language", index: l })
    return list
  }

  function isRow(kind, index) {
    if (!cursorActive || cursor < 0 || cursor >= rows.length) return false
    var row = rows[cursor]
    return row.kind === kind && (index === undefined || row.index === index)
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    cursor = (cursor + delta + rows.length) % rows.length
  }

  function activate() {
    if (cursor < 0 || cursor >= rows.length) return
    var row = rows[cursor]
    if (row.kind === "dictation") toggleDictation()
    else if (row.kind === "device") selectDevice(devices[row.index])
    else if (row.kind === "auto") setLanguage(languages)
    else if (row.kind === "language") setLanguage(langs[row.index].code)
  }

  // ---------------------------------------------------------------- actions

  function deeplink(route) {
    actionProcess.command = ["wispr-flow", "wispr-flow://" + route]
    actionProcess.running = true
    // The app takes a moment to move; re-read once it has.
    settleTimer.restart()
  }

  function toggleDictation() {
    deeplink(dictating ? "stop-hands-free" : "start-hands-free")
  }

  function selectDevice(device) {
    if (!device || device.selected) return
    deeplink("switch-mic?mic_name=" + encodeURIComponent(device.name))
  }

  function setLanguage(codes) {
    deeplink("set-language?lang=" + encodeURIComponent(codes))
  }

  // ---------------------------------------------------------------- polling

  function refresh() {
    if (stateProcess.running) return
    stateProcess.command = [root.helper, root.languages]
    stateProcess.running = true
  }

  function applyState(text) {
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      return
    }
    appRunning = parsed.running === true
    dictation = String(parsed.state || "")
    devices = parsed.devices instanceof Array ? parsed.devices : []
    langs = parsed.languages instanceof Array ? parsed.languages : []
    autoLanguage = parsed.auto === true
    if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)
  }

  Process {
    id: stateProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: stateStdout
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
  }

  // Fast while the panel is open or a dictation is in flight, lazy otherwise:
  // the helper shells out to grep and jq, and the bar should not pay for that
  // every second when nothing is happening.
  Timer {
    interval: root.opened || root.busy ? 1000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursor = 0
      refresh()
    }
  }

  // -------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.appRunning ? (root.busy ? "󰔟" : "󰍬") : "󰍭"
    active: root.dictating
    tooltipText: root.appRunning ? "Wispr Flow · " + root.stateLabel : "Wispr Flow not running"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.toggleDictation()
      else if (mouseButton === Qt.MiddleButton) root.deeplink("open")
      else root.toggle()
    }
  }

  // -------------------------------------------------------------- the popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.appRunning ? "󰍬" : "󰍭"
              color: root.dictating ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Wispr Flow"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.stateLabel
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Dictation ----------
          Button {
            width: parent.width
            text: root.dictating ? "Stop dictation" : "Start dictation"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            active: root.dictating
            hasCursor: root.isRow("dictation")
            enabled: root.appRunning
            opacity: root.appRunning ? 1.0 : 0.45
            onClicked: root.toggleDictation()
            onHovered: function(isHovered) {
              if (!isHovered) return
              root.cursorActive = true
              root.cursor = 0
            }
          }

          // ---------- Microphone ----------
          PanelSeparator { width: parent.width }

          PanelSectionHeader {
            text: "Microphone"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.devices
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              width: panelColumn.width
              label: modelData.name
              glyph: "󰍬"
              chosen: modelData.selected
              rowKind: "device"
              rowIndex: index
              onActivated: root.selectDevice(modelData)
            }
          }

          Text {
            visible: root.devices.length === 0
            text: root.appRunning ? "No devices reported yet" : "Start Wispr Flow to list devices"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            width: parent.width
            elide: Text.ElideRight
          }

          // ---------- Language ----------
          PanelSeparator { width: parent.width }

          PanelSectionHeader {
            text: "Language"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ChoiceRow {
            width: panelColumn.width
            label: "Detect automatically"
            glyph: "󰗊"
            chosen: root.autoLanguage
            rowKind: "auto"
            rowIndex: -1
            onActivated: root.setLanguage(root.languages)
          }

          Repeater {
            model: root.langs
            delegate: ChoiceRow {
              required property var modelData
              required property int index
              width: panelColumn.width
              label: modelData.name
              glyph: "󰗊"
              chosen: modelData.selected
              rowKind: "language"
              rowIndex: index
              onActivated: root.setLanguage(modelData.code)
            }
          }

          // ---------- Hub ----------
          PanelSeparator { width: parent.width }

          Button {
            width: parent.width
            text: "Open Flow Hub"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: { root.deeplink("open"); root.close() }
          }
        }
      }
    }
  }

  // A selectable row: glyph, label, and a check when it is the current choice.
  component ChoiceRow: CursorSurface {
    id: choiceRow
    property string label: ""
    property string glyph: ""
    property bool chosen: false
    property string rowKind: ""
    property int rowIndex: -1
    signal activated()

    hasCursor: root.isRow(rowKind, rowIndex < 0 ? undefined : rowIndex)
    current: chosen
    foreground: root.foreground
    fill: Style.hoverFillFor(root.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.foreground, Color.accent)
    implicitHeight: rowInner.implicitHeight + Style.spacing.xl

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: choiceRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: choiceRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: choiceRow.chosen ? "󰄬" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        for (var i = 0; i < root.rows.length; i++) {
          var candidate = root.rows[i]
          if (candidate.kind !== choiceRow.rowKind) continue
          if (choiceRow.rowIndex >= 0 && candidate.index !== choiceRow.rowIndex) continue
          root.cursor = i
          break
        }
      }
      onClicked: choiceRow.activated()
    }
  }
}
