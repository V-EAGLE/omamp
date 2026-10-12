#!/usr/bin/env python3
"""Apple Music bridge for the OmAmp Omarchy shell plugin.

Runs music.apple.com as a Chromium web app with a private profile and the
DevTools protocol on localhost, and drives the page's MusicKit instance.

Protocol (newline-delimited JSON):
  stdin   {"cmd": "<name>", "args": {...}, "id": <optional int>}
  stdout  {"type": "status"|"state"|"queue"|"result"|"error", ...}

Stdlib only. Chromium keeps running when the bridge exits, so a shell restart
reconnects to the same session without interrupting playback.
"""

import base64
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request

PORT = int(os.environ.get("AM_DEBUG_PORT", "9339"))
URL = "https://music.apple.com/"
WM_CLASS = "apple-music-web"
SPECIAL = "applemusic"
DATA_HOME = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
DATA = os.path.join(DATA_HOME, "omamp")
PROFILE = os.path.join(DATA, "chromium")
POLL = 0.5


def emit(obj):
    try:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        os._exit(0)


# ---------------------------------------------------------------- websocket


class WebSocket:
    """Just enough RFC 6455 client for a localhost DevTools socket."""

    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake closed")
            buf += chunk
        head, self.pending = buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError("websocket handshake refused: " + head.split(b"\r\n", 1)[0].decode())

    def _read(self, n):
        while len(self.pending) < n:
            chunk = self.sock.recv(max(65536, n - len(self.pending)))
            if not chunk:
                raise ConnectionError("websocket closed")
            self.pending += chunk
        out, self.pending = self.pending[:n], self.pending[n:]
        return out

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + body)

    def send(self, text):
        self._send_frame(0x1, text.encode())

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._read(2)
            opcode = b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise ConnectionError("websocket closed by peer")
            if opcode == 0x9:
                self._send_frame(0xA, data)
                continue
            if opcode in (0x0, 0x1, 0x2):
                message += data
                if b1 & 0x80:
                    return message.decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------- page JS

STATE_JS = r"""
(() => {
  const MK = window.MusicKit;
  let mk = null;
  try { mk = MK && MK.getInstance(); } catch (e) {}
  if (!mk) return { ready: false };
  const art = (a, s) => a && a.url ? a.url.replace('{w}', s).replace('{h}', s).replace('{f}', 'jpg').replace('{c}', '') : '';
  const it = mk.nowPlayingItem;
  const q = mk.queue;
  const items = q && q.items ? q.items : [];
  let sig = String(items.length);
  if (items.length) sig += ':' + items[0].id + ':' + items[items.length - 1].id;
  return {
    ready: true,
    authorized: !!mk.isAuthorized,
    storefront: mk.storefrontId || '',
    playing: !!mk.isPlaying,
    playbackState: mk.playbackState,
    time: mk.currentPlaybackTime || 0,
    duration: mk.currentPlaybackDuration || (it ? (it.playbackDuration || 0) / 1000 : 0),
    volume: mk.volume,
    shuffle: mk.shuffleMode,
    repeat: mk.repeatMode,
    position: q ? q.position : -1,
    queueSig: sig,
    item: it ? {
      id: String(it.id || ''),
      catalogId: String((it.playParams && (it.playParams.catalogId || it.playParams.id)) || it.id || ''),
      title: it.title || it.attributes?.name || '',
      artist: it.artistName || it.attributes?.artistName || '',
      album: it.albumName || it.attributes?.albumName || '',
      art: art(it.artwork || it.attributes?.artwork, 600),
      color: (it.artwork || it.attributes?.artwork || {}).bgColor || '',
      explicit: it.attributes?.contentRating === 'explicit'
    } : null
  };
})()
"""

