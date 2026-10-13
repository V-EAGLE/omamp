#!/usr/bin/env python3
"""Apple Music bridge for the OmAmp Omarchy shell plugin.

Runs music.apple.com as a Chromium web app with a private profile and drives
the page's MusicKit instance over the Chrome DevTools Protocol (CDP).

There is no DevTools TCP port. Two processes:

  amctl.py daemon   Long-lived, detached from the shell. Starts Chromium with
                    --remote-debugging-pipe, so CDP exists only as a pipe
                    inherited by this process, and relays CDP requests from a
                    Unix socket in $XDG_RUNTIME_DIR/omamp/ (directory 0700,
                    socket 0600). Every connection's peer UID is checked with
                    SO_PEERCRED; only the owning user is served. The daemon
                    exits when Chromium exits.
  amctl.py bridge   Started by the shell. Talks to the daemon over that socket
                    (verifying the daemon's UID too) and speaks newline JSON
                    with the shell:
                      stdin   {"cmd": "<name>", "args": {...}, "id": <optional int>}
                      stdout  {"type": "status"|"state"|"queue"|"result"|"error", ...}

Chromium and the daemon survive a shell restart, so playback isn't
interrupted; the new bridge reconnects to the same socket. Stdlib only.
"""

import fcntl
import json
import os
import queue
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import threading
import time

URL = "https://music.apple.com/"
WM_CLASS = "apple-music-web"
SPECIAL = "applemusic"
DATA_HOME = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
DATA = os.path.join(DATA_HOME, "omamp")
PROFILE = os.path.join(DATA, "chromium")
RUNTIME = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "omamp")
SOCKET_PATH = os.path.join(RUNTIME, "cdp.sock")
LOCK_PATH = os.path.join(RUNTIME, "daemon.lock")
POLL = 0.5

# Values that end up inside page JavaScript or Apple API paths.
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
QUEUE_KINDS = {"song", "songs", "album", "playlist", "station"}
CONTAINER_TYPES = {"library-playlists", "library-albums", "library-artists", "albums", "playlists", "artists"}


def emit(obj):
    try:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        os._exit(0)


def safe_id(value):
    value = str(value)
    if not SAFE_ID.match(value):
        raise ValueError("invalid id")
    return value


# ---------------------------------------------------------------- transport


