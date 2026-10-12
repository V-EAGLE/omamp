import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons

// Pop-out Apple Music player: sidebar navigation, player bar, library /
// catalog browsing, search, and an Up Next drawer.
Item {
  id: root

  // ---- host injections
  property var shell: null
  property var service: null
  property var manifest: null

  readonly property var am: service
  // Apple Music pages need a signed-in Apple source.
  readonly property bool live: !!(am && am.appleLive)

  // ---- palette (Apple Music dark)
  readonly property color accent: Color.accent
  readonly property color bg: Color.background
  readonly property color sidebarBg: Qt.tint(Color.background, Util.alpha(Color.foreground, 0.04))
  readonly property color barBg: Qt.tint(Color.background, Util.alpha(Color.foreground, 0.06))
  readonly property color lcdBg: Qt.tint(Color.background, Util.alpha(Color.foreground, 0.1))
  readonly property color separator: Util.alpha(Color.foreground, 0.12)
  readonly property color secondary: Util.alpha(Color.foreground, 0.6)
  readonly property string iconFont: Style.font.family

  // ---- lifecycle
  property bool opened: false
  property bool closingFromHost: false

  function open(payloadJson) {
    closingFromHost = false
    opened = true
    window.visible = true
    if (live && !initialized) initialize()

    // Optional payload: {"search": "term"} or {"nav": {view, ...}} opens a page.
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (live && typeof p.search === "string" && p.search !== "") {
      searchField.text = p.search
      doSearch(p.search)
    } else if (p.nav && typeof p.nav.view === "string" && (live || p.nav.view === "nowplaying")) {
      navigate(p.nav)
    } else if (am && (!am.isApple || !am.appleEnabled) && nav.view !== "nowplaying") {
      navigate({ view: "nowplaying" })
    }
  }

  function close() {
    closingFromHost = true
    opened = false
    window.visible = false
    closingFromHost = false
  }

  // ---- navigation / data
  property bool initialized: false
  property var nav: ({ view: "nowplaying" })
  property var navHistory: []
  property var sections: []
  property bool loading: false
  property string errorText: ""
  property var cache: ({})
  property int serial: 0
  property var playlists: []
  property bool queueOpen: false
  property string searchScope: "catalog"
  property string searchTerm: ""

  function initialize() {
    initialized = true
    loadPlaylists()
    if (nav.view === "nowplaying" && am.isApple) nav = { view: "home" }
    load(nav)
  }

  function loadPlaylists() {
    am.request("library", { section: "playlists" }, function(ok, data) {
      if (ok) root.playlists = data || []
    })
  }

  function navKey(n) { return JSON.stringify(n) }

  function navigate(n) {
    if (navKey(n) === navKey(nav)) return
    var h = navHistory.slice()
    h.push(nav)
    if (h.length > 50) h.shift()
    navHistory = h
    nav = n
    load(n)
  }

  function back() {
    if (!navHistory.length) return
    var h = navHistory.slice()
    nav = h.pop()
    navHistory = h
    load(nav)
  }

  function refresh() {
    var c = {}
    for (var k in cache) if (k !== navKey(nav)) c[k] = cache[k]
    cache = c
    if (nav.view === "home" || nav.view === "library") loadPlaylists()
    load(nav)
  }

  function load(n) {
    var mySerial = ++serial
    var key = navKey(n)
    errorText = ""
    pageList.positionViewAtBeginning()
    if (cache[key] !== undefined) {
      loading = false
      sections = build(n, cache[key])
      return
    }
    sections = n.view === "search" ? build(n, null) : []
    if (n.view === "nowplaying") { loading = false; return }
    if (!live) return
    loading = true
    var cmd, args
    if (n.view === "home") { cmd = "home"; args = {} }
    else if (n.view === "library") { cmd = "library"; args = { section: n.section } }
    else if (n.view === "container") { cmd = "container"; args = { type: n.type, id: n.id } }
    else if (n.view === "search") {
      if (!n.term) { loading = false; return }
      cmd = "search"; args = { term: n.term, scope: n.scope }
    }
    am.request(cmd, args, function(ok, data) {
      if (mySerial !== root.serial) return
      root.loading = false
      if (!ok) { root.errorText = String(data || "Request failed"); return }
      var c = {}
      for (var k in root.cache) c[k] = root.cache[k]
      c[key] = data
      root.cache = c
      root.sections = root.build(n, data)
    })
  }

  function libraryTitle(section) {
    return ({ recent: "Recently Added", artists: "Artists", albums: "Albums", songs: "Songs", playlists: "Playlists" })[section] || "Library"
  }

  // Turn a response into page sections. Rendering flattens these into rows.
  function build(n, data) {
    var out = []
    if (n.view === "home") {
      out.push({ kind: "pagetitle", text: "Home" })
      var groups = data || []
      for (var i = 0; i < groups.length; i++)
        out.push({ kind: "carousel", title: groups[i].title, items: groups[i].items })
      if (!groups.length) out.push({ kind: "message", text: "Nothing to show yet. Play some music!" })
    } else if (n.view === "library") {
      out.push({ kind: "pagetitle", text: libraryTitle(n.section) })
      var items = data || []
      if (n.section === "songs") out.push({ kind: "tracks", items: items, context: { kind: "songs" }, showArt: true, showAlbum: true })
      else out.push({ kind: "grid", items: items })
      if (!items.length) out.push({ kind: "message", text: "Your library is empty here." })
    } else if (n.view === "container") {
      var info = data && data.info ? data.info : { name: "", type: n.type }
      var tracks = data && data.tracks ? data.tracks : []
      var isArtist = n.type.indexOf("artist") !== -1
      out.push({ kind: "hero", info: info, tracks: tracks, isArtist: isArtist })
      if (isArtist) {
        if (tracks.length) out.push({ kind: "tracks", title: "Top Songs", items: tracks.slice(0, 10), context: { kind: "songs" }, showArt: true, showAlbum: true })
        if (data && data.albums && data.albums.length) out.push({ kind: "grid", title: "Albums", items: data.albums })
      } else {
        var isAlbum = n.type.indexOf("album") !== -1
        out.push({ kind: "tracks", items: tracks, context: { kind: am.queueKind(n.type), id: n.id }, showArt: !isAlbum, showAlbum: !isAlbum, numbered: isAlbum })
      }
    } else if (n.view === "search") {
      out.push({ kind: "pagetitle", text: n.term ? "Results for “" + n.term + "”" : "Search" })
      out.push({ kind: "scope" })
      if (data) {
        if (data.songs.length) out.push({ kind: "tracks", title: "Songs", items: data.songs.slice(0, 12), context: { kind: "single" }, showArt: true, showAlbum: true })
        if (data.artists.length) out.push({ kind: "carousel", title: "Artists", items: data.artists })
        if (data.albums.length) out.push({ kind: "carousel", title: "Albums", items: data.albums })
        if (data.playlists.length) out.push({ kind: "carousel", title: "Playlists", items: data.playlists })
        if (!data.songs.length && !data.artists.length && !data.albums.length && !data.playlists.length)
          out.push({ kind: "message", text: "No results." })
      }
    }
    return out
  }

  readonly property real pagePad: 28
  readonly property real cardGap: 20
  readonly property real minCard: 170
  readonly property int columns: Math.max(2, Math.floor((pageList.width - pagePad * 2 + cardGap) / (minCard + cardGap)))
  readonly property real cardWidth: (pageList.width - pagePad * 2 - cardGap * (columns - 1)) / columns
  readonly property var rows: flatten(sections, columns)

  function flatten(secs, cols) {
    var out = []
    for (var s = 0; s < secs.length; s++) {
      var sec = secs[s]
      if (sec.title) out.push({ kind: "title", text: sec.title })
      if (sec.kind === "grid") {
        for (var i = 0; i < sec.items.length; i += cols)
          out.push({ kind: "cardrow", items: sec.items.slice(i, i + cols) })
      } else if (sec.kind === "tracks") {
        for (var t = 0; t < sec.items.length; t++)
          out.push({ kind: "track", item: sec.items[t], index: t, section: sec })
      } else {
        out.push(sec)
      }
    }
    out.push({ kind: "spacer" })
    return out
  }

  // ---- actions
  function openItem(item) {
    var t = item.type || ""
    if (t.indexOf("album") !== -1 || t.indexOf("playlist") !== -1 || t.indexOf("artist") !== -1)
      navigate({ view: "container", type: t, id: item.id })
    else
      playItem(item)
  }

  function playItem(item, shuffleMode) {
    am.playQueue(am.queueKind(item.type), item.id, -1, shuffleMode)
  }

  function playTrack(section, index) {
    var ctx = section.context || {}
    var item = section.items[index]
    if (ctx.kind === "album" || ctx.kind === "playlist") {
      am.playQueue(ctx.kind, ctx.id, index, 0)
    } else if (ctx.kind === "songs") {
      var ids = []
      for (var i = index; i < section.items.length && ids.length < 200; i++) ids.push(section.items[i].id)
      am.playQueue("songs", ids, 0, 0)
    } else {
      am.playQueue("song", item.id, -1, 0)
    }
  }

  function isCurrent(item) {
    if (!am || !am.item || !item) return false
    return item.id === am.item.id || (item.catalogId && item.catalogId === am.item.catalogId)
  }

  function showMenu(item, target, x, y) {
    contextMenu.item = item
    contextMenu.popup(target, x, y)
  }

  function doSearch(term) {
    searchTerm = term
    var n = { view: "search", term: term, scope: searchScope }
    if (nav.view === "search") { nav = n; load(n) }
    else navigate(n)
  }

  Connections {
    target: root.am
    function onAuthorizedChanged() {
      if (root.live && root.opened && !root.initialized) root.initialize()
    }
    function onConnectedChanged() {
      if (root.live && root.opened && !root.initialized) root.initialize()
    }
  }

  // ======================================================================

  FloatingWindow {
    id: window
    title: "OmAmp"
    color: root.bg
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(860, 560)
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost) {
        root.opened = false
        if (root.shell && typeof root.shell.hide === "function") root.shell.hide("io.github.v-eagle.omamp")
      }
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(e) {
        if (e.key === Qt.Key_F && (e.modifiers & Qt.ControlModifier)) {
          searchField.forceActiveFocus(); searchField.selectAll(); e.accepted = true
        } else if (e.key === Qt.Key_Space && !searchField.activeFocus) {
          root.am.playPause(); e.accepted = true
        } else if (e.key === Qt.Key_Left && (e.modifiers & Qt.AltModifier)) {
          root.back(); e.accepted = true
        } else if (e.key === Qt.Key_Right && (e.modifiers & Qt.ControlModifier)) {
          root.am.next(); e.accepted = true
        } else if (e.key === Qt.Key_Left && (e.modifiers & Qt.ControlModifier)) {
          root.am.previous(); e.accepted = true
        } else if (e.key === Qt.Key_Escape) {
          if (searchField.activeFocus) keys.forceActiveFocus()
          else if (root.queueOpen) root.queueOpen = false
          e.accepted = true
        }
      }

      // ------------------------------------------------------------ sidebar
      Rectangle {
        id: sidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 240
        color: root.sidebarBg

        Rectangle {
          anchors.right: parent.right
          width: 1
          height: parent.height
          color: root.separator
        }

        // search field
        Rectangle {
          id: searchBox
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: 14
          anchors.topMargin: 18
          height: 32
          radius: 8
          color: Util.alpha(Color.foreground, 0.08)
          border.width: searchField.activeFocus ? 2 : 0
          border.color: root.accent

          Text {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: root.secondary
            font.family: root.iconFont
            font.pixelSize: 14
          }

          TextInput {
            id: searchField
            anchors.left: searchGlyph.right
            anchors.leftMargin: 8
            anchors.right: clearSearch.left
            anchors.verticalCenter: parent.verticalCenter
            color: Color.foreground
            selectedTextColor: Color.background
            font.family: "Noto Sans"
            font.pixelSize: 13
            selectByMouse: true
            clip: true
            selectionColor: root.accent
            onAccepted: if (text.trim() !== "") { root.doSearch(text.trim()); keys.forceActiveFocus() }

            T {
              anchors.fill: parent
              text: "Search"
              secondary: true
              visible: !searchField.text && !searchField.activeFocus
            }
          }

          IconButton {
            id: clearSearch
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            size: 22
            glyph: "󰅖"
            glyphFont: root.iconFont
            color: root.secondary
            visible: searchField.text !== ""
            onClicked: { searchField.text = ""; keys.forceActiveFocus() }
          }
        }

        Flickable {
          id: sideFlick
          anchors.top: searchBox.bottom
          anchors.topMargin: 14
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: sideFooter.top
          contentHeight: sideCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar {}

          Column {
            id: sideCol
            width: sideFlick.width
            spacing: 2

            T { text: "Now Playing"; leftPadding: 22; topPadding: 4; bottomPadding: 4; secondary: true; font.pixelSize: 11; font.weight: Font.DemiBold }
            Repeater {
              model: root.am ? root.am.sources : []
              SideItem {
                required property var modelData
                x: 10
                width: sideCol.width - 20
                glyph: modelData.glyph
                label: modelData.name + (modelData.playing ? "  󰝚" : "")
                accent: root.accent
                glyphFont: root.iconFont
                selected: root.am.activeKey === modelData.key && root.nav.view === "nowplaying"
                onActivated: { root.am.selectSource(modelData.key); root.navigate({ view: "nowplaying" }) }
              }
            }

            T { text: "Apple Music"; visible: root.am && root.am.appleEnabled; leftPadding: 22; topPadding: 14; bottomPadding: 4; secondary: true; font.pixelSize: 11; font.weight: Font.DemiBold }
            SideItem { glyph: "󰋜"; label: "Home"; visible: root.am && root.am.appleEnabled; property var target: ({ view: "home" }); x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }

            T { text: "Library"; visible: root.am && root.am.appleEnabled; leftPadding: 22; topPadding: 14; bottomPadding: 4; secondary: true; font.pixelSize: 11; font.weight: Font.DemiBold }
            SideItem { glyph: "󰅐"; label: "Recently Added"; visible: root.am && root.am.appleEnabled; property var target: ({ view: "library", section: "recent" }); x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }
            SideItem { glyph: "󰠃"; label: "Artists"; visible: root.am && root.am.appleEnabled; property var target: ({ view: "library", section: "artists" }); x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }
            SideItem { glyph: "󰀥"; label: "Albums"; visible: root.am && root.am.appleEnabled; property var target: ({ view: "library", section: "albums" }); x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }
            SideItem { glyph: "󰎈"; label: "Songs"; visible: root.am && root.am.appleEnabled; property var target: ({ view: "library", section: "songs" }); x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }

            T { text: "Playlists"; visible: root.playlists.length > 0 && root.am.appleEnabled; leftPadding: 22; topPadding: 14; bottomPadding: 4; secondary: true; font.pixelSize: 11; font.weight: Font.DemiBold }
            SideItem { glyph: "󰕰"; label: "All Playlists"; property var target: ({ view: "library", section: "playlists" }); visible: root.playlists.length > 0 && root.am.appleEnabled; x: 10; width: sideCol.width - 20; accent: root.accent; glyphFont: root.iconFont; selected: root.navKey(root.nav) === root.navKey(target); onActivated: root.navigate(target) }
            Repeater {
              model: root.am && root.am.appleEnabled ? root.playlists : []
              SideItem {
                required property var modelData
                readonly property var target: ({ view: "container", type: modelData.type, id: modelData.id })
                x: 10
                width: sideCol.width - 20
                glyph: "󰲸"
                label: modelData.name
                artUrl: modelData.art || ""
                accent: root.accent
                glyphFont: root.iconFont
                selected: root.navKey(root.nav) === root.navKey(target)
                onActivated: root.navigate(target)
              }
            }
            Item { width: 1; height: 12 }
          }
        }

        Item {
          id: sideFooter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 44

          Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            IconButton { size: 28; glyph: "󰁍"; glyphFont: root.iconFont; color: root.secondary; enabled: root.navHistory.length > 0; onClicked: root.back() }
            IconButton { size: 28; glyph: "󰑐"; glyphFont: root.iconFont; color: root.secondary; enabled: root.live; onClicked: root.refresh() }
            IconButton { size: 28; glyph: "󰖟"; glyphFont: root.iconFont; color: root.secondary; enabled: root.am && root.am.canShowSource; onClicked: root.am.showSource() }
          }
        }
      }

      // --------------------------------------------------------- player bar
      Rectangle {
        id: playerBar
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.top: parent.top
        height: 68
        color: root.barBg

        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.separator }

        Row {
          id: transport
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 30; glyph: "󰒟"; glyphFont: root.iconFont
            color: root.secondary
            active: root.am && root.am.shuffle !== 0
            enabled: root.am && root.am.canShuffle
            onClicked: root.am.setShuffle(root.am.shuffle ? 0 : 1)
          }
          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 36; glyph: "󰒮"; glyphFont: root.iconFont
            enabled: root.am && root.am.canPrevious
            onClicked: root.am.previous()
          }
          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 44; glyphSize: 30
            glyph: root.am && root.am.playing ? "󰏤" : "󰐊"; glyphFont: root.iconFont
            onClicked: root.am.playPause()
          }
          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 36; glyph: "󰒭"; glyphFont: root.iconFont
            enabled: root.am && root.am.canNext
            onClicked: root.am.next()
          }
          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 30; glyph: root.am && root.am.repeat === 1 ? "󰑘" : "󰑖"; glyphFont: root.iconFont
            color: root.secondary
            active: root.am && root.am.repeat !== 0
            enabled: root.am && root.am.canRepeat
            onClicked: root.am.cycleRepeat()
          }
        }

        // LCD
        Rectangle {
          id: lcd
          anchors.centerIn: parent
          width: Math.min(560, parent.width - transport.width - right.width - 80)
          height: 52
          radius: 6
          color: root.lcdBg
          border.width: 1
          border.color: Util.alpha(Color.foreground, 0.1)
          clip: true

          CoverArt {
            id: lcdArt
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: height
            radius: 0
            source: root.am ? root.am.artUrl : ""
            glyph: root.am ? root.am.sourceGlyph : "󰝚"
            glyphFont: root.iconFont
            placeholderColor: Util.alpha(Color.foreground, 0.1)
          }

          Column {
            anchors.left: lcdArt.right
            anchors.right: parent.right
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            anchors.top: parent.top
            anchors.topMargin: 7
            spacing: 1

            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.am && root.am.hasTrack ? root.am.title : (root.am ? root.am.sourceName : "OmAmp")
              font.pixelSize: 13
              font.weight: Font.DemiBold
            }
            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              secondary: true
              font.pixelSize: 12
              text: root.am && root.am.hasTrack ? root.am.artist + (root.am.album ? " — " + root.am.album : "") : ""
            }
          }

          T {
            anchors.left: lcdArt.right
            anchors.leftMargin: 8
            anchors.bottom: lcdTimeline.top
            text: root.am ? root.am.formatTime(lcdTimeline.shownPosition) : ""
            secondary: true
            font.pixelSize: 10
            visible: lcdHover.hovered && root.am && root.am.hasTrack
          }
          T {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.bottom: lcdTimeline.top
            text: root.am ? "-" + root.am.formatTime(Math.max(0, root.am.duration - lcdTimeline.shownPosition)) : ""
            secondary: true
            font.pixelSize: 10
            visible: lcdHover.hovered && root.am && root.am.hasTrack
          }

          Timeline {
            id: lcdTimeline
            anchors.left: lcdArt.right
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 10
            trackHeight: 3
            position: root.am ? root.am.livePosition : 0
            duration: root.am ? root.am.duration : 0
            trackColor: Util.alpha(Color.foreground, 0.2)
            fillColor: Util.alpha(Color.foreground, 0.75)
            knobColor: Color.foreground
            showKnob: false
            seekable: root.am ? root.am.canSeek : false
            onSeekRequested: function(t) { root.am.seek(t) }
          }

          HoverHandler { id: lcdHover }
        }

        Row {
          id: right
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.am && root.am.canVolume
            text: !root.am || root.am.volume <= 0.001 ? "󰝟" : (root.am.volume < 0.5 ? "󰖀" : "󰕾")
            color: root.secondary
            font.family: root.iconFont
            font.pixelSize: 16
            TapHandler {
              property real lastVolume: 0.6
              onTapped: {
                if (root.am.volume > 0.001) { lastVolume = root.am.volume; root.am.setVolume(0) }
                else root.am.setVolume(lastVolume)
              }
            }
          }
          Timeline {
            anchors.verticalCenter: parent.verticalCenter
            width: 96
            trackHeight: 4
            duration: 1
            wheelStep: 0.05
            position: root.am ? root.am.volume : 1
            visible: root.am && root.am.canVolume
            trackColor: Util.alpha(Color.foreground, 0.2)
            fillColor: Util.alpha(Color.foreground, 0.75)
            onSeekRequested: function(v) { root.am.setVolume(v) }
          }
          Item { width: 8; height: 1 }
          IconButton {
            anchors.verticalCenter: parent.verticalCenter
            size: 32; glyph: "󰲸"; glyphFont: root.iconFont
            color: root.secondary
            active: root.queueOpen
            visible: root.am && root.am.hasQueue
            onClicked: root.queueOpen = !root.queueOpen
          }
        }
      }

      // ------------------------------------------------------------ content
      Item {
        id: contentArea
        anchors.left: sidebar.right
        anchors.right: queueDrawer.left
        anchors.top: playerBar.bottom
        anchors.bottom: parent.bottom
        clip: true

        Rectangle {
          id: drmBanner
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? 34 : 0
          visible: root.am && root.am.previewOnly
          color: Util.alpha(Color.urgent, 0.18)
          T {
            anchors.fill: parent
            anchors.leftMargin: root.pagePad
            anchors.rightMargin: root.pagePad
            font.pixelSize: 12
            text: "Playing 90-second previews: the DRM module (Widevine) isn't ready yet. The web player restarts automatically once it has downloaded."
          }
        }

        ListView {
          id: pageList
          anchors.top: drmBanner.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          model: root.rows
          visible: root.live && root.nav.view !== "nowplaying"
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: 800
          ScrollBar.vertical: ScrollBar {}

          delegate: Loader {
            id: rowLoader
            required property var modelData
            required property int index
            width: pageList.width
            sourceComponent: {
              switch (modelData.kind) {
                case "pagetitle": return pageTitleRow
                case "title": return titleRow
                case "hero": return heroRow
                case "carousel": return carouselRow
                case "cardrow": return cardRow
                case "track": return trackRow
                case "scope": return scopeRow
                case "message": return messageRow
                default: return spacerRow
              }
            }
          }
        }

        // Now Playing: works for every source (Apple or any MPRIS player).
        Item {
          id: nowPlaying
          anchors.fill: parent
          visible: root.nav.view === "nowplaying"

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 460)
            spacing: 14
            visible: root.am && root.am.hasTrack

            CoverArt {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.min(340, Math.max(160, nowPlaying.height * 0.42))
              height: width
              radius: 12
              source: root.am ? root.am.artUrl : ""
              glyph: root.am ? root.am.sourceGlyph : "󰝚"
              glyphFont: root.iconFont
            }

            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.am ? root.am.title : ""
              font.pixelSize: 24
              font.weight: Font.Bold
            }
            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              secondary: true
              font.pixelSize: 15
              text: root.am ? root.am.artist + (root.am.album ? " — " + root.am.album : "") : ""
              visible: text !== ""
            }
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 6
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.am ? root.am.sourceGlyph : ""
                color: root.accent
                font.family: root.iconFont
                font.pixelSize: 13
              }
              T {
                anchors.verticalCenter: parent.verticalCenter
                text: root.am ? root.am.sourceName : ""
                color: root.accent
                font.pixelSize: 12
              }
            }

            Column {
              width: parent.width
              spacing: 4
              visible: root.am && root.am.duration > 0
              Timeline {
                id: npTimeline
                width: parent.width
                position: root.am ? root.am.livePosition : 0
                duration: root.am ? root.am.duration : 0
                seekable: root.am ? root.am.canSeek : false
                fillColor: root.accent
                onSeekRequested: function(t) { root.am.seek(t) }
              }
              Item {
                width: parent.width
                height: 14
                T { anchors.left: parent.left; secondary: true; font.pixelSize: 11; text: root.am ? root.am.formatTime(npTimeline.shownPosition) : "" }
                T { anchors.right: parent.right; secondary: true; font.pixelSize: 11; text: root.am ? "-" + root.am.formatTime(Math.max(0, root.am.duration - npTimeline.shownPosition)) : "" }
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 14
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 36; glyph: "󰒟"; glyphFont: root.iconFont
                color: root.secondary
                visible: root.am && root.am.canShuffle
                active: root.am && root.am.shuffle !== 0
                onClicked: root.am.setShuffle(root.am.shuffle ? 0 : 1)
              }
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 46; glyph: "󰒮"; glyphFont: root.iconFont
                enabled: root.am && root.am.canPrevious
                onClicked: root.am.previous()
              }
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 64; glyphSize: 34
                glyph: root.am && root.am.playing ? "󰏤" : "󰐊"; glyphFont: root.iconFont
                filled: true
                onClicked: root.am.playPause()
              }
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 46; glyph: "󰒭"; glyphFont: root.iconFont
                enabled: root.am && root.am.canNext
                onClicked: root.am.next()
              }
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 36; glyph: root.am && root.am.repeat === 1 ? "󰑘" : "󰑖"; glyphFont: root.iconFont
                color: root.secondary
                visible: root.am && root.am.canRepeat
                active: root.am && root.am.repeat !== 0
                onClicked: root.am.cycleRepeat()
              }
            }
          }

          // nothing playing: open a service
          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 520)
            spacing: 16
            visible: !root.am || !root.am.hasTrack

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰝚"
              color: root.accent
              font.family: root.iconFont
              font.pixelSize: 54
            }
            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: 18
              font.weight: Font.DemiBold
              text: root.am && root.am.isApple && root.am.connected && !root.am.authorized
                ? "Sign in to Apple Music in the web player" : "Nothing playing"
            }
            T {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              secondary: true
              text: "Start music in any player that supports MPRIS — Spotify, tidal-hifi or a web player in your browser — or open a service:"
            }
            Flow {
              width: parent.width
              spacing: 10
              Repeater {
                model: root.am ? root.am.launchers.filter(function(l) { return l.visible !== false }) : []
                PillButton {
                  required property var modelData
                  label: modelData.name
                  glyph: modelData.glyph
                  glyphFont: root.iconFont
                  onClicked: modelData.key === "apple" && root.am.connected && !root.am.authorized
                    ? root.am.showWeb() : root.am.openService(modelData.key)
                }
              }
            }
          }
        }

        // status overlays
        Column {
          anchors.centerIn: parent
          spacing: 14
          visible: root.nav.view !== "nowplaying" && (!root.live || root.loading || root.errorText !== "")
          width: Math.min(parent.width - 80, 420)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰀵"
            color: root.accent
            font.family: root.iconFont
            font.pixelSize: 54
            visible: !root.live
          }
          T {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            text: !root.am ? "Apple Music service is not loaded."
              : !root.am.connected ? (root.am.browser ? "Connecting to Apple Music…" : "Apple Music is not running.")
              : !root.am.authorized ? "Sign in to Apple Music in the web player to get started."
              : root.loading ? "Loading…" : root.errorText
          }
          PillButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.am && (!root.am.browser || (root.am.connected && !root.am.authorized))
            label: root.am && root.am.connected ? "Open Web Player to Sign In" : "Start Apple Music"
            glyph: "󰀵"
            glyphFont: root.iconFont
            onClicked: root.am.connected ? root.am.showWeb() : root.am.launch(true)
          }
          PillButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.live && !root.loading && root.errorText !== ""
            label: "Retry"
            glyph: "󰑐"
            glyphFont: root.iconFont
            onClicked: root.load(root.nav)
          }
        }
      }

      // ---------------------------------------------------------- up next
      Rectangle {
        id: queueDrawer
        anchors.right: parent.right
        anchors.top: playerBar.bottom
        anchors.bottom: parent.bottom
        width: root.queueOpen && root.am && root.am.hasQueue ? 320 : 0
        color: root.sidebarBg
        clip: true
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: root.separator }

        T {
          id: queueTitle
          anchors.left: parent.left
          anchors.leftMargin: 18
          anchors.top: parent.top
          anchors.topMargin: 16
          text: "Playing Next"
          font.pixelSize: 17
          font.weight: Font.Bold
        }
        T {
          anchors.left: queueTitle.left
          anchors.top: queueTitle.bottom
          anchors.topMargin: 2
          secondary: true
          font.pixelSize: 12
          text: root.am ? root.am.upNext.length + (root.am.upNext.length === 1 ? " song" : " songs") : ""
        }

        ListView {
          id: queueList
          anchors.top: queueTitle.bottom
          anchors.topMargin: 26
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: 8
          anchors.rightMargin: 8
          width: 304
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.am ? root.am.upNext : []
          ScrollBar.vertical: ScrollBar {}

          delegate: Rectangle {
            id: qItem
            required property var modelData
            width: queueList.width
            height: 52
            radius: 6
            color: qHover.hovered ? Util.alpha(Color.foreground, 0.07) : "transparent"
            HoverHandler { id: qHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.am.jump(qItem.modelData.index) }

            CoverArt {
              id: qArt
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              width: 38; height: 38; radius: 4
              source: qItem.modelData.art || ""
              glyphFont: root.iconFont
              crossfade: false
            }
            Column {
              anchors.left: qArt.right
              anchors.leftMargin: 10
              anchors.right: qDur.left
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              T { width: parent.width; text: qItem.modelData.title; font.pixelSize: 13 }
              T { width: parent.width; text: qItem.modelData.artist; secondary: true; font.pixelSize: 12 }
            }
            T {
              id: qDur
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: root.am.formatTime(qItem.modelData.duration)
              secondary: true
              font.pixelSize: 11
            }
          }
        }
      }
    }
  }

  // ====================================================== row components

  Component {
    id: pageTitleRow
    Item {
      readonly property var row: parent ? parent.modelData : ({})
      height: 76
      T {
        anchors.left: parent.left
        anchors.leftMargin: root.pagePad
        anchors.right: parent.right
        anchors.rightMargin: root.pagePad
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        text: row.text || ""
        font.pixelSize: 28
        font.weight: Font.Bold
      }
    }
  }

  Component {
    id: titleRow
    Item {
      readonly property var row: parent ? parent.modelData : ({})
      height: 52
      T {
        anchors.left: parent.left
        anchors.leftMargin: root.pagePad
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        text: row.text || ""
        font.pixelSize: 20
        font.weight: Font.Bold
      }
      Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.leftMargin: root.pagePad
        anchors.right: parent.right
        anchors.rightMargin: root.pagePad
        height: 1
        color: root.separator
      }
    }
  }

  Component {
    id: messageRow
    Item {
      readonly property var row: parent ? parent.modelData : ({})
      height: 80
      T {
        anchors.centerIn: parent
        text: row.text || ""
        secondary: true
        font.pixelSize: 14
      }
    }
  }

  Component {
    id: spacerRow
    Item { height: 40 }
  }

  Component {
    id: scopeRow
    Item {
      height: 44
      Row {
        anchors.left: parent.left
        anchors.leftMargin: root.pagePad
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Rectangle {
          width: scopeInner.implicitWidth + 4
          height: 28
          radius: 7
          color: Util.alpha(Color.foreground, 0.08)
          Row {
            id: scopeInner
            anchors.centerIn: parent
            Repeater {
              model: [{ key: "catalog", label: "Apple Music" }, { key: "library", label: "Your Library" }]
              Rectangle {
                required property var modelData
                width: scopeLabel.implicitWidth + 28
                height: 24
                radius: 6
                color: root.searchScope === modelData.key ? Util.alpha(Color.foreground, 0.2) : "transparent"
                T {
                  id: scopeLabel
                  anchors.centerIn: parent
                  text: modelData.label
                  font.pixelSize: 12
                  font.weight: Font.DemiBold
                }
                TapHandler {
                  onTapped: {
                    root.searchScope = modelData.key
                    if (root.searchTerm) root.doSearch(root.searchTerm)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: heroRow
    Item {
      id: hero
      readonly property var row: parent ? parent.modelData : ({ info: {} })
      readonly property var info: row.info || {}
      readonly property var tracks: row.tracks || []
      readonly property real totalSeconds: {
        var s = 0
        for (var i = 0; i < tracks.length; i++) s += tracks[i].duration || 0
        return s
      }
      height: 320

      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0; color: Util.alpha(Color.accent, 0.18) }
          GradientStop { position: 1; color: "transparent" }
        }
      }

      CoverArt {
        id: heroArt
        anchors.left: parent.left
        anchors.leftMargin: root.pagePad
        anchors.top: parent.top
        anchors.topMargin: 36
        width: 240
        height: 240
        radius: hero.row.isArtist ? 120 : 10
        source: hero.info.art || ""
        glyph: hero.row.isArtist ? "󰠃" : "󰀥"
        glyphFont: root.iconFont
      }

      Column {
        anchors.left: heroArt.right
        anchors.leftMargin: 28
        anchors.right: parent.right
        anchors.rightMargin: root.pagePad
        anchors.bottom: heroArt.bottom
        spacing: 6

        T {
          width: parent.width
          text: hero.info.name || ""
          font.pixelSize: hero.row.isArtist ? 40 : 28
          font.weight: Font.Bold
          wrapMode: Text.WordWrap
          maximumLineCount: 2
        }
        T {
          width: parent.width
          text: hero.info.artist || ""
          color: root.accent
          font.pixelSize: 20
          visible: text !== "" && !hero.row.isArtist
        }
        T {
          width: parent.width
          secondary: true
          font.pixelSize: 12
          visible: !hero.row.isArtist
          text: {
            var bits = []
            if (hero.info.genre) bits.push(hero.info.genre.toUpperCase())
            if (hero.info.date && hero.info.type && hero.info.type.indexOf("album") !== -1) bits.push(String(hero.info.date).slice(0, 4))
            if (hero.tracks.length) bits.push(hero.tracks.length + (hero.tracks.length === 1 ? " SONG" : " SONGS"))
            if (hero.totalSeconds > 0) bits.push(Math.round(hero.totalSeconds / 60) + " MIN")
            return bits.join(" · ")
          }
        }
        T {
          width: parent.width
          secondary: true
          font.pixelSize: 12
          text: hero.info.description || ""
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          visible: text !== ""
        }
        Item { width: 1; height: 8 }
        Row {
          spacing: 12
          visible: hero.tracks.length > 0
          PillButton {
            label: "Play"; glyph: "󰐊"; glyphFont: root.iconFont
            onClicked: hero.row.isArtist ? root.playTrack({ items: hero.tracks, context: { kind: "songs" } }, 0) : root.playItem(hero.info, 0)
          }
          PillButton {
            label: "Shuffle"; glyph: "󰒟"; glyphFont: root.iconFont
            onClicked: {
              if (hero.row.isArtist) {
                var ids = hero.tracks.map(function(t) { return t.id })
                root.am.playQueue("songs", ids, 0, 1)
              } else root.playItem(hero.info, 1)
            }
          }
        }
      }
    }
  }

  Component {
    id: trackRow
    Item {
      readonly property var row: parent ? parent.modelData : ({ item: {} })
      readonly property var sec: row.section || {}
      height: 48
      TrackRow {
        id: tr
        x: root.pagePad - 10
        width: parent.width - (root.pagePad - 10) * 2
        item: row.item || {}
        number: sec.numbered ? (row.item.track || row.index + 1) : 0
        showArt: !!sec.showArt
        showAlbum: !!sec.showAlbum && width > 640
        striped: row.index % 2 === 1
        current: root.isCurrent(row.item)
        playing: root.am ? root.am.applePlaying : false
        glyphFont: root.iconFont
        accent: root.accent
        durationText: root.am ? root.am.formatTime(row.item.duration || 0) : ""
        onPlay: {
          if (current) root.am.playPause()
          else root.playTrack(sec, row.index)
        }
        onMenu: function(x, y) { root.showMenu(row.item, tr, x, y) }
      }
    }
  }

  Component {
    id: cardRow
    Item {
      readonly property var row: parent ? parent.modelData : ({ items: [] })
      height: rowInner.implicitHeight + 24
      Row {
        id: rowInner
        x: root.pagePad
        y: 12
        spacing: root.cardGap
        Repeater {
          model: row.items
          Card {
            id: gridCard
            required property var modelData
            width: root.cardWidth
            item: modelData
            glyphFont: root.iconFont
            accent: root.accent
            onOpen: function(it) { root.openItem(it) }
            onPlay: function(it) { root.playItem(it, 0) }
            onMenu: function(it, x, y) { root.showMenu(it, gridCard, x, y) }
          }
        }
      }
    }
  }

  Component {
    id: carouselRow
    Item {
      readonly property var row: parent ? parent.modelData : ({ items: [] })
      height: 170 + 60
      ListView {
        id: carousel
        anchors.fill: parent
        anchors.topMargin: 8
        orientation: ListView.Horizontal
        spacing: root.cardGap
        leftMargin: root.pagePad
        rightMargin: root.pagePad
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        model: row.items
        ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: Card {
          id: carouselCard
          required property var modelData
          width: 170
          item: modelData
          glyphFont: root.iconFont
          accent: root.accent
          onOpen: function(it) { root.openItem(it) }
          onPlay: function(it) { root.playItem(it, 0) }
          onMenu: function(it, x, y) { root.showMenu(it, carouselCard, x, y) }
        }
        // Vertical wheel scrolls the page, horizontal wheel the carousel.
        // Not interactive, so vertical wheel keeps scrolling the page;
        // horizontal / shift+wheel scrolls the carousel.
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function(ev) {
            var dx = ev.angleDelta.x
            if (ev.modifiers & Qt.ShiftModifier) dx = ev.angleDelta.y
            if (Math.abs(dx) > Math.abs(ev.angleDelta.y) || (ev.modifiers & Qt.ShiftModifier)) {
              var minX = carousel.originX - carousel.leftMargin
              var maxX = Math.max(minX, carousel.originX + carousel.contentWidth - carousel.width + carousel.rightMargin)
              carousel.contentX = Math.max(minX, Math.min(carousel.contentX - dx, maxX))
              ev.accepted = true
            } else ev.accepted = false
          }
        }
      }
    }
  }

  // ------------------------------------------------------- context menu
  Menu {
    id: contextMenu
    property var item: null
    readonly property string kind: item ? root.am.queueKind(item.type) : "song"
    readonly property bool isArtist: item && (item.type || "").indexOf("artist") !== -1

    palette.window: root.lcdBg
    palette.base: root.lcdBg
    palette.button: root.lcdBg
    palette.windowText: Color.foreground
    palette.text: Color.foreground
    palette.buttonText: Color.foreground
    palette.brightText: Color.foreground
    palette.highlight: root.accent
    palette.highlightedText: Color.background
    palette.light: root.separator
    palette.mid: root.separator
    palette.dark: root.separator

    MenuItem { text: "Play"; enabled: !contextMenu.isArtist; onTriggered: root.playItem(contextMenu.item, 0) }
    MenuItem { text: "Shuffle"; enabled: !contextMenu.isArtist && contextMenu.kind !== "song"; visible: enabled; height: visible ? implicitHeight : 0; onTriggered: root.playItem(contextMenu.item, 1) }
    MenuItem { text: "Play Next"; enabled: !contextMenu.isArtist; onTriggered: root.am.playNext(contextMenu.kind, contextMenu.item.id) }
    MenuItem { text: "Play Last"; enabled: !contextMenu.isArtist; onTriggered: root.am.playLater(contextMenu.kind, contextMenu.item.id) }
    MenuItem {
      text: "Open"
      visible: contextMenu.item && contextMenu.kind !== "song"
      height: visible ? implicitHeight : 0
      onTriggered: root.openItem(contextMenu.item)
    }
  }
}