QUEUE_JS = r"""
(() => {
  const mk = MusicKit.getInstance();
  const art = (a, s) => a && a.url ? a.url.replace('{w}', s).replace('{h}', s).replace('{f}', 'jpg').replace('{c}', '') : '';
  const items = mk.queue && mk.queue.items ? mk.queue.items : [];
  return items.slice(0, 500).map((it, i) => ({
    index: i,
    id: String(it.id || ''),
    title: it.title || it.attributes?.name || '',
    artist: it.artistName || it.attributes?.artistName || '',
    album: it.albumName || it.attributes?.albumName || '',
    art: art(it.artwork || it.attributes?.artwork, 120),
    duration: (it.playbackDuration || it.attributes?.durationInMillis || 0) / 1000
  }));
})()
"""

# Shared page-side helpers for library/catalog requests: normalize API
# resources into flat rows and follow `next` offsets for paged endpoints.
HELPERS_JS = r"""
const sf = mk.storefrontId || 'us';
const art = (a, s) => a && a.url ? a.url.replace('{w}', s).replace('{h}', s).replace('{f}', 'jpg').replace('{c}', '') : '';
const norm = (r, s) => {
  const a = r.attributes || {};
  const pp = a.playParams || {};
  return {
    id: String(r.id), type: r.type, name: a.name || '',
    artist: a.artistName || a.curatorName || '',
    album: a.albumName || '',
    art: art(a.artwork, s || 300),
    color: (a.artwork || {}).bgColor || '',
    duration: (a.durationInMillis || 0) / 1000,
    track: a.trackNumber || 0, disc: a.discNumber || 1,
    explicit: a.contentRating === 'explicit',
    kind: pp.kind || '', playable: !!a.playParams,
    catalogId: String(pp.catalogId || (pp.isLibrary ? '' : pp.id) || ''),
    description: (a.description && (a.description.short || a.description.standard)) || (a.editorialNotes && (a.editorialNotes.short || a.editorialNotes.standard)) || '',
    date: a.releaseDate || a.dateAdded || '',
    genre: (a.genreNames || [])[0] || '',
    count: a.trackCount || 0
  };
};
const all = async (path, params, max) => {
  let out = [], off = 0;
  for (let i = 0; i < 100; i++) {
    const r = await mk.api.music(path, Object.assign({}, params || {}, off ? { offset: off } : {}));
    const d = r.data || {};
    const items = d.data || [];
    out = out.concat(items);
    if (!d.next || !items.length || out.length >= max) break;
    const m = /offset=(\d+)/.exec(d.next);
    if (!m) break;
    off = +m[1];
  }
  return out.slice(0, max);
};
"""

CONTAINER_JS = r"""
const t = ARGS.type, id = ARGS.id;
const lib = t.startsWith('library-');
let info = null, tracks = [], albums = [];
if (t === 'library-playlists') {
  info = (await mk.api.music(`/v1/me/library/playlists/${id}`)).data.data[0];
  tracks = await all(`/v1/me/library/playlists/${id}/tracks`, { limit: 100 }, 2000);
} else if (t === 'library-albums') {
  info = (await mk.api.music(`/v1/me/library/albums/${id}`)).data.data[0];
  tracks = await all(`/v1/me/library/albums/${id}/tracks`, { limit: 100 }, 500);
} else if (t === 'albums') {
  info = (await mk.api.music(`/v1/catalog/${sf}/albums/${id}`)).data.data[0];
  tracks = await all(`/v1/catalog/${sf}/albums/${id}/tracks`, { limit: 100 }, 500);
} else if (t === 'playlists') {
  info = (await mk.api.music(`/v1/catalog/${sf}/playlists/${id}`)).data.data[0];
  tracks = await all(`/v1/catalog/${sf}/playlists/${id}/tracks`, { limit: 100 }, 1000);
} else if (t === 'library-artists') {
  info = (await mk.api.music(`/v1/me/library/artists/${id}`)).data.data[0];
  albums = await all(`/v1/me/library/artists/${id}/albums`, { limit: 100 }, 300);
} else if (t === 'artists') {
  info = (await mk.api.music(`/v1/catalog/${sf}/artists/${id}`)).data.data[0];
  try { tracks = (await mk.api.music(`/v1/catalog/${sf}/artists/${id}/view/top-songs`, { limit: 20 })).data.data || []; } catch (e) {}
  albums = await all(`/v1/catalog/${sf}/artists/${id}/albums`, { limit: 100 }, 300);
} else {
  throw new Error('unsupported container ' + t);
}
return { info: info ? norm(info, 600) : null, tracks: tracks.map(r => norm(r, 120)), albums: albums.map(r => norm(r, 300)) };
"""

