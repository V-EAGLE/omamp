import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Multi-source player model shared by the bar widget (slim popup) and the
// pop-out window.
//
// Sources:
//   - "apple": Apple Music, driven through the amctl.py bridge (queue,
//     library, search).
//   - every other MPRIS player (Spotify, tidal-hifi, web players in any
//     browser, ...): now playing and transport controls.
//
// The unified properties (title, playing, livePosition, ...) and actions
// (playPause, seek, ...) always refer to the active source.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))

  // Set by the bar widget from its `appleMusic` setting.
  property bool appleEnabled: true

  // =============================================================== Apple

  // bridge / browser status
  property bool browser: false
  property bool connected: false
  property bool ready: false
  property bool authorized: false
  // false while Widevine isn't loaded: Apple Music then plays 90 s previews.
  property var drm: null
  // PID of OmAmp's Chromium, whose own MPRIS player is hidden as a duplicate.
  property int browserPid: 0
  readonly property bool appleLive: appleEnabled && connected && authorized
  readonly property bool previewOnly: isApple && appleLive && drm === false
  property string lastError: ""

  property bool applePlaying: false
  property real applePosition: 0
  property real appleDuration: 0
  property real appleVolume: 1
  property int appleShuffle: 0
  property int appleRepeat: 0
  property int queuePosition: -1
  property string storefront: ""
  property var item: null
  property var queue: []

  // Position is pushed every ~0.5s; interpolate between pushes for a smooth
  // timeline. `seekHold` keeps an optimistic value while a seek settles.
  property real _stamp: 0
  property real _seekHoldUntil: 0
  property real appleLivePosition: 0

  property int _nextId: 1
  property var _callbacks: ({})

  signal resultError(string message)

  // =============================================================== sources

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var sources: buildSources()
  property string pickedKey: ""
  property string lastActiveKey: ""
  property var playOrder: ({})
  property int playSerial: 0

  readonly property var activeSource: pickActive()
  readonly property string activeKey: activeSource ? activeSource.key : ""
  readonly property bool isApple: activeKey === "apple"
  readonly property var player: activeSource && activeSource.kind === "mpris" ? activeSource.player : null
  property real mprisPosition: 0

  // ---- unified state of the active source
  readonly property bool hasTrack: isApple ? (item !== null && item !== undefined)
    : !!(player && (player.trackTitle || player.trackArtist))
  readonly property string title: isApple ? (item ? item.title || "" : "") : (player ? player.trackTitle || "" : "")
  readonly property string artist: isApple ? (item ? item.artist || "" : "") : (player ? player.trackArtist || "" : "")
  readonly property string album: isApple ? (item ? item.album || "" : "") : (player ? player.trackAlbum || "" : "")
  readonly property string artUrl: isApple ? (item ? item.art || "" : "") : (player ? player.trackArtUrl || "" : "")
  readonly property bool playing: isApple ? applePlaying : (player ? player.isPlaying : false)
  readonly property real duration: isApple ? appleDuration
    : (player && player.lengthSupported ? Math.max(0, player.length) : 0)
  readonly property real livePosition: isApple ? appleLivePosition : mprisPosition
  readonly property real volume: isApple ? appleVolume : (player && player.volumeSupported ? player.volume : 1)
  readonly property int shuffle: isApple ? appleShuffle : (player && player.shuffle ? 1 : 0)
  // 0 none, 1 one, 2 all (MusicKit's numbering)
  readonly property int repeat: isApple ? appleRepeat : loopToRepeat(player ? player.loopState : MprisLoopState.None)
  readonly property var upNext: isApple ? (queuePosition >= 0 ? queue.slice(queuePosition + 1) : queue) : []

  // ---- capabilities of the active source
  readonly property bool canControl: isApple ? appleLive : !!player
  readonly property bool canSeek: isApple ? appleLive : !!(player && player.canSeek && player.positionSupported && duration > 0)
  readonly property bool canShuffle: isApple ? appleLive : !!(player && player.shuffleSupported)
  readonly property bool canRepeat: isApple ? appleLive : !!(player && player.loopSupported)
  readonly property bool canVolume: isApple ? appleLive : !!(player && player.volumeSupported)
  readonly property bool canNext: isApple ? appleLive : !!(player && player.canGoNext)
  readonly property bool canPrevious: isApple ? appleLive : !!(player && player.canGoPrevious)
  readonly property bool hasQueue: isApple && appleLive
  readonly property bool canShowSource: isApple ? connected : !!(player && player.canRaise)

  readonly property string sourceName: activeSource ? activeSource.name : "OmAmp"
  readonly property string sourceGlyph: activeSource ? activeSource.glyph : "󰝚"

  function loopToRepeat(state) {
    if (state === MprisLoopState.Track) return 1
    if (state === MprisLoopState.Playlist) return 2
    return 0
  }

  function repeatToLoop(mode) {
    if (mode === 1) return MprisLoopState.Track
    if (mode === 2) return MprisLoopState.Playlist
    return MprisLoopState.None
  }

  function isProxyPlayer(p) {
    var name = String(p && p.dbusName || "").toLowerCase()
    return name.indexOf("playerctld") !== -1 || String(p && p.desktopEntry || "").toLowerCase() === "playerctld"
  }

  function isOwnBrowser(p) {
    return browserPid > 0 && String(p && p.dbusName || "").endsWith(".instance" + browserPid)
  }

  // Name and glyph for an MPRIS player. Browser players all report the
  // browser's identity, so the artwork host tells which service is playing.
  function describe(p) {
    var ident = String(p.identity || p.desktopEntry || "").trim()
    var id = (ident + " " + String(p.desktopEntry || "") + " " + String(p.dbusName || "")).toLowerCase()
    var art = String(p.trackArtUrl || "").toLowerCase()
    var web = /chrom|brave|firefox|vivaldi|edge|opera|helium|zen|librewolf/.test(id)
    var services = [
      { re: /spotify/, host: /scdn\.co|spotifycdn/, name: "Spotify", glyph: "󰓇" },
      { re: /applemusic|apple music/, host: /mzstatic\.com/, name: "Apple Music", glyph: "󰀵" },
      { re: /tidal/, host: /tidal\.com/, name: "Tidal", glyph: "󰝚" },
      { re: /amazon/, host: /media-amazon\.com|ssl-images-amazon/, name: "Amazon Music", glyph: "" },
      { re: /audible/, host: /audible/, name: "Audible", glyph: "󰋋" },
      { re: /youtube/, host: /ytimg\.com|googleusercontent/, name: "YouTube", glyph: "󰗃" },
      { re: /deezer/, host: /dzcdn\.net/, name: "Deezer", glyph: "󰝚" },
      { re: /soundcloud/, host: /sndcdn\.com/, name: "SoundCloud", glyph: "󰓀" }
    ]
    for (var i = 0; i < services.length; i++) {
      var s = services[i]
      if (s.re.test(id) || (web && s.host.test(art)))
        return { name: s.name + (web && !s.re.test(id) ? " (web)" : ""), glyph: s.glyph }
    }
    if (web) return { name: ident || "Browser", glyph: "󰖟" }
    return { name: ident || "Media player", glyph: "󰝚" }
  }

  function buildSources() {
    var list = []
    if (appleEnabled)
      list.push({ key: "apple", kind: "apple", name: "Apple Music", glyph: "󰀵", player: null,
                  playing: applePlaying, title: item ? item.title || "" : "", artist: item ? item.artist || "" : "" })
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      if (!p || isProxyPlayer(p) || isOwnBrowser(p)) continue
      if (!(p.trackTitle || p.trackArtist)) continue
      var d = describe(p)
      list.push({ key: String(p.dbusName), kind: "mpris", name: d.name, glyph: d.glyph, player: p,
                  playing: !!p.isPlaying, title: p.trackTitle || "", artist: p.trackArtist || "" })
    }
    return list
  }

  function sourceFor(key) {
    for (var i = 0; i < sources.length; i++) if (sources[i].key === key) return sources[i]
    return null
  }

  // Manual pick wins while it exists; otherwise the most recently started
  // playing source; otherwise the last active one, then Apple / the first.
  function pickActive() {
    var picked = pickedKey ? sourceFor(pickedKey) : null
    if (picked) return picked
    var best = null, bestOrder = -1
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i]
      if (!s.playing) continue
      var order = playOrder[s.key] || 0
      if (order > bestOrder) { best = s; bestOrder = order }
    }
    if (best) return best
    var last = lastActiveKey ? sourceFor(lastActiveKey) : null
    if (last) return last
    var apple = sourceFor("apple")
    if (apple && (appleLive || sources.length === 1)) return apple
    for (var j = 0; j < sources.length; j++) if (sources[j].kind === "mpris") return sources[j]
    return apple
  }

  function selectSource(key) {
    pickedKey = key
  }

  onActiveKeyChanged: if (activeKey) lastActiveKey = activeKey

  // Record when each source started playing (newest wins auto-selection).
  function syncPlayOrder() {
    var next = {}
    var serial = playSerial
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i]
      if (!s.playing) continue
      if (playOrder[s.key] === undefined) next[s.key] = ++serial
      else next[s.key] = playOrder[s.key]
    }
    // A manual pick is released once another source starts playing.
    for (var k in next) {
      if (playOrder[k] === undefined && k !== pickedKey && pickedKey !== "") pickedKey = ""
    }
    playSerial = serial
    playOrder = next
  }

  onSourcesChanged: syncPlayOrder()

  // ============================================================ launchers

  property var installedApps: ({})
  readonly property var launchers: [
    { key: "apple", name: "Apple Music", glyph: "󰀵", visible: appleEnabled },
    { key: "spotify", name: "Spotify", glyph: "󰓇", app: "spotify", url: "https://open.spotify.com/" },
    { key: "tidal", name: "Tidal", glyph: "󰝚", app: "tidal-hifi", url: "https://listen.tidal.com/" },
    { key: "amazon", name: "Amazon Music", glyph: "", url: "https://music.amazon.com/" },
    { key: "audible", name: "Audible", glyph: "󰋋", url: "https://www.audible.com/library/titles" },
    { key: "ytmusic", name: "YouTube Music", glyph: "󰗃", url: "https://music.youtube.com/" }
  ]

  function openService(key) {
    if (key === "apple") {
      pickedKey = "apple"
      launch(true)
      return
    }
    for (var i = 0; i < launchers.length; i++) {
      var l = launchers[i]
      if (l.key !== key) continue
      if (l.app && installedApps[l.app]) Quickshell.execDetached(["uwsm-app", "--", l.app])
      else Quickshell.execDetached(["omarchy-launch-webapp", l.url])
      return
    }
  }

  Process {
    running: true
    command: ["sh", "-c", "for a in spotify tidal-hifi; do command -v \"$a\" >/dev/null 2>&1 && echo \"$a\"; done"]
    stdout: SplitParser {
      onRead: function(line) {
        var next = {}
        for (var k in root.installedApps) next[k] = root.installedApps[k]
        next[String(line).trim()] = true
        root.installedApps = next
      }
    }
  }

  // ============================================================== actions

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

  // Apple controls auto-launch the web player when it is not running yet.
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

  function showSource() {
    if (isApple) showWeb()
    else if (player && player.canRaise) player.raise()
  }

  function playPause() {
    if (isApple) {
      if (connected) applePlaying = !applePlaying
      control("playPause")
    } else if (player) {
      if (player.canTogglePlaying) player.togglePlaying()
      else if (player.isPlaying) player.pause()
      else player.play()
    }
  }

  function next() {
    if (isApple) control("next")
    else if (player && player.canGoNext) player.next()
  }

  function previous() {
    if (isApple) control("previous")
    else if (player && player.canGoPrevious) player.previous()
  }

  function setShuffle(mode) {
    if (isApple) { appleShuffle = mode; control("shuffle", { mode: mode }) }
    else if (player && player.shuffleSupported) player.shuffle = !!mode
  }

  function setRepeat(mode) {
    if (isApple) { appleRepeat = mode; control("repeat", { mode: mode }) }
    else if (player && player.loopSupported) player.loopState = repeatToLoop(mode)
  }

  function cycleRepeat() { setRepeat((repeat + 2) % 3) } // none -> all -> one -> none

  function setVolume(value) {
    var v = Math.max(0, Math.min(1, value))
    if (isApple) { appleVolume = v; control("volume", { value: v }) }
    else if (player && player.volumeSupported) player.volume = v
  }

  function seek(seconds) {
    var t = Math.max(0, Math.min(duration || 0, seconds))
    if (isApple) {
      applePosition = t
      appleLivePosition = t
      _stamp = Date.now()
      _seekHoldUntil = Date.now() + 1500
      control("seek", { time: t })
    } else if (player && player.canSeek) {
      player.position = t
      mprisPosition = t
    }
  }

  // Apple-only: jump to a queue index.
  function jump(index) { control("jump", { index: index }) }

  // kind: song | album | playlist | station | songs
  function playQueue(kind, idOrIds, startWith, shuffleMode, callback) {
    pickedKey = "apple"
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

  // ============================================================= bridge

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type === "state") {
      if (Date.now() >= _seekHoldUntil) {
        applePosition = msg.time || 0
        appleLivePosition = applePosition
        _stamp = Date.now()
      }
      applePlaying = !!msg.playing
      appleDuration = msg.duration || 0
      appleVolume = msg.volume === undefined ? appleVolume : msg.volume
      appleShuffle = msg.shuffle || 0
      appleRepeat = msg.repeat || 0
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
      browserPid = msg.pid || 0
      if (!connected) {
        applePlaying = false
        item = null
        queue = []
      }
    } else if (msg.type === "result") {
      var cb = _callbacks[msg.id]
      if (cb) {
        delete _callbacks[msg.id]
        try { cb(msg.ok, msg.ok ? msg.data : msg.error) } catch (e) { console.warn("omamp callback:", e) }
      }
    } else if (msg.type === "error") {
      lastError = msg.message || ""
      console.warn("omamp:", lastError)
    }
  }

  // Smooth timeline: interpolate Apple's position, and poll MPRIS players
  // (Quickshell doesn't update MprisPlayer.position on its own).
  Timer {
    interval: 250
    repeat: true
    running: root.playing
    onTriggered: {
      if (root.isApple) {
        var t = root.applePosition + (Date.now() - root._stamp) / 1000
        root.appleLivePosition = root.appleDuration > 0 ? Math.min(t, root.appleDuration) : t
      } else if (root.player) {
        root.player.positionChanged()
        root.mprisPosition = root.player.position
      }
    }
  }

  onPlayerChanged: mprisPosition = player ? player.position : 0

  Process {
    id: bridge
    command: ["python3", "-u", root.pluginDir + "amctl.py", "bridge"]
    running: root.appleEnabled
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleLine(data) }
    }
    stderr: SplitParser {
      onRead: function(data) { console.warn("omamp bridge:", data) }
    }
    onExited: function(code) {
      root.connected = false
      root.browserPid = 0
      if (root.appleEnabled) restart.start()
    }
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: if (root.appleEnabled) bridge.running = true
  }
}
