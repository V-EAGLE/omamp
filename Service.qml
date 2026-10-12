import QtQuick
import Quickshell
import Quickshell.Io

// Owns the amctl.py bridge process and mirrors Apple Music's MusicKit state.
// Shared by the bar widget (slim popup) and the pop-out player window.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))

  // bridge / browser status
  property bool browser: false
  property bool connected: false
  property bool ready: false
  property bool authorized: false
  // false while Widevine isn't loaded: Apple Music then plays 90 s previews.
  property var drm: null
  readonly property bool previewOnly: connected && authorized && drm === false
  property string lastError: ""

  // playback
  property bool playing: false
  property real position: 0
  property real duration: 0
  property real volume: 1
  property int shuffle: 0
  property int repeat: 0
  property int queuePosition: -1
  property string storefront: ""
  property var item: null
  property var queue: []

  // Position is pushed every ~0.5s; interpolate between pushes for a smooth
  // timeline. `seekHold` keeps an optimistic value while a seek settles.
  property real _stamp: 0
  property real _seekHoldUntil: 0
  property real livePosition: 0

  readonly property bool hasTrack: item !== null && item !== undefined
  readonly property string title: hasTrack ? (item.title || "") : ""
  readonly property string artist: hasTrack ? (item.artist || "") : ""
  readonly property string album: hasTrack ? (item.album || "") : ""
  readonly property string artUrl: hasTrack ? (item.art || "") : ""
  readonly property var upNext: queuePosition >= 0 ? queue.slice(queuePosition + 1) : queue

  property int _nextId: 1
  property var _callbacks: ({})

  signal resultError(string message)

  function send(cmd, args, callback) {
    var msg = { cmd: cmd, args: args || {} }
    if (callback) {
      msg.id = _nextId++
      _callbacks[msg.id] = callback
    }
    if (!bridge.running) {
      if (callback) callback(false, "bridge not running")
      return
    }
    bridge.write(JSON.stringify(msg) + "\n")
  }

  // Controls auto-launch the web player when it is not running yet.
  function control(cmd, args) {
    if (!connected) {
      launch(true)
      return
    }
    send(cmd, args)
  }

  function launch(hidden) { send("launch", { hidden: hidden !== false }) }
  function showWeb() { send("showWeb") }
  function hideWeb() { send("hideWeb") }
  function playPause() { if (connected) playing = !playing; control("playPause") }
  function next() { control("next") }
  function previous() { control("previous") }
  function jump(index) { control("jump", { index: index }) }
  function setShuffle(mode) { shuffle = mode; control("shuffle", { mode: mode }) }
  function setRepeat(mode) { repeat = mode; control("repeat", { mode: mode }) }
  function setVolume(value) { volume = value; control("volume", { value: value }) }
  function cycleRepeat() { setRepeat((repeat + 2) % 3) } // none -> all -> one -> none
  function seek(seconds) {
    var t = Math.max(0, Math.min(duration || 0, seconds))
    position = t
    livePosition = t
    _stamp = Date.now()
    _seekHoldUntil = Date.now() + 1500
    control("seek", { time: t })
  }

  // kind: song | album | playlist | station | songs
  function playQueue(kind, idOrIds, startWith, shuffleMode, callback) {
    var args = { kind: kind, shuffle: shuffleMode ? 1 : 0 }
    if (kind === "songs") args.ids = idOrIds
    else args.id = idOrIds
    if (startWith !== undefined && startWith !== null && startWith >= 0) args.startWith = startWith
    send("setQueue", args, callback || function(ok, data) { if (!ok) root.resultError(String(data)) })
  }

  function playNext(kind, id) { send("playNext", { kind: kind, id: id }) }
  function playLater(kind, id) { send("playLater", { kind: kind, id: id }) }
  function request(cmd, args, callback) { send(cmd, args, callback) }

  // Map an API resource type to the MusicKit setQueue key.
  function queueKind(type) {
    if (!type) return "song"
    if (type.indexOf("playlist") !== -1) return "playlist"
    if (type.indexOf("album") !== -1) return "album"
    if (type.indexOf("station") !== -1) return "station"
    return "song"
  }

  function formatTime(seconds) {
    if (!isFinite(seconds) || seconds < 0) seconds = 0
    var s = Math.floor(seconds)
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var ss = s % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + (ss < 10 ? "0" : "") + ss
  }

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type === "state") {
      if (Date.now() >= _seekHoldUntil) {
        position = msg.time || 0
        livePosition = position
        _stamp = Date.now()
      }
      playing = !!msg.playing
      duration = msg.duration || 0
      volume = msg.volume === undefined ? volume : msg.volume
      shuffle = msg.shuffle || 0
      repeat = msg.repeat || 0
      queuePosition = msg.position === undefined ? -1 : msg.position
      storefront = msg.storefront || storefront
      authorized = !!msg.authorized
      var same = item && msg.item && item.id === msg.item.id && item.art === msg.item.art
      if (!same) item = msg.item || null
    } else if (msg.type === "queue") {
      queue = msg.items || []
    } else if (msg.type === "status") {
      browser = !!msg.browser
      connected = !!msg.connected
      ready = !!msg.ready
      authorized = !!msg.authorized
      drm = msg.drm === undefined ? null : msg.drm
      if (!connected) {
        playing = false
        item = null
        queue = []
      }
    } else if (msg.type === "result") {
      var cb = _callbacks[msg.id]
      if (cb) {
        delete _callbacks[msg.id]
        try { cb(msg.ok, msg.ok ? msg.data : msg.error) } catch (e) { console.warn("applemusic callback:", e) }
      }
    } else if (msg.type === "error") {
      lastError = msg.message || ""
      console.warn("applemusic:", lastError)
    }
  }

  Timer {
    interval: 250
    repeat: true
    running: root.playing
    onTriggered: {
      var t = root.position + (Date.now() - root._stamp) / 1000
      root.livePosition = root.duration > 0 ? Math.min(t, root.duration) : t
    }
  }

  Process {
    id: bridge
    command: ["python3", "-u", root.pluginDir + "amctl.py", "bridge"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleLine(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { console.warn("applemusic bridge:", data) }
    }
    onExited: function(code) {
      root.connected = false
      restart.start()
    }
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: bridge.running = true
  }
}