def secure_dir(path):
    """Create `path` (0700) or make sure an existing one is ours and private."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise RuntimeError(f"refusing to use {path}: not a directory owned by this user")
    if stat.S_IMODE(st.st_mode) & 0o077:
        os.chmod(path, 0o700)


def peer_uid(sock):
    pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    return uid


def recv_line(sock, buf):
    """Return (line, rest) from a newline-delimited stream; line is None at EOF."""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None, b""
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    return line, rest


class DaemonClient:
    """CDP over the daemon's Unix socket. Both ends verify each other's UID."""

    def __init__(self, timeout=30):
        st = os.lstat(SOCKET_PATH)
        if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
            raise ConnectionError("daemon socket is not owned by this user")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(SOCKET_PATH)
            if peer_uid(self.sock) != os.getuid():
                raise ConnectionError("daemon runs as another user")
        except OSError:
            self.sock.close()
            raise
        self.buf = b""
        self.next_id = 0

    def request(self, method, params=None, scope="page"):
        self.next_id += 1
        mid = self.next_id
        msg = {"id": mid, "method": method, "params": params or {}, "scope": scope}
        self.sock.sendall(json.dumps(msg, separators=(",", ":")).encode() + b"\n")
        while True:
            line, self.buf = recv_line(self.sock, self.buf)
            if line is None:
                raise ConnectionError("daemon closed the connection")
            reply = json.loads(line)
            if reply.get("id") == mid:
                return reply

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def daemon_info():
    """{"pid", "page"} from a running daemon, or None."""
    try:
        client = DaemonClient(timeout=3)
    except (OSError, ConnectionError):
        return None
    try:
        return client.request("omamp.info", scope="daemon").get("result")
    except (OSError, ConnectionError, ValueError):
        return None
    finally:
        client.close()


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
        return f"await mk.seekToTime({max(0.0, float(a.get('time', 0)))}); return true;"
    if cmd == "volume":
        return f"mk.volume = Math.max(0, Math.min(1, {float(a.get('value', 1))})); return true;"
    if cmd == "shuffle":
        return f"mk.shuffleMode = {int(a.get('mode', 0))}; return true;"
    if cmd == "repeat":
        return f"mk.repeatMode = {int(a.get('mode', 0))}; return true;"
    if cmd == "jump":
        return f"await mk.changeToMediaAtIndex({max(0, int(a.get('index', 0)))}); return true;"
    if cmd == "setQueue":
        # args: {kind: song|album|playlist|station|songs, id | ids, startWith, shuffle}
        kind = a.get("kind", "song")
        if kind not in QUEUE_KINDS:
            raise ValueError("invalid queue kind")
        if kind == "songs":
            ids = a.get("ids")
            if not isinstance(ids, list) or not ids:
                raise ValueError("invalid ids")
            opts = {kind: [safe_id(i) for i in ids[:500]]}
        else:
            opts = {kind: safe_id(a.get("id"))}
        if "startWith" in a:
            opts["startWith"] = max(0, int(a["startWith"]))
        return (f"mk.shuffleMode = {1 if int(a.get('shuffle', 0)) else 0}; await mk.setQueue({j(opts)}); "
                "await mk.play(); return true;")
    if cmd in ("playNext", "playLater"):
        kind = a.get("kind", "song")
        if kind not in QUEUE_KINDS - {"songs"}:
            raise ValueError("invalid queue kind")
        return f"await mk.{cmd}({j({kind: safe_id(a.get('id'))})}); return true;"
    if cmd == "library":
        section = a.get("section", "playlists")
        if section not in LIBRARY_PATHS:
            raise ValueError("invalid library section")
        path, limit, cap = LIBRARY_PATHS[section]
        size = 120 if section == "songs" else 300
        return (HELPERS_JS + f"const rows = await all({j(path)}, {j({'limit': limit})}, {cap}); "
                f"return rows.map(r => norm(r, {size}));")
    if cmd == "container":
        if a.get("type") not in CONTAINER_TYPES:
            raise ValueError("invalid container type")
        args = {"type": a["type"], "id": safe_id(a.get("id"))}
        return HELPERS_JS + f"const ARGS = {j(args)};" + CONTAINER_JS
    if cmd == "home":
        return HELPERS_JS + HOME_JS
    if cmd == "search":
        args = {"term": str(a.get("term", ""))[:200],
                "scope": "library" if a.get("scope") == "library" else "catalog"}
        return HELPERS_JS + f"const ARGS = {j(args)};" + SEARCH_JS
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


def chromium_binary():
    for name in ("chromium", "google-chrome-stable", "brave"):
        path = shutil.which(name)
        if path:
            return path
    return None


def launch_browser():
    """Start the daemon (which starts Chromium), fully detached from the shell."""
    if not chromium_binary():
        emit({"type": "error", "message": "chromium not found"})
        return False
    subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "daemon"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)
    return True


class BrowserDaemon:
    """Owns Chromium's CDP pipe and serves it to same-user clients."""

    def __init__(self):
        self.write_lock = threading.Lock()
        self.pending = {}            # browser message id -> [Event, reply]
        self.pending_lock = threading.Lock()
        self.next_id = 0
        self.session = None
        self.session_lock = threading.Lock()
        self.proc = None
        self.to_browser = None
        self.from_browser = None

    # -- Chromium --------------------------------------------------------

    def start_browser(self):
        binary = chromium_binary()
        if not binary:
            raise RuntimeError("chromium not found")
        r1, w1 = os.pipe()  # daemon -> browser (browser fd 3)
        r2, w2 = os.pipe()  # browser -> daemon (browser fd 4)

        def child_fds():
            # Move both ends out of the way first so dup2 can't clobber one.
            a = fcntl.fcntl(r1, fcntl.F_DUPFD, 10)
            b = fcntl.fcntl(w2, fcntl.F_DUPFD, 10)
            os.dup2(a, 3)
            os.dup2(b, 4)

        args = [
            binary,
            f"--user-data-dir={PROFILE}",
            "--remote-debugging-pipe",
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
        # OMAMP_LOG=<file> keeps Chromium's output for debugging.
        log = open(os.environ["OMAMP_LOG"], "ab") if os.environ.get("OMAMP_LOG") else subprocess.DEVNULL
        self.proc = subprocess.Popen(args, pass_fds=(3, 4), preexec_fn=child_fds,
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        os.close(r1)
        os.close(w2)
        self.to_browser, self.from_browser = w1, r2

    def browser_reader(self):
        buf = b""
        while True:
            try:
                chunk = os.read(self.from_browser, 1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
            while b"\0" in buf:
                raw, buf = buf.split(b"\0", 1)
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if "id" in msg:
                    with self.pending_lock:
                        slot = self.pending.pop(msg["id"], None)
                    if slot:
                        slot[1] = msg
                        slot[0].set()
                elif msg.get("method") in ("Target.detachedFromTarget", "Target.targetDestroyed"):
                    with self.session_lock:
                        self.session = None
        # Pipe closed: Chromium is gone; wake everybody waiting.
        with self.pending_lock:
            for slot in self.pending.values():
                slot[0].set()
            self.pending.clear()

    def browser_call(self, method, params=None, session=None, timeout=60):
        with self.pending_lock:
            self.next_id += 1
            mid = self.next_id
            slot = [threading.Event(), None]
            self.pending[mid] = slot
        msg = {"id": mid, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        data = json.dumps(msg, separators=(",", ":")).encode() + b"\0"
        with self.write_lock:
            view = memoryview(data)
            while view:
                n = os.write(self.to_browser, view)
                view = view[n:]
        if not slot[0].wait(timeout) or slot[1] is None:
            with self.pending_lock:
                self.pending.pop(mid, None)
            raise ConnectionError(f"no reply to {method}")
        return slot[1]

    def page_session(self):
        """Attach (flattened) to the Apple Music page target once and reuse it."""
        with self.session_lock:
            if self.session:
                return self.session
            targets = self.browser_call("Target.getTargets").get("result", {}).get("targetInfos", [])
            pages = [t for t in targets if t.get("type") == "page"]
            page = next((t for t in pages if "music.apple.com" in t.get("url", "")), pages[0] if pages else None)
            if not page:
                return None
            reply = self.browser_call("Target.attachToTarget", {"targetId": page["targetId"], "flatten": True})
            self.session = reply.get("result", {}).get("sessionId")
            return self.session

    # -- clients ---------------------------------------------------------

    def serve_client(self, conn):
        try:
            if peer_uid(conn) != os.getuid():
                return
            conn.settimeout(None)
            buf = b""
            while True:
                line, buf = recv_line(conn, buf)
                if line is None:
                    return
                try:
                    req = json.loads(line)
                    cid = req["id"]
                    method = str(req["method"])
                    params = req.get("params") or {}
                    scope = req.get("scope", "page")
                except (ValueError, KeyError, TypeError):
                    continue
                try:
                    if scope == "daemon" and method == "omamp.quit":
                        # SIGTERM is Chromium's clean shutdown; CDP Browser.close
                        # trips an internal assertion (SIGTRAP) in --app mode.
                        self.proc.terminate()
                        reply = {"result": {}}
                    elif scope == "daemon" and method == "omamp.info":
                        try:
                            ready = self.page_session() is not None
                        except ConnectionError:
                            ready = False
                        reply = {"result": {"pid": self.proc.pid, "page": ready}}
                    elif scope == "browser":
                        reply = self.browser_call(method, params)
                    else:
                        session = self.page_session()
                        if not session:
                            reply = {"error": {"message": "Apple Music page not ready"}}
                        else:
                            reply = self.browser_call(method, params, session=session)
                            if reply.get("error") and "session" in str(reply["error"].get("message", "")).lower():
                                with self.session_lock:
                                    self.session = None
                except ConnectionError as e:
                    reply = {"error": {"message": str(e)}}
                reply = dict(reply)
                reply.pop("sessionId", None)
                reply["id"] = cid
                conn.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")
        except OSError:
            pass
        finally:
            conn.close()

    def run(self):
        secure_dir(RUNTIME)
        lock = open(LOCK_PATH, "w")
        os.chmod(LOCK_PATH, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # another daemon already owns the browser
        secure_dir(DATA)
        secure_dir(PROFILE)
        self.start_browser()
        threading.Thread(target=self.browser_reader, daemon=True).start()

        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old_umask = os.umask(0o177)
        try:
            server.bind(SOCKET_PATH)
        finally:
            os.umask(old_umask)
        os.chmod(SOCKET_PATH, 0o600)
        server.listen(8)
        server.settimeout(1.0)
        try:
            while self.proc.poll() is None:
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=self.serve_client, args=(conn,), daemon=True).start()
        finally:
            server.close()
            try:
                os.unlink(SOCKET_PATH)
            except FileNotFoundError:
                pass


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


def window_address(w):
    addr = str(w.get("address", ""))
    return addr if re.fullmatch(r"0x[0-9a-fA-F]+", addr) else None


def hide_window():
    w = browser_window()
    if w and not window_address(w):
        return
    if w and not str(w.get("workspace", {}).get("name", "")).startswith("special:"):
        hypr_eval(f'hl.dispatch(hl.dsp.window.move({{ workspace = "special:{SPECIAL}", follow = false, window = "address:{w["address"]}" }}))')


def show_window():
    w = browser_window()
    if not w or not window_address(w):
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
        self.ws = None   # DaemonClient while connected
        self.last_state = None
        self.last_queue_sig = None
        self.status = None
        self.launched_at = 0
        self.hide_after_auth = False
        self.drm = None
        self.drm_checked_at = 0
        self.drm_restarted = False
        self.drm_failures = 0
        self.pid = 0

    def set_status(self, **kw):
        status = {"type": "status", "browser": False, "connected": False, "ready": False, "authorized": False, "drm": None,
                  "pid": self.pid if kw.get("connected") else 0}
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
        if not os.path.exists(SOCKET_PATH):
            return False
        try:
            client = DaemonClient()
            info = client.request("omamp.info", scope="daemon").get("result") or {}
        except (OSError, ConnectionError, ValueError):
            return False
        if not info.get("page"):
            client.close()
            return False
        self.ws = client
        self.pid = int(info.get("pid") or 0)
        return True

    def call(self, method, params, scope="page"):
        return self.ws.request(method, params, scope=scope)

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
                if not daemon_info():
                    self.hide_after_auth = bool(args.get("hidden", True))
                    self.launched_at = time.time()
                    launch_browser()
                else:
                    show_window() if not args.get("hidden", True) else None
                result = True
            elif cmd == "showWeb":
                result = show_window()
                if not result and not daemon_info():
                    self.hide_after_auth = False
                    self.launched_at = time.time()
                    result = launch_browser()
            elif cmd == "hideWeb":
                hide_window()
                result = True
            elif cmd == "quit":
                if self.ws:
                    try:
                        self.call("omamp.quit", {}, scope="daemon")
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
        # EME can report "unsupported" for a moment while the page settles, so
        # only a second failed check (15 s later) triggers the restart.
        self.drm_failures = 0 if self.drm else self.drm_failures + 1
        if self.drm_failures >= 2 and widevine_downloaded() and not self.drm_restarted:
            self.restart_browser()

    def restart_browser(self):
        """Relaunch Chromium once so it loads a freshly downloaded Widevine."""
        self.drm_restarted = True
        emit({"type": "error", "message": "restarting web player to load Widevine"})
        try:
            self.call("omamp.quit", {}, scope="daemon")
        except Exception:
            pass
        self.disconnect()
        for _ in range(40):
            if not os.path.exists(SOCKET_PATH):
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
                    self.set_status(browser=os.path.exists(SOCKET_PATH) or (time.time() - self.launched_at) < 15)
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
    if len(sys.argv) > 1 and sys.argv[1] == "daemon":
        BrowserDaemon().run()
        return
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
