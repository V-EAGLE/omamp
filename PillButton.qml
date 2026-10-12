import QtQuick
import qs.Commons

// Apple Music style "Play" / "Shuffle" pill.
Rectangle {
  id: root

  property string glyph: ""
  property string label: ""
  property string glyphFont: "monospace"
  property color accent: Color.accent

  signal clicked()

  implicitWidth: row.implicitWidth + 36
  implicitHeight: 32
  radius: 8
  color: hover.hovered ? Qt.lighter(accent, 1.12) : accent
  scale: tap.pressed ? 0.96 : 1
  Behavior on scale { NumberAnimation { duration: 90 } }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyph
      color: Color.background
      font.family: root.glyphFont
      font.pixelSize: 15
    }
    T {
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: Color.background
      font.pixelSize: 13
      font.weight: Font.DemiBold
    }
  }

  HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
  TapHandler { id: tap; onTapped: root.clicked() }
}
