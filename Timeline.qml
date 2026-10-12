import QtQuick
import qs.Commons

// Scrubbable progress bar. Drag or click to seek; the mouse wheel nudges by
// `wheelStep` seconds. Emits `seekRequested` only on release / wheel so the
// player is not flooded while dragging.
Item {
  id: root

  property real position: 0
  property real duration: 0
  property real wheelStep: 5
  property color trackColor: Util.alpha(Color.foreground, 0.2)
  property color fillColor: Color.foreground
  property color knobColor: fillColor
  property real trackHeight: 4
  property bool showKnob: hover.hovered || dragging

  readonly property bool dragging: mouse.pressed
  property real dragPosition: 0
  readonly property real shownPosition: dragging ? dragPosition : position
  readonly property real progress: duration > 0 ? Math.max(0, Math.min(1, shownPosition / duration)) : 0

  signal seekRequested(real seconds)

  implicitHeight: 16
  implicitWidth: 200

  function posAt(x) {
    return duration > 0 ? Math.max(0, Math.min(1, x / width)) * duration : 0
  }

  HoverHandler { id: hover; cursorShape: root.duration > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: root.showKnob ? root.trackHeight + 2 : root.trackHeight
    radius: height / 2
    color: root.trackColor
    Behavior on height { NumberAnimation { duration: 120 } }

    Rectangle {
      width: Math.max(height, parent.width * root.progress)
      height: parent.height
      radius: parent.radius
      color: root.fillColor
      visible: root.progress > 0
    }
  }

  Rectangle {
    width: 12
    height: 12
    radius: 6
    color: root.knobColor
    anchors.verticalCenter: parent.verticalCenter
    x: Math.round(root.progress * root.width - width / 2)
    opacity: root.showKnob && root.duration > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.duration > 0
    preventStealing: true
    onPressed: function(e) { root.dragPosition = root.posAt(e.x) }
    onPositionChanged: function(e) { if (pressed) root.dragPosition = root.posAt(e.x) }
    onReleased: function(e) { root.seekRequested(root.posAt(e.x)) }
    onWheel: function(w) {
      var delta = (w.angleDelta.y !== 0 ? w.angleDelta.y : -w.angleDelta.x) / 120
      if (delta === 0) return
      root.seekRequested(Math.max(0, Math.min(root.duration, root.position + delta * root.wheelStep)))
    }
  }
}
