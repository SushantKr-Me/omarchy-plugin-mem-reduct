import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mem Reduct: System memory monitor, pagecache drop & compaction,
// and live process manager allowing users to close any program directly to free RAM.
Panel {
  id: root
  moduleName: "sushantkr.mem-reduct"
  ipcTarget: "sushantkr.mem-reduct"

  readonly property color barFg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color barUrgent: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property color accentColor: Commons.Color.accent
  readonly property string barFont: root.bar ? root.bar.fontFamily : Style.font.family

  // Values in kB from /proc/meminfo
  property real memTotal: 0
  property real memAvailable: 0
  property real memFree: 0
  property real cached: 0
  property real buffers: 0
  property real slab: 0
  property real swapTotal: 0
  property real swapFree: 0

  property bool clearing: false
  property string status: ""
  property real availableBeforeClear: 0

  // Processes data from list-procs
  property var allProcs: []
  property var appProcs: []
  property var bgProcs: []
  property string currentTab: "all" // "all", "apps", "bg"
  property string searchQuery: ""
  property int killingPid: -1
  property string lastClosedName: ""
  property string lastClosedMem: ""

  // Ollama loaded models
  property var ollamaModels: []
  property bool ollamaReachable: false
  property string unloadingModel: ""

  readonly property real memUsed: Math.max(0, memTotal - memAvailable)
  readonly property real usedFraction: memTotal > 0 ? memUsed / memTotal : 0
  readonly property int usedPercent: Math.round(usedFraction * 100)
  readonly property real swapUsed: Math.max(0, swapTotal - swapFree)

  // Dynamic RAM usage icon reflecting current load
  readonly property string ramIcon: {
    var icons = ["󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥"]
    var idx = Math.min(7, Math.max(0, Math.floor(usedFraction * 8)))
    return icons[idx]
  }

  readonly property string cleanHelperPath: String(Qt.resolvedUrl("clean-ram")).replace(/^file:\/\//, "")
  readonly property string listHelperPath: String(Qt.resolvedUrl("list-procs")).replace(/^file:\/\//, "")
  readonly property string killHelperPath: String(Qt.resolvedUrl("kill-proc")).replace(/^file:\/\//, "")

  // Dynamic urgency color
  readonly property color usageColor: {
    if (usedFraction >= 0.90) return barUrgent
    if (usedFraction >= 0.75) return Qt.rgba(barUrgent.r * 0.85 + barFg.r * 0.15,
                                             barUrgent.g * 0.70 + barFg.g * 0.30,
                                             barUrgent.b * 0.50 + barFg.b * 0.50, 1.0)
    return barFg
  }

  function gb(kb) {
    var val = kb / 1024 / 1024
    return val >= 10 ? val.toFixed(1) + " GB" : val.toFixed(2) + " GB"
  }

  function mb(kb) {
    return Math.round(kb / 1024) + " MB"
  }

  function parseMeminfo(raw) {
    var values = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^(\w+):\s+(\d+)/)
      if (match) values[match[1]] = parseFloat(match[2])
    }
    if (!values.MemTotal) return
    memTotal = values.MemTotal
    memAvailable = values.MemAvailable || 0
    memFree = values.MemFree || 0
    cached = values.Cached || 0
    buffers = values.Buffers || 0
    slab = values.Slab || 0
    swapTotal = values.SwapTotal || 0
    swapFree = values.SwapFree || 0

    if (availableBeforeClear > 0) {
      var freed = memAvailable - availableBeforeClear
      status = freed > 0 ? "Cleaned " + gb(freed) : "Caches dropped & compacted"
      availableBeforeClear = 0
      statusResetTimer.restart()
    }
  }

  function parseProcs(raw) {
    try {
      var data = JSON.parse(raw)
      allProcs = data.all || []
      appProcs = data.apps || []
      bgProcs = data.background || []
    } catch (e) {
      // Keep existing data on parse hiccup
    }
  }

  function parseOllama(raw) {
    try {
      var models = JSON.parse(raw).models || []
      ollamaModels = models
      ollamaReachable = true
    } catch (e) {
      ollamaModels = []
      ollamaReachable = false
    }
  }

  function expiryLabel(expiresAt) {
    var when = Date.parse(String(expiresAt).replace(/(\.\d{3})\d+/, "$1"))
    if (!isFinite(when)) return ""
    var seconds = Math.round((when - Date.now()) / 1000)
    if (seconds > 365 * 24 * 3600) return "pinned"
    if (seconds <= 0) return "unloading"
    if (seconds < 60) return seconds + "s left"
    return Math.round(seconds / 60) + "m left"
  }

  function unloadModel(name) {
    if (unloadProc.running) return
    unloadingModel = name
    unloadProc.command = ["curl", "-s", "--max-time", "10", "http://127.0.0.1:11434/api/generate",
      "-d", JSON.stringify({ model: name, keep_alive: 0 })]
    unloadProc.running = true
  }

  function refresh() {
    if (!memProc.running) memProc.running = true
    if (opened && !ollamaProc.running) ollamaProc.running = true
  }

  function refreshProcs() {
    if (!procsProc.running) procsProc.running = true
  }

  function cleanRam() {
    if (clearing) return
    clearing = true
    status = "Cleaning RAM…"
    availableBeforeClear = memAvailable
    cleanProc.running = true
  }

  function closeProgram(procData) {
    if (killProc.running) return
    killingPid = procData.pid
    lastClosedName = procData.name
    lastClosedMem = procData.rss_label
    status = "Closing " + procData.name + "…"

    var args = [killHelperPath]
    var pids = procData.pids || [procData.pid]
    for (var i = 0; i < pids.length; i++) {
      args.push(String(pids[i]))
    }
    killProc.command = args
    killProc.running = true
  }

  function getDisplayList() {
    var base = allProcs
    if (currentTab === "apps") base = appProcs
    else if (currentTab === "bg") base = bgProcs

    var q = searchQuery.trim().toLowerCase()
    if (!q) return base

    var result = []
    for (var i = 0; i < base.length; i++) {
      var item = base[i]
      var matchName = item.name && item.name.toLowerCase().indexOf(q) !== -1
      var matchTitle = item.title && item.title.toLowerCase().indexOf(q) !== -1
      var matchClass = item.class && item.class.toLowerCase().indexOf(q) !== -1
      if (matchName || matchTitle || matchClass) {
        result.push(item)
      }
    }
    return result
  }

  Component.onCompleted: { refresh(); }
  onOpenedChanged: if (opened) {
    status = ""
    refresh()
    refreshProcs()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Meminfo processor
  Process {
    id: memProc
    command: ["cat", "/proc/meminfo"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseMeminfo(text) }
  }

  // Process list processor
  Process {
    id: procsProc
    command: [root.listHelperPath]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseProcs(text) }
  }

  // Ollama checker
  Process {
    id: ollamaProc
    command: ["curl", "-s", "--max-time", "1", "http://127.0.0.1:11434/api/ps"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseOllama(text) }
  }

  // Ollama model unloader
  Process {
    id: unloadProc
    onExited: {
      root.unloadingModel = ""
      root.refresh()
    }
  }

  // Memory cleaner (runs passwordless via sudo -n or pkexec fallback)
  Process {
    id: cleanProc
    command: ["sudo", "-n", "/usr/local/bin/mem-reduct-clean"]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.clearing = false
        root.refresh()
        root.refreshProcs()
      } else {
        pkCleanProc.running = true
      }
    }
  }

  Process {
    id: pkCleanProc
    command: ["pkexec", "/usr/local/bin/mem-reduct-clean"]
    onExited: function(exitCode) {
      root.clearing = false
      if (exitCode === 0) {
        root.refresh()
        root.refreshProcs()
      } else {
        root.availableBeforeClear = 0
        root.status = (exitCode === 126 || exitCode === 127) ? "Authorization cancelled" : "Clean failed"
        statusResetTimer.restart()
      }
    }
  }

  // Program closer
  Process {
    id: killProc
    onExited: function(exitCode) {
      root.killingPid = -1
      if (root.lastClosedName) {
        root.status = "Closed " + root.lastClosedName + " (Freed ~" + root.lastClosedMem + ")"
        root.statusResetTimer.restart()
      }
      root.refreshProcs()
      root.refresh()
    }
  }

  // Auto-refresh timers
  Timer { interval: root.opened ? 1500 : 5000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 2500; running: root.opened; repeat: true; onTriggered: root.refreshProcs() }

  // Status reset timer
  Timer {
    id: statusResetTimer
    interval: 4000
    onTriggered: {
      if (root.status.indexOf("Closed") === 0 || root.status.indexOf("Cleaned") === 0 || root.status.indexOf("Caches") === 0) {
        root.status = ""
      }
    }
  }

  // Bar icon button with standard memory icon and RAM usage percentage label
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    labelText: !vertical ? (root.usedPercent + "%") : ""
    slotSize: Style.bar.iconSlot * (!vertical ? 2 : 1)
    foreground: root.usageColor
    tooltipText: "RAM: " + root.gb(root.memUsed) + " / " + root.gb(root.memTotal) + " (" + root.usedPercent + "%)"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
      } else {
        root.toggle()
      }
    }
  }

  // Popover panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.cleanRam()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero Section (Mem Reduct style) ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            text: "󰍛"
            color: root.usageColor
            font.family: root.barFont
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Mem Reduct"
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.status ? root.status.toUpperCase() : (root.gb(root.memUsed) + " OF " + root.gb(root.memTotal)).toUpperCase()
              color: root.status ? root.barUrgent : Qt.darker(root.barFg, 1.4)
              font.family: root.barFont
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.usedPercent + "%"
            color: root.usageColor
            font.family: root.barFont
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Usage Progress Bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)
          }

          Rectangle {
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.usageColor
            width: Math.max(barTrack.height, barTrack.width * root.usedFraction)

            Behavior on width { NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Memory Breakdown Stats Grid ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(16)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              StatPair { label: "Physical Used"; value: root.gb(root.memUsed) }
              StatPair { label: "Available"; value: root.gb(root.memAvailable) }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              StatPair { label: "Cache & Buffers"; value: root.gb(root.cached + root.buffers + root.slab) }
              StatPair { label: "Page File (Swap)"; value: root.swapTotal > 0 ? root.gb(root.swapUsed) : "Off" }
            }
          }
        }

        // ---------- Clean RAM Action Button ----------
        Button {
          width: parent.width
          iconText: "󰃢"
          iconSize: Style.font.title
          text: root.clearing ? "Cleaning RAM…" : "Clean RAM"
          fontSize: Style.font.bodySmall
          foreground: root.barFg
          fontFamily: root.barFont
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          hasCursor: true
          tooltipText: "Drop pagecache, compact memory, and flush buffers (instant, passwordless)"
          onClicked: root.cleanRam()
        }

        // ---------- Ollama Section (if models loaded) ----------
        PanelSeparator {
          visible: root.ollamaReachable && root.ollamaModels.length > 0
          foreground: root.barFg
        }

        Column {
          visible: root.ollamaReachable && root.ollamaModels.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: "OLLAMA (LOADED IN VRAM/RAM)"
            foreground: root.barFg
            fontFamily: root.barFont
          }

          Repeater {
            model: root.ollamaModels
            Item {
              required property var modelData
              readonly property bool unloading: root.unloadingModel === modelData.name

              width: parent.width
              implicitHeight: Math.max(modelInfo.implicitHeight, unloadButton.implicitHeight)

              Column {
                id: modelInfo
                anchors.left: parent.left
                anchors.right: unloadButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: String(modelData.name).replace(/:latest$/, "")
                  color: root.barFg
                  font.family: root.barFont
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.gb(modelData.size / 1024) + " · " + (unloading ? "unloading" : root.expiryLabel(modelData.expires_at))
                  color: Qt.darker(root.barFg, 1.4)
                  font.family: root.barFont
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Button {
                id: unloadButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅙"
                iconSize: Style.font.body
                text: unloading ? "Unloading…" : "Unload"
                fontSize: Style.font.bodySmall
                foreground: root.barFg
                fontFamily: root.barFont
                bordered: true
                tooltipText: "Evict this model from memory (ollama stop)"
                onClicked: root.unloadModel(modelData.name)
              }
            }
          }
        }

        // ---------- Active Programs & Process Killer Header ----------
        PanelSeparator { foreground: root.barFg }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: headerTitle.implicitHeight

            PanelSectionHeader {
              id: headerTitle
              text: "RUNNING PROGRAMS & PROCESSES"
              foreground: root.barFg
              fontFamily: root.barFont
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            // Refresh button
            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              iconSize: Style.font.bodySmall
              fontSize: Style.font.caption
              tooltipText: "Rescan active processes"
              onClicked: root.refreshProcs()
            }
          }

          // Search Filter Field
          Item {
            width: parent.width
            implicitHeight: Style.space(28)

            Rectangle {
              anchors.fill: parent
              radius: Style.space(4)
              color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.08)
              border.width: 1
              border.color: filterInput.activeFocus ? root.accentColor : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.15)
            }

            Text {
              id: searchIcon
              text: "󰍉"
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              color: root.barFg
              opacity: 0.6
              font.pixelSize: Style.font.bodySmall
            }

            TextInput {
              id: filterInput
              anchors.left: searchIcon.right
              anchors.leftMargin: Style.space(6)
              anchors.right: clearSearchBtn.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.bodySmall
              clip: true
              onTextChanged: root.searchQuery = text

              Text {
                text: "Search programs to close…"
                color: Qt.darker(root.barFg, 1.6)
                font.family: root.barFont
                font.pixelSize: Style.font.bodySmall
                visible: !filterInput.text && !filterInput.activeFocus
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              id: clearSearchBtn
              text: "󰅖"
              visible: filterInput.text.length > 0
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              color: root.barFg
              opacity: 0.7
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { filterInput.text = ""; root.searchQuery = "" }
              }
            }
          }

          // Tab switch: All | Apps | Background
          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "All (" + root.allProcs.length + ")"
              fontSize: Style.font.caption
              selected: root.currentTab === "all"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              bordered: true
              onClicked: root.currentTab = "all"
            }

            Button {
              text: "Apps (" + root.appProcs.length + ")"
              fontSize: Style.font.caption
              selected: root.currentTab === "apps"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              bordered: true
              onClicked: root.currentTab = "apps"
            }

            Button {
              text: "Background (" + root.bgProcs.length + ")"
              fontSize: Style.font.caption
              selected: root.currentTab === "bg"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              bordered: true
              onClicked: root.currentTab = "bg"
            }
          }

          // Process List View (Scrollable, capped height)
          ListView {
            id: processList
            width: parent.width
            height: Math.min(contentHeight, Style.space(250))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.getDisplayList()

            delegate: Item {
              id: procItem
              required property var modelData
              required property int index
              readonly property bool isBeingKilled: Boolean(modelData && root.killingPid === modelData.pid)

              width: ListView.view.width
              implicitHeight: Style.space(38)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, procMouse.containsMouse ? 0.08 : 0.03)
              }

              MouseArea {
                id: procMouse
                anchors.fill: parent
                hoverEnabled: true
              }

              // Left: Icon + Name + Title
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: actionGroup.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: (modelData && modelData.is_window) ? "󰖲" : "󰍛"
                  color: (modelData && modelData.is_window) ? root.accentColor : root.barFg
                  opacity: 0.8
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  width: parent.width - Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Row {
                    spacing: Style.space(6)
                    Text {
                      textFormat: Text.PlainText
                      text: modelData ? modelData.name : ""
                      color: root.barFg
                      font.family: root.barFont
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                      maximumLineCount: 1
                    }
                    Text {
                      visible: Boolean(modelData && modelData.count > 1)
                      textFormat: Text.PlainText
                      text: modelData ? "(" + modelData.count + " procs)" : ""
                      color: root.barFg
                      opacity: 0.5
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData ? (modelData.title || (modelData.class ? modelData.class : "PID " + modelData.pid)) : ""
                    color: Qt.darker(root.barFg, 1.4)
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: parent.width
                  }
                }
              }

              // Right: RAM badge + Close / Protected button
              Row {
                id: actionGroup
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                // Memory pill
                Rectangle {
                  radius: Style.space(4)
                  height: Style.space(22)
                  width: memBadgeText.implicitWidth + Style.space(10)
                  color: (modelData && modelData.percent >= 8.0) ? Qt.rgba(root.barUrgent.r, root.barUrgent.g, root.barUrgent.b, 0.2) : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: memBadgeText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData ? modelData.rss_label : ""
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: (modelData && modelData.percent >= 8.0) ? root.barUrgent : root.barFg
                  }
                }

                // Action: Protected or Close button
                Item {
                  width: Style.space(62)
                  height: Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter

                  // Protected indicator
                  Row {
                    visible: Boolean(modelData && modelData.protected)
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: "󰌾"
                      color: root.barFg
                      opacity: 0.5
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: "System"
                      color: root.barFg
                      opacity: 0.5
                      font.pixelSize: Style.font.caption
                    }
                  }

                  // Close Program Button
                  Button {
                    visible: Boolean(modelData && !modelData.protected)
                    anchors.fill: parent
                    text: procItem.isBeingKilled ? "…" : "Close"
                    iconText: procItem.isBeingKilled ? "" : "󰅙"
                    fontSize: Style.font.caption
                    iconSize: Style.font.caption
                    foreground: root.barUrgent
                    bordered: true
                    tooltipText: modelData ? ("Close " + modelData.name + " to clean " + modelData.rss_label + " RAM") : ""
                    onClicked: if (modelData) root.closeProgram(modelData)
                  }
                }
              }
            }
          }

          // Empty state when search has no matches
          Text {
            visible: processList.count === 0
            textFormat: Text.PlainText
            text: "No matching programs found"
            color: Qt.darker(root.barFg, 1.4)
            font.family: root.barFont
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            topPadding: Style.space(10)
            bottomPadding: Style.space(10)
          }
        }
      }
    }
  }

  // Info pair component
  component StatPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.barFg
      opacity: 0.6
      font.family: root.barFont
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: value
      color: root.barFg
      font.family: root.barFont
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }
}