HOME_JS = r"""
const groups = [];
try {
  const recent = (await mk.api.music('/v1/me/recent/played', { limit: 10 })).data.data || [];
  if (recent.length) groups.push({ title: 'Recently Played', items: recent.map(r => norm(r, 300)) });
} catch (e) {}
try {
  const recs = (await mk.api.music('/v1/me/recommendations', { limit: 12 })).data.data || [];
  for (const g of recs) {
    const a = g.attributes || {};
    const title = (a.title && (a.title.stringForDisplay || a.title.contentIds)) || a.reason?.stringForDisplay || 'For You';
    const items = ((g.relationships && g.relationships.contents && g.relationships.contents.data) || []).filter(r => r.attributes);
    if (items.length) groups.push({ title, items: items.map(r => norm(r, 300)) });
  }
} catch (e) {}
return groups;
"""

SEARCH_JS = r"""
const term = ARGS.term || '';
const out = { songs: [], albums: [], artists: [], playlists: [] };
if (!term.trim()) return out;
if (ARGS.scope === 'library') {
  const r = (await mk.api.music('/v1/me/library/search', { term, types: 'library-songs,library-albums,library-artists,library-playlists', limit: 25 })).data.results || {};
  out.songs = (r['library-songs']?.data || []).map(x => norm(x, 120));
  out.albums = (r['library-albums']?.data || []).map(x => norm(x, 300));
  out.artists = (r['library-artists']?.data || []).map(x => norm(x, 300));
  out.playlists = (r['library-playlists']?.data || []).map(x => norm(x, 300));
} else {
  const r = (await mk.api.music(`/v1/catalog/${sf}/search`, { term, types: 'songs,albums,artists,playlists', limit: 25 })).data.results || {};
  out.songs = (r.songs?.data || []).map(x => norm(x, 120));
  out.albums = (r.albums?.data || []).map(x => norm(x, 300));
  out.artists = (r.artists?.data || []).map(x => norm(x, 300));
  out.playlists = (r.playlists?.data || []).map(x => norm(x, 300));
}
return out;
"""

LIBRARY_PATHS = {
    "playlists": ("/v1/me/library/playlists", 100, 1000),
    "recent": ("/v1/me/library/recently-added", 25, 100),
    "albums": ("/v1/me/library/albums", 100, 3000),
    "artists": ("/v1/me/library/artists", 100, 3000),
    "songs": ("/v1/me/library/songs", 100, 5000),
}


