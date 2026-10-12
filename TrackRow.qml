import QtQuick
import qs.Commons

// One song in a track table. Double-click (or the hover play glyph) plays it.
Rectangle {
  id: root

  property var item: ({})
  property int number: 0
  property bool showArt: true
  property bool showAlbum: true
  property bool current: false
  property bool playing: false
  property bool striped: false
  property string glyphFont: "monospace"
  property color accent: Color.accent
  property string durationText: ""

  signal play()
  signal menu(real x, real y)

  height: 48
  radius: 6
  color: hover.hovered ? Util.alpha(Color.foreground, 0.08) : (striped ? Util.alpha(Color.foreground, 0.03) : "transparent")

  HoverHandler { id: hover }
  TapHandler {
    acceptedButtons: Qt.LeftButton
    onDoubleTapped: root.play()
  }
  TapHandler {
    acceptedButtons: Qt.RightButton
    onTapped: function(ev) { root.menu(ev.position.x, ev.position.y) }
  }

  // number / art column
  Item {
    id: lead
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    width: root.showArt ? 36 : 26
    height: 36

    CoverArt {
      anchors.fill: parent
      visible: root.showArt
      radius: 4
      source: root.item.art || ""
      glyphFont: root.glyphFont
      crossfade: false
    }

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: Util.alpha(Color.background, 0.65)
      visible: root.showArt && (hover.hovered || root.current)
    }

    T {
      anchors.centerIn: parent
      visible: !root.showArt && !hover.hovered && !root.current
      text: root.number > 0 ? String(root.number) : ""
      secondary: true
      font.pixelSize: 12
    }

    Text {
      anchors.centerIn: parent
      visible: hover.hovered || root.current
      text: hover.hovered ? (root.current && root.playing ? "󰏤" : "󰐊") : (root.playing ? "󰝚" : "󰏤")
      color: hover.hovered ? Color.foreground : root.accent
      font.family: root.glyphFont
      font.pixelSize: 16
      TapHandler { onTapped: root.play() }
      HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
  }

  Row {
    anchors.left: lead.right
    anchors.leftMargin: 12
    anchors.right: dur.left
    anchors.rightMargin: 12
    anchors.verticalCenter: parent.verticalCenter
    spacing: 12

    readonly property real colW: root.showAlbum ? (width - spacing * 2) / 3 : (width - spacing) / 2

    Row {
      width: parent.colW
      spacing: 6
      T {
        width: Math.min(implicitWidth, parent.width - (explicitBadge.visible ? explicitBadge.width + 6 : 0))
        text: root.item.name || root.item.title || ""
        color: root.current ? root.accent : Color.foreground
      }
      Rectangle {
        id: explicitBadge
        visible: !!root.item.explicit
        width: 14; height: 14; radius: 3
        color: Util.alpha(Color.foreground, 0.45)
        anchors.verticalCenter: parent.verticalCenter
        Text { anchors.centerIn: parent; text: "E"; color: Color.background; font.pixelSize: 9; font.bold: true }
      }
    }
    T {
      width: parent.colW
      text: root.item.artist || ""
      secondary: true
    }
    T {
      width: parent.colW
      visible: root.showAlbum
      text: root.item.album || ""
      secondary: true
    }
  }

  T {
    id: dur
    anchors.right: parent.right
    anchors.rightMargin: 14
    anchors.verticalCenter: parent.verticalCenter
    width: 48
    horizontalAlignment: Text.AlignRight
    text: root.durationText
    secondary: true
    font.pixelSize: 12
  }
}
