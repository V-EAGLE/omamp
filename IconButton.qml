import QtQuick
import qs.Commons

// Round glyph button used throughout the pop-out player.
Item {
  id: root

  property string glyph: ""
  property string glyphFont: "monospace"
  property real size: 32
  property real glyphSize: size * 0.55
  property color color: Color.foreground
  property color activeColor: Color.accent
  property bool active: false
  property bool filled: false
  property color fillColor: Color.accent
  property string tooltip: ""

  signal clicked()

  implicitWidth: size
  implicitHeight: size
  opacity: enabled ? 1 : 0.35

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.filled ? root.fillColor : (hover.hovered ? Util.alpha(Color.foreground, 0.1) : "transparent")
    scale: tap.pressed ? 0.92 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }
  }

  Text {
    anchors.centerIn: parent
    text: root.glyph
    color: root.filled ? Color.background : (root.active ? root.activeColor : root.color)
    font.family: root.glyphFont
    font.pixelSize: root.glyphSize
    scale: tap.pressed ? 0.92 : 1
  }

  HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
  TapHandler { id: tap; onTapped: root.clicked() }
}
