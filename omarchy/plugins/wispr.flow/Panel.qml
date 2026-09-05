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

  // Omarchy's own dictation UI (voxtype) surfaces as an indicator rather than a
  // permanent icon, and a second microphone in the bar reads as a duplicate. So
  // the icon is optional: hidden, the widget keeps a zero-width slot and the
  // panel stays reachable over IPC (`omarchy-shell wispr.flow toggle`), which
  // is what a keybinding calls.
  readonly property bool showIcon: root.setting("showIcon", true) === true

  // The bar sizes each widget slot from the plugin root's implicit size, so
  // the root has to carry the button's -- an Item with anchored children has
  // none of its own and the slot collapses to nothing.
  implicitWidth: showIcon ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // The helper lives beside this file, so the plugin works from wherever it
  // was installed without the path being configured anywhere.
  readonly property string helper: Qt.resolvedUrl("wispr-state").toString().replace(/^file:\/\//, "")
  readonly property string languages: String(root.setting("languages", "en"))

  property bool appRunning: false
  property string dictation: ""
  property var langs: []
  property bool autoLanguage: false
  property string device: ""
  property string systemDevice: ""
  property bool overridden: false

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

  readonly property string languageLabel: {
    if (autoLanguage) return "Auto"
    for (var i = 0; i < langs.length; i++)
      if (langs[i].selected) return langs[i].name
    return ""
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  // One flat cursor over every actionable row, so j/k walks the panel in the
  // order it reads: the dictation button, then microphones, then languages.
  property int cursor: 0
  property bool cursorActive: false
  readonly property var rows: {
    var list = [{ kind: "auto" }]
    for (var l = 0; l < langs.length; l++) list.push({ kind: "language", index: l })
    list.push({ kind: "dictation" })
    if (overridden) list.push({ kind: "release" })
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
    else if (row.kind === "auto") setLanguage(languages)
    else if (row.kind === "language") setLanguage(langs[row.index].code)
    else if (row.kind === "release") releaseDevice()
  }

  // ---------------------------------------------------------------- actions

  function deeplink(route) {
    actionProcess.command = ["wispr-flow", "wispr-flow://" + route]
    actionProcess.running = true
    // The app takes a moment to move; re-read once it has.
    settleTimer.restart()
  }

  // Dictation has to be driven with the panel shut. The panel takes keyboard
  // focus while it is open, so Wispr would record it as the active app at
  // start and synthesize the paste keystroke into it at stop -- the transcript
  // reaches the clipboard and nothing else. Closing first hands focus back to
  // the window the text is meant for; the small delay lets the compositor
  // finish that handover before Wispr looks.
  function toggleDictation() {
    var route = dictating ? "stop-hands-free" : "start-hands-free"
    if (opened) {
      close()
      pendingRoute = route
      focusHandoffTimer.restart()
    } else {
      deeplink(route)
    }
  }

  // Hand the microphone back to the system. Wispr's device setting is an
  // override; on its "default" entry the app follows whatever PipeWire is
  // capturing from, which the Omarchy audio panel owns along with input volume
  // and mute. This panel offers no picker of its own -- only the way out.
  function releaseDevice() {
    if (!overridden || systemDevice === "") return
    deeplink("switch-mic?mic_name=" + encodeURIComponent(systemDevice))
  }

  // Through the helper rather than straight to the deep link: it records the
  // choice next to the app's config, which Wispr only flushes later, so the
  // panel reflects a switch immediately instead of minutes afterwards.
  function setLanguage(codes) {
    actionProcess.command = [root.helper, "--set-language", codes]
    actionProcess.running = true
    settleTimer.restart()
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
    langs = parsed.languages instanceof Array ? parsed.languages : []
    autoLanguage = parsed.auto === true
    device = String(parsed.device || "")
    systemDevice = String(parsed.systemDevice || "")
    overridden = parsed.overridden === true
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

  property string pendingRoute: ""

  Timer {
    id: focusHandoffTimer
    interval: 150
    repeat: false
    onTriggered: {
      if (root.pendingRoute === "") return
      root.deeplink(root.pendingRoute)
      root.pendingRoute = ""
    }
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
    visible: root.showIcon
    // The same glyphs Omarchy's own Dictation indicator uses, so dictation looks
    // like dictation wherever it surfaces. Absence is shown by dimming rather
    // than a mic-off glyph, which would read as "muted".
    text: root.busy && !root.dictating ? "󰔟" : "󰍬"
    active: root.dictating
    dimmed: !root.appRunning
    tooltipText: {
      if (!root.appRunning) return "Wispr Flow not running"
      var tip = "Wispr Flow · " + root.stateLabel
      if (root.languageLabel !== "") tip += " · " + root.languageLabel
      return tip
    }
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

          // ---------- Header: one line, since the bar icon already carries
          // the state and repeating it here just spends the top third ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabel.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰍬"
              color: root.dictating ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: heroLabel
              textFormat: Text.PlainText
              text: "Wispr Flow · " + root.stateLabel
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ---------- Language: the one setting that lives nowhere else ------
          PanelSeparator { width: parent.width }

          PanelSectionHeader {
            text: "Language"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ChoiceRow {
            width: panelColumn.width
            label: "Detect automatically"
            glyph: "󰗋"
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
              glyph: "󰗋"
              chosen: modelData.selected
              rowKind: "language"
              rowIndex: index
              onActivated: root.setLanguage(modelData.code)
            }
          }

          // ---------- Dictation: a convenience; right-clicking the bar icon
          // does the same thing without opening anything ----------
          PanelSeparator { width: parent.width }

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
              for (var i = 0; i < root.rows.length; i++) {
                if (root.rows[i].kind === "dictation") { root.cursor = i; break }
              }
            }
          }

          // ---------- Microphone: only when Wispr is overriding the system ---
          // Choosing the input device is the audio panel's job. All this shows
          // is when Wispr has been pinned to something else, and how to undo it.
          ChoiceRow {
            visible: root.overridden
            width: panelColumn.width
            label: "Release " + root.device
            glyph: "󰍬"
            chosen: false
            rowKind: "release"
            rowIndex: -1
            onActivated: root.releaseDevice()
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
