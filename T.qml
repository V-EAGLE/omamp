import QtQuick
import qs.Commons

// Plain-text label with the pop-out player's typography. Data from the API is
// never interpreted as rich text.
Text {
  property bool secondary: false
  textFormat: Text.PlainText
  color: secondary ? Util.alpha(Color.foreground, 0.6) : Color.foreground
  font.family: "Noto Sans"
  font.pixelSize: 13
  elide: Text.ElideRight
  verticalAlignment: Text.AlignVCenter
}
