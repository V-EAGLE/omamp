import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.v-eagle.omamp"

  readonly property var am: bar && bar.shell ? bar.shell.serviceFor("io.github.v-eagle.omamp") : null
  readonly property bool hasTrack: am ? am.hasTrack : false
  readonly property bool isPlaying: am ? am.playing : false
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string iconFont: bar ? bar.fontFamily : Style.font.family
  readonly property real maxLabelWidth: setting("maxLabelWidth", 180)

  property bool popupOpen: false
  property bool sourceMenuOpen: false
  function close() { popupOpen = false; sourceMenuOpen = false }

  // Apple Music can be switched off per widget (`appleMusic` setting).
  Binding {
    target: root.am
    property: "appleEnabled"
    value: root.setting("appleMusic", true) !== false
    when: root.am !== null
  }

  readonly property bool appleConnecting: am ? (am.isApple && am.appleEnabled && am.browser && !am.connected) : false
  readonly property bool appleSignIn: am ? (am.isApple && am.connected && !am.authorized) : false
  readonly property bool showPlayer: am ? (am.hasTrack || (am.isApple && am.appleLive)) : false

  function popOut() {
    popupOpen = false
    if (bar && bar.shell) bar.shell.summon("io.github.v-eagle.omamp", "{}")
  }

  // `omarchy-shell omamp togglePopup` / `openPlayer` (bindable from Hyprland).
  // One instance owns the target, so the popup opens on that bar's monitor.
  IpcHandler {
    target: "omamp"
    function togglePopup(): void { root.popupOpen = !root.popupOpen }
    function openPlayer(): void { root.popOut() }
    function playPause(): void { if (root.am) root.am.playPause() }
    function next(): void { if (root.am) root.am.next() }
    function previous(): void { if (root.am) root.am.previous() }
    function seekBy(seconds: string): void { if (root.am) root.am.seek(root.am.livePosition + Number(seconds)) }
  }

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.hasTrack ? (root.isPlaying ? "󰝚" : "󰏤") : "󰝚"
      color: root.isPlaying ? (root.bar ? root.bar.barForeground : root.fg) : root.dim
      font.family: root.iconFont
      font.pixelSize: Style.font.body
    }

    Item {
      id: clip
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(root.maxLabelWidth, label.implicitWidth)
      height: glyph.height
      clip: true
      visible: !root.vertical && root.hasTrack && root.maxLabelWidth > 0

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.am ? root.am.title + (root.am.artist ? "  ·  " + root.am.artist : "") : ""
        color: root.bar ? root.bar.barForeground : root.fg
        font.family: root.iconFont
        font.pixelSize: Style.font.body

        readonly property bool needsScroll: implicitWidth > clip.width
        NumberAnimation on x {
          running: label.needsScroll && root.isPlaying && !root.popupOpen
          onRunningChanged: if (!running) label.x = 0
          loops: Animation.Infinite
          duration: Math.max(6000, label.implicitWidth * 25)
          from: clip.width
          to: -label.implicitWidth
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (!root.am) return
      if (mouse.button === Qt.MiddleButton) root.am.playPause()
      else if (mouse.button === Qt.RightButton) root.popOut()
      else root.popupOpen = !root.popupOpen
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasTrack ? root.am.title + " — " + root.am.artist + "  (" + root.am.sourceName + ")" : "OmAmp")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ------------------------------------------------------------ slim popup

  // KeyboardPanel (not PopupCard) so the popup also takes keyboard input.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)
    focusTarget: content

    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)
      focus: true

      // ↑/↓ PgUp/PgDn Home/End scroll Up Next, Space plays/pauses, Esc closes.
      Keys.onPressed: function(event) {
        var k = event.key
        if (k === Qt.Key_Escape) root.close()
        else if (k === Qt.Key_Space && root.am) root.am.playPause()
        else if (k === Qt.Key_Up) upNextList.scrollRows(-1)
        else if (k === Qt.Key_Down) upNextList.scrollRows(1)
        else if (k === Qt.Key_PageUp) upNextList.scrollRows(-upNextList.visibleRows)
        else if (k === Qt.Key_PageDown) upNextList.scrollRows(upNextList.visibleRows)
        else if (k === Qt.Key_Home) upNextList.positionViewAtBeginning()
        else if (k === Qt.Key_End) upNextList.positionViewAtEnd()
        else return
        event.accepted = true
      }

      // header: active source (click to switch) + actions
      Item {
        width: parent.width
        height: Math.max(sourceButton.implicitHeight, popBtn.implicitHeight)

        Rectangle {
          id: sourceButton
          readonly property bool switchable: root.am && root.am.sources.length > 1
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: headerLabel.implicitWidth + Style.space(12)
          implicitHeight: headerLabel.implicitHeight + Style.space(6)
          radius: Style.spacing.labelGap
          color: switchable && headerHover.hovered ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

          Text {
            id: headerLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: (root.am ? root.am.sourceGlyph + "  " + root.am.sourceName : "󰝚  OmAmp")
              + (sourceButton.switchable ? (root.sourceMenuOpen ? "  󰅃" : "  󰅀") : "")
            color: root.dim
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
          }

          HoverHandler { id: headerHover; cursorShape: sourceButton.switchable ? Qt.PointingHandCursor : Qt.ArrowCursor }
          TapHandler { onTapped: if (sourceButton.switchable) root.sourceMenuOpen = !root.sourceMenuOpen }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Button {
            iconText: "󰖟"
            tooltipText: root.am && root.am.isApple ? "Show web player" : "Show player"
            foreground: root.fg
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            visible: root.am && root.am.canShowSource
            onClicked: { root.close(); root.am.showSource() }
          }

          Button {
            id: popBtn
            iconText: "󰁌"
            tooltipText: "Pop out"
            foreground: root.fg
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            onClicked: root.popOut()
          }
        }
      }

      // source picker
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.sourceMenuOpen

        Repeater {
          model: root.am ? root.am.sources : []

          Rectangle {
            id: srcRow
            required property var modelData
            readonly property bool selected: root.am && root.am.activeKey === modelData.key
            width: parent.width
            height: Style.space(36)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.fg, Color.accent)
              : (srcHover.hovered ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")

            HoverHandler { id: srcHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: { root.am.selectSource(srcRow.modelData.key); root.sourceMenuOpen = false } }

            Text {
              id: srcGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: srcRow.modelData.glyph
              color: srcRow.modelData.playing ? Color.accent : root.fg
              font.family: root.iconFont
              font.pixelSize: Style.font.body
            }

            Column {
              anchors.left: srcGlyph.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: srcRow.modelData.name + (srcRow.modelData.playing ? "  󰝚" : "")
                color: root.fg
                font.family: root.iconFont
                font.pixelSize: Style.font.bodySmall
                font.bold: srcRow.selected
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: srcRow.modelData.title + (srcRow.modelData.artist ? " — " + srcRow.modelData.artist : "")
                color: root.dim
                font.family: root.iconFont
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                visible: text !== ""
              }
            }
          }
        }

        PanelSeparator { foreground: root.fg }
      }

      // Apple: connecting / sign-in
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.appleConnecting || root.appleSignIn

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: root.fg
          font.family: root.iconFont
          font.pixelSize: Style.font.body
          text: root.appleSignIn ? "Sign in to Apple Music in the web player." : "Connecting to Apple Music…"
        }

        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Sign in"
          bordered: true
          foreground: root.fg
          visible: root.appleSignIn
          onClicked: { root.close(); root.am.showWeb() }
        }
      }

      // nothing playing: open a service
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: !root.showPlayer && !root.appleConnecting && !root.appleSignIn

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          color: root.fg
          font.family: root.iconFont
          font.pixelSize: Style.font.body
          text: "Nothing playing"
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.iconFont
          font.pixelSize: Style.font.caption
          text: "Start music in any player, or open a service:"
        }

        Flow {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.am ? root.am.launchers.filter(function(l) { return l.visible !== false }) : []

            Button {
              required property var modelData
              text: modelData.glyph + "  " + modelData.name
              bordered: true
              foreground: root.fg
              horizontalPadding: Style.spacing.md
              verticalPadding: Style.spacing.xs
              onClicked: { root.am.openService(modelData.key); if (modelData.key !== "apple") root.close() }
            }
          }
        }
      }

      // cover
      CoverArt {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.round(parent.width * 0.25)
        height: width
        visible: root.showPlayer
        source: root.am ? root.am.artUrl : ""
        glyph: root.am ? root.am.sourceGlyph : "󰝚"
        radius: Math.max(6, Style.cornerRadius)
        placeholderColor: Style.normalFillFor(root.fg, Color.accent)
        glyphColor: root.dim
        glyphFont: root.iconFont
      }

      // title / artist
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.showPlayer

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.hasTrack ? root.am.title : "Not Playing"
          color: root.fg
          font.family: root.iconFont
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.hasTrack ? root.am.artist + (root.am.album ? " — " + root.am.album : "") : ""
          color: root.dim
          font.family: root.iconFont
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
          visible: text !== ""
        }
      }

      Text {
        width: parent.width
        visible: root.am && root.am.previewOnly
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        text: "Previews only until the DRM module (Widevine) is ready. The web player restarts automatically once it has downloaded."
        color: Color.urgent
        font.family: root.iconFont
        font.pixelSize: Style.font.caption
      }

      // timeline
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.showPlayer && root.am.duration > 0

        Timeline {
          id: timeline
          width: parent.width
          position: root.am ? root.am.livePosition : 0
          duration: root.am ? root.am.duration : 0
          seekable: root.am ? root.am.canSeek : false
          trackColor: Style.selectedFillFor(root.fg, Color.accent)
          fillColor: root.fg
          onSeekRequested: function(t) { root.am.seek(t) }
        }

        Item {
          width: parent.width
          height: elapsed.implicitHeight

          Text {
            id: elapsed
            anchors.left: parent.left
            text: root.am ? root.am.formatTime(timeline.shownPosition) : "0:00"
            color: root.dim
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            text: root.am ? "-" + root.am.formatTime(Math.max(0, root.am.duration - timeline.shownPosition)) : "-0:00"
            color: root.dim
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
          }
        }
      }

      // controls
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: root.showPlayer

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒟"
          tooltipText: "Shuffle"
          visible: root.am && root.am.canShuffle
          foreground: root.am && root.am.shuffle ? Color.accent : root.dim
          onClicked: root.am.setShuffle(root.am.shuffle ? 0 : 1)
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒮"
          foreground: root.fg
          iconSize: Style.font.iconLarge
          enabled: root.am && root.am.canPrevious
          opacity: enabled ? 1 : 0.4
          onClicked: root.am.previous()
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          foreground: root.fg
          iconSize: Math.round(Style.font.iconLarge * 1.5)
          horizontalPadding: Style.spacing.panelGap
          onClicked: root.am.playPause()
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒭"
          foreground: root.fg
          iconSize: Style.font.iconLarge
          enabled: root.am && root.am.canNext
          opacity: enabled ? 1 : 0.4
          onClicked: root.am.next()
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.am && root.am.repeat === 1 ? "󰑘" : "󰑖"
          tooltipText: "Repeat"
          visible: root.am && root.am.canRepeat
          foreground: root.am && root.am.repeat ? Color.accent : root.dim
          onClicked: root.am.cycleRepeat()
        }
      }

      // up next
      PanelSeparator {
        foreground: root.fg
        visible: upNextList.count > 0
      }

      Text {
        text: "Up Next"
        color: root.fg
        font.family: root.iconFont
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        visible: upNextList.count > 0
      }

      ListView {
        id: upNextList
        // Three rows tall; the rest of the queue scrolls (wheel, scrollbar,
        // or ↑/↓, PgUp/PgDn, Home/End while the popup is open).
        readonly property real rowHeight: Style.space(34)
        readonly property real rowStep: rowHeight + spacing
        readonly property int visibleRows: 3
        width: parent.width
        height: Math.min(count, visibleRows) * rowHeight + Math.max(0, Math.min(count, visibleRows) - 1) * spacing
        interactive: count > visibleRows
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        snapMode: ListView.SnapToItem
        model: root.am && root.am.hasQueue ? root.am.upNext : []
        visible: count > 0
        ScrollBar.vertical: ScrollBar {
          policy: upNextList.count > upNextList.visibleRows ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        function scrollRows(n) {
          var maxY = Math.max(0, contentHeight - height)
          contentY = Math.max(0, Math.min(maxY, contentY + n * rowStep))
        }

        // Start at the next song whenever the popup opens or the track changes.
        Connections {
          target: root
          function onPopupOpenChanged() {
            if (root.popupOpen) upNextList.positionViewAtBeginning()
          }
        }
        Connections {
          target: root.am
          function onQueuePositionChanged() { upNextList.positionViewAtBeginning() }
        }

        delegate: Rectangle {
          id: rowItem
          required property var modelData
          width: upNextList.width
          height: upNextList.rowHeight
          radius: Style.spacing.labelGap
          color: rowHover.hovered ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

          HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.am.jump(rowItem.modelData.index) }

          CoverArt {
            id: thumb
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            height: width
            radius: 4
            source: rowItem.modelData.art || ""
            placeholderColor: Style.normalFillFor(root.fg, Color.accent)
            glyphColor: root.dim
            glyphFont: root.iconFont
            crossfade: false
          }

          Column {
            anchors.left: thumb.right
            anchors.leftMargin: Style.space(8)
            anchors.right: dur.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: rowItem.modelData.title
              color: root.fg
              font.family: root.iconFont
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: rowItem.modelData.artist
              color: root.dim
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: dur
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.am ? root.am.formatTime(rowItem.modelData.duration) : ""
            color: root.dim
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
