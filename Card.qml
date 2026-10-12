import QtQuick
import qs.Commons
import Quickshell.Widgets

// Album / playlist / artist tile. Clicking opens it; the hover play button
// starts playback directly.
Item {
  id: root

  property var item: ({})
  property string glyphFont: "monospace"
  property color accent: Color.accent
  readonly property bool isArtist: (item.type || "").indexOf("artist") !== -1
  readonly property bool canPlay: !isArtist && (item.playable || (item.type || "").indexOf("playlist") !== -1)

  signal open(var item)
  signal play(var item)
  signal menu(var item, real x, real y)

  implicitHeight: art.height + 8 + titleLabel.implicitHeight + (subLabel.visible ? subLabel.implicitHeight : 0) + 6

  CoverArt {
    id: art
    width: parent.width
    height: width
    radius: root.isArtist ? width / 2 : 8
    source: root.item.art || ""
    glyph: root.isArtist ? "󰠃" : ((root.item.type || "").indexOf("playlist") !== -1 ? "󰲸" : "󰀥")
    glyphFont: root.glyphFont
    placeholderColor: Util.alpha(Color.foreground, 0.08)
    glyphColor: Util.alpha(Color.foreground, 0.4)

    Rectangle {
      anchors.fill: parent
      color: Color.background
      opacity: hover.hovered ? 0.25 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    IconButton {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.margins: 10
      size: 34
      glyph: "󰐊"
      glyphFont: root.glyphFont
      filled: true
      fillColor: root.accent
      visible: hover.hovered && root.canPlay
      onClicked: root.play(root.item)
    }
  }

  T {
    id: titleLabel
    anchors.top: art.bottom
    anchors.topMargin: 8
    width: parent.width
    text: root.item.name || ""
    font.pixelSize: 13
    horizontalAlignment: root.isArtist ? Text.AlignHCenter : Text.AlignLeft
  }

  T {
    id: subLabel
    anchors.top: titleLabel.bottom
    width: parent.width
    secondary: true
    text: root.item.artist || ""
    font.pixelSize: 12
    visible: text !== "" && !root.isArtist
  }

  HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
  TapHandler {
    gesturePolicy: TapHandler.ReleaseWithinBounds
    onTapped: root.open(root.item)
  }
  TapHandler {
    acceptedButtons: Qt.RightButton
    onTapped: function(ev) { root.menu(root.item, ev.position.x, ev.position.y) }
  }
}