def js_command(cmd, a):
    """Return the body of an async function (with `mk` in scope) for a command, or None."""
    j = json.dumps
    if cmd == "playPause":
        return "if (mk.isPlaying) mk.pause(); else await mk.play(); return true;"
    if cmd == "play":
        return "await mk.play(); return true;"
    if cmd == "pause":
        return "mk.pause(); return true;"
    if cmd == "next":
        return "await mk.skipToNextItem(); return true;"
    if cmd == "previous":
        return "if (mk.currentPlaybackTime > 3) await mk.seekToTime(0); else await mk.skipToPreviousItem(); return true;"
    if cmd == "seek":
        return f"await mk.seekToTime({float(a.get('time', 0))}); return true;"
    if cmd == "volume":
        return f"mk.volume = Math.max(0, Math.min(1, {float(a.get('value', 1))})); return true;"
    if cmd == "shuffle":
        return f"mk.shuffleMode = {int(a.get('mode', 0))}; return true;"
    if cmd == "repeat":
        return f"mk.repeatMode = {int(a.get('mode', 0))}; return true;"
    if cmd == "jump":
        return f"await mk.changeToMediaAtIndex({int(a.get('index', 0))}); return true;"
    if cmd == "setQueue":
        # args: {kind: song|album|playlist|station|songs, id | ids, startWith, shuffle}
        kind = a.get("kind", "song")
        opts = {kind: a.get("ids") if kind == "songs" else a.get("id")}
        if "startWith" in a:
            opts["startWith"] = int(a["startWith"])
        return (f"mk.shuffleMode = {int(a.get('shuffle', 0))}; await mk.setQueue({j(opts)}); "
                "await mk.play(); return true;")
    if cmd == "playNext":
        return f"await mk.playNext({j({a.get('kind', 'song'): a.get('id')})}); return true;"
    if cmd == "playLater":
        return f"await mk.playLater({j({a.get('kind', 'song'): a.get('id')})}); return true;"
    if cmd == "api":
        return f"const r = await mk.api.music({j(a.get('path', ''))}, {j(a.get('params') or {})}); return r.data;"
    if cmd == "rate":
        # value: 1 love, -1 dislike, 0 clear
        path = f"/v1/me/ratings/{a.get('kind', 'songs')}/{a.get('id')}"
        val = int(a.get("value", 0))
        if val == 0:
            return f"await mk.api.music({j(path)}, {{}}, {{ fetchOptions: {{ method: 'DELETE' }} }}); return 0;"
        body = j({"type": "rating", "attributes": {"value": val}})
        return (f"await mk.api.music({j(path)}, {{}}, {{ fetchOptions: {{ method: 'PUT', "
                f"headers: {{ 'Content-Type': 'application/json' }}, body: {j(body)} }} }}); return {val};")
    if cmd == "library":
        path, limit, cap = LIBRARY_PATHS[a.get("section", "playlists")]
        params = {"limit": limit}
        size = 120 if a.get("section") == "songs" else 300
        return (HELPERS_JS + f"const rows = await all({j(path)}, {j(params)}, {int(a.get('max', cap))}); "
                f"return rows.map(r => norm(r, {size}));")
    if cmd == "container":
        return HELPERS_JS + f"const ARGS = {j(a)};" + CONTAINER_JS
    if cmd == "home":
        return HELPERS_JS + HOME_JS
    if cmd == "search":
        return HELPERS_JS + f"const ARGS = {j(a)};" + SEARCH_JS
    if cmd == "authorize":
        return "await mk.authorize(); return true;"
    return None


def wrap(body):
    return "(async () => { const mk = MusicKit.getInstance(); " + body + " })()"


# Apple Music needs Widevine for full tracks; without it MusicKit quietly
# falls back to 90-second previews.
DRM_JS = r"""
(async () => {
  try {
    await navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
      initDataTypes: ['cenc'],
      audioCapabilities: [{ contentType: 'audio/mp4;codecs="mp4a.40.2"' }]
    }]);
    return true;
  } catch (e) { return false; }
})()
"""

# ---------------------------------------------------------------- browser


def debug_targets():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=1.5) as r:
        return json.load(r)


def find_page():
    try:
        targets = debug_targets()
    except OSError:
        return None
    pages = [t for t in targets if t.get("type") == "page" and "webSocketDebuggerUrl" in t]
    for t in pages:
        if "music.apple.com" in t.get("url", ""):
            return t
    return pages[0] if pages else None


def chromium_binary():
    for name in ("chromium", "google-chrome-stable", "brave"):
        path = shutil.which(name)
        if path:
            return path
    return None


