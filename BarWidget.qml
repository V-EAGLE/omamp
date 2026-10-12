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
  function close() { popupOpen = false }

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
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasTrack ? root.am.title + " — " + root.am.artist : "OmAmp")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ------------------------------------------------------------ slim popup

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)

      // header
      Item {
        width: parent.width
        height: Math.max(headerLabel.implicitHeight, popBtn.implicitHeight)

        Text {
          id: headerLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "󰝚  OmAmp"
          color: root.dim
          font.family: root.iconFont
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Button {
            iconText: "󰖟"
            tooltipText: "Show web player"
            foreground: root.fg
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            visible: root.am && root.am.connected
            onClicked: { root.popupOpen = false; root.am.showWeb() }
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

      // not running / not signed in
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: !root.am || !root.am.connected || !root.am.authorized

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: root.fg
          font.family: root.iconFont
          font.pixelSize: Style.font.body
          text: !root.am || !root.am.connected
            ? (root.am && root.am.browser ? "Connecting to Apple Music…" : "Apple Music is not running.")
            : "Sign in to Apple Music in the web player."
        }

        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          text: !root.am || !root.am.connected ? "Start Apple Music" : "Sign in"
          bordered: true
          foreground: root.fg
          visible: !root.am || !root.am.browser || (root.am.connected && !root.am.authorized)
          onClicked: {
            if (!root.am) return
            if (!root.am.connected) root.am.launch(true)
            else { root.popupOpen = false; root.am.showWeb() }
          }
        }
      }

      // cover
      CoverArt {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.round(parent.width * 0.25)
        height: width
        visible: root.am && root.am.connected && root.am.authorized
        source: root.am ? root.am.artUrl : ""
        radius: Math.max(6, Style.cornerRadius)
        placeholderColor: Style.normalFillFor(root.fg, Color.accent)
        glyphColor: root.dim
        glyphFont: root.iconFont
      }

      // title / artist
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.am && root.am.connected && root.am.authorized

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
        visible: root.am && root.am.connected && root.am.authorized

        Timeline {
          id: timeline
          width: parent.width
          position: root.am ? root.am.livePosition : 0
          duration: root.am ? root.am.duration : 0
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
        visible: root.am && root.am.connected && root.am.authorized

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒟"
          tooltipText: "Shuffle"
          foreground: root.am && root.am.shuffle ? Color.accent : root.dim
          onClicked: root.am.setShuffle(root.am.shuffle ? 0 : 1)
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒮"
          foreground: root.fg
          iconSize: Style.font.iconLarge
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
          onClicked: root.am.next()
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.am && root.am.repeat === 1 ? "󰑘" : "󰑖"
          tooltipText: "Repeat"
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
        width: parent.width
        height: contentHeight
        interactive: false
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        model: root.am && root.am.connected ? root.am.upNext.slice(0, 3) : []
        visible: count > 0

        delegate: Rectangle {
          id: rowItem
          required property var modelData
          width: upNextList.width
          height: Style.space(34)
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
