import QtQuick
import qs.Commons
import Quickshell.Widgets

// Rounded artwork with a music-note placeholder while loading or missing.
ClippingRectangle {
  id: root

  property string source: ""
  // Artwork URLs come from any MPRIS player; only load ordinary image URLs.
  readonly property string safeSource: /^(https?|file):\/\//i.test(source) ? source : ""
  property color placeholderColor: Util.alpha(Color.foreground, 0.08)
  property color glyphColor: Util.alpha(Color.foreground, 0.45)
  property string glyphFont: "monospace"
  property string glyph: "󰝚"
  property bool crossfade: true

  color: placeholderColor
  radius: 6

  Text {
    anchors.centerIn: parent
    visible: img.status !== Image.Ready
    text: root.glyph
    color: root.glyphColor
    font.family: root.glyphFont
    font.pixelSize: Math.max(10, Math.min(root.width, root.height) * 0.38)
  }

  Image {
    id: img
    anchors.fill: parent
    source: root.safeSource
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    sourceSize.width: Math.ceil(root.width * 2)
    sourceSize.height: Math.ceil(root.height * 2)
    opacity: status === Image.Ready ? 1 : 0
    Behavior on opacity {
      enabled: root.crossfade
      NumberAnimation { duration: 220 }
    }
  }
}