def launch_browser():
    binary = chromium_binary()
    if not binary:
        emit({"type": "error", "message": "chromium not found"})
        return False
    os.makedirs(PROFILE, exist_ok=True)
    args = [
        binary,
        f"--user-data-dir={PROFILE}",
        f"--remote-debugging-port={PORT}",
        "--remote-debugging-address=127.0.0.1",
        f"--class={WM_CLASS}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        "--autoplay-policy=no-user-gesture-required",
        f"--app={URL}",
    ]
    if os.environ.get("WAYLAND_DISPLAY"):
        args.insert(1, "--ozone-platform=wayland")
    launcher = ["uwsm-app", "--"] if shutil.which("uwsm-app") else []
    subprocess.Popen(launcher + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def widevine_downloaded():
    # Chromium's component updater fetches Widevine into the profile after the
    # first start, but only loads a CDM at browser startup.
    return os.path.isfile(os.path.join(PROFILE, "WidevineCdm", "latest-component-updated-widevine-cdm"))


def hypr_eval(lua):
    try:
        subprocess.run(["hyprctl", "eval", lua], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        pass


def browser_window():
    try:
        out = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=3).stdout
        for c in json.loads(out or "[]"):
            if WM_CLASS in c.get("initialClass", "") or "music.apple.com" in c.get("initialClass", ""):
                return c
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def hide_window():
    w = browser_window()
    if w and not str(w.get("workspace", {}).get("name", "")).startswith("special:"):
        hypr_eval(f'hl.dispatch(hl.dsp.window.move({{ workspace = "special:{SPECIAL}", follow = false, window = "address:{w["address"]}" }}))')


def show_window():
    w = browser_window()
    if not w:
        return False
    name = str(w.get("workspace", {}).get("name", ""))
    if name.startswith("special:"):
        hypr_eval(f'hl.dispatch(hl.dsp.window.move({{ workspace = "e+0", window = "address:{w["address"]}" }}))')
    hypr_eval(f'hl.dispatch(hl.dsp.focus({{ window = "address:{w["address"]}" }}))')
    return True


# ---------------------------------------------------------------- bridge


class Bridge:
    def __init__(self):
        self.commands = queue.Queue()
        self.ws = None
        self.msg_id = 0
        self.last_state = None
        self.last_queue_sig = None
        self.status = None
        self.launched_at = 0
        self.hide_after_auth = False
        self.drm = None
        self.drm_checked_at = 0
        self.drm_restarted = False

    def set_status(self, **kw):
        status = {"type": "status", "browser": False, "connected": False, "ready": False, "authorized": False, "drm": None}
        status.update(kw)
        if status != self.status:
            self.status = status
            emit(status)

    def disconnect(self):
        if self.ws:
            self.ws.close()
        self.ws = None
        self.last_state = None
        self.last_queue_sig = None
        self.drm = None
        self.drm_checked_at = 0

    def connect(self):
        page = find_page()
        if not page:
            return False
        try:
            self.ws = WebSocket(page["webSocketDebuggerUrl"])
            self.ws.sock.settimeout(20)
        except (OSError, ConnectionError) as e:
            emit({"type": "error", "message": f"connect failed: {e}"})
            self.ws = None
            return False
        return True

    def call(self, method, params):
        self.msg_id += 1
        mid = self.msg_id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                return msg

    def evaluate(self, expr, await_promise=False):
        res = self.call("Runtime.evaluate", {
            "expression": expr,
            "returnByValue": True,
            "awaitPromise": await_promise,
            "userGesture": True,
        })
        if "error" in res:
            raise RuntimeError(res["error"].get("message", "evaluate failed"))
        result = res.get("result", {})
        if "exceptionDetails" in result:
            ex = result["exceptionDetails"]
            text = ex.get("exception", {}).get("description") or ex.get("text", "exception")
            raise RuntimeError(text.split("\n")[0])
        return result.get("result", {}).get("value")

    def handle(self, msg):
        cmd = msg.get("cmd", "")
        args = msg.get("args") or {}
        rid = msg.get("id")
        try:
            if cmd == "launch":
                if not find_page():
                    self.hide_after_auth = bool(args.get("hidden", True))
                    self.launched_at = time.time()
                    launch_browser()
                else:
                    show_window() if not args.get("hidden", True) else None
                result = True
            elif cmd == "showWeb":
                result = show_window()
                if not result and not find_page():
                    self.hide_after_auth = False
                    self.launched_at = time.time()
                    result = launch_browser()
            elif cmd == "hideWeb":
                hide_window()
                result = True
            elif cmd == "quit":
                if self.ws:
                    try:
                        self.call("Browser.close", {})
                    except Exception:
                        pass
                self.disconnect()
                result = True
            else:
                spec = js_command(cmd, args)
                if spec is None:
                    raise RuntimeError(f"unknown command {cmd}")
                if not self.ws:
                    raise RuntimeError("Apple Music is not running")
                result = self.evaluate(wrap(spec), True)
            if rid is not None:
                emit({"type": "result", "id": rid, "ok": True, "data": result})
        except (ConnectionError, OSError) as e:
            self.disconnect()
            if rid is not None:
                emit({"type": "result", "id": rid, "ok": False, "error": str(e)})
        except Exception as e:
            if rid is not None:
                emit({"type": "result", "id": rid, "ok": False, "error": str(e)})
            else:
                emit({"type": "error", "message": f"{cmd}: {e}"})
        self.last_state = None  # force a fresh state push after any command

    def poll(self):
        state = self.evaluate(STATE_JS)
        if not state or not state.get("ready"):
            self.set_status(browser=True, connected=True)
            return
        if state.get("authorized"):
            self.check_drm()
        self.set_status(browser=True, connected=True, ready=True, authorized=state.get("authorized", False), drm=self.drm)
        if state.get("authorized") and self.hide_after_auth:
            self.hide_after_auth = False
            hide_window()
        sig = state.pop("queueSig", "")
        if sig != self.last_queue_sig:
            self.last_queue_sig = sig
            emit({"type": "queue", "items": self.evaluate(QUEUE_JS) or []})
        if state != self.last_state:
            self.last_state = state
            emit(dict(state, type="state"))

    def check_drm(self):
        if self.drm or time.time() - self.drm_checked_at < 15:
            return
        self.drm_checked_at = time.time()
        self.drm = bool(self.evaluate(DRM_JS, True))
        if not self.drm and widevine_downloaded() and not self.drm_restarted:
            self.restart_browser()

    def restart_browser(self):
        """Relaunch Chromium once so it loads a freshly downloaded Widevine."""
        self.drm_restarted = True
        emit({"type": "error", "message": "restarting web player to load Widevine"})
        try:
            self.call("Browser.close", {})
        except Exception:
            pass
        self.disconnect()
        for _ in range(40):
            if not find_page():
                break
            time.sleep(0.25)
        self.hide_after_auth = True
        self.launched_at = time.time()
        launch_browser()
        raise ConnectionError("web player restarting")

    def stdin_reader(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.commands.put(json.loads(line))
            except ValueError:
                emit({"type": "error", "message": "bad json on stdin"})
        os._exit(0)

    def run(self):
        threading.Thread(target=self.stdin_reader, daemon=True).start()
        next_poll = 0
        while True:
            timeout = max(0, next_poll - time.time())
            try:
                msg = self.commands.get(timeout=timeout)
            except queue.Empty:
                msg = None

            if not self.ws:
                if not self.connect():
                    self.set_status(browser=find_page() is not None or (time.time() - self.launched_at) < 15)
                    if msg:
                        self.handle(msg)
                    next_poll = time.time() + 1.0
                    continue

            if msg:
                self.handle(msg)
                continue

            try:
                self.poll()
            except (ConnectionError, OSError):
                self.disconnect()
                self.set_status()
            except Exception as e:
                emit({"type": "error", "message": f"poll: {e}"})
            next_poll = time.time() + POLL


def main():
    if len(sys.argv) > 1 and sys.argv[1] != "bridge":
        # One-shot CLI: amctl.py <cmd> ['{json args}']
        args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        b = Bridge()
        if sys.argv[1] in ("launch", "showWeb", "hideWeb"):
            b.handle({"cmd": sys.argv[1], "args": args, "id": 0})
            return
        if not b.connect():
            print("Apple Music is not running", file=sys.stderr)
            sys.exit(1)
        if sys.argv[1] == "state":
            print(json.dumps(b.evaluate(STATE_JS), indent=2))
        elif sys.argv[1] == "queue":
            print(json.dumps(b.evaluate(QUEUE_JS), indent=2))
        else:
            b.handle({"cmd": sys.argv[1], "args": args, "id": 0})
        return
    Bridge().run()


if __name__ == "__main__":
    main()
