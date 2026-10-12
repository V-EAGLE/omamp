import QtQuick
import qs.Commons

// Sidebar navigation entry: accent glyph or tiny artwork, plus a label.
Rectangle {
  id: si

  property string glyph: ""
  property string label: ""
  property string artUrl: ""
  property bool selected: false
  property color accent: Color.accent
  property string glyphFont: "monospace"

  signal activated()

  height: 30
  radius: 6
  color: selected ? Util.alpha(Color.foreground, 0.14) : (siHover.hovered ? Util.alpha(Color.foreground, 0.07) : "transparent")

  Text {
    visible: si.artUrl === ""
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    width: 18
    horizontalAlignment: Text.AlignHCenter
    text: si.glyph
    color: si.accent
    font.family: si.glyphFont
    font.pixelSize: 15
  }
  CoverArt {
    visible: si.artUrl !== ""
    anchors.left: parent.left
    anchors.leftMargin: 9
    anchors.verticalCenter: parent.verticalCenter
    width: 20
    height: 20
    radius: 3
    source: si.artUrl
    glyphFont: si.glyphFont
    crossfade: false
  }
  T {
    anchors.left: parent.left
    anchors.leftMargin: 38
    anchors.right: parent.right
    anchors.rightMargin: 8
    anchors.verticalCenter: parent.verticalCenter
    text: si.label
  }
  HoverHandler { id: siHover; cursorShape: Qt.PointingHandCursor }
  TapHandler { onTapped: si.activated() }
}
