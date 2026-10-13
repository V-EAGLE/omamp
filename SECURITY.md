# Security

OmAmp runs inside the Omarchy shell like every plugin, unsandboxed, with your
user's permissions. This page covers what it adds on top of that.

## Any MPRIS player

OmAmp reads and controls players over your D-Bus session bus through
Quickshell's MPRIS service. It opens no ports and writes no files for this.
Player-supplied text (titles, artists, albums) is always rendered as plain
text, and cover art is only loaded from `https:`, `http:` or `file:` URLs.

At startup the service runs `sh -c 'command -v spotify tidal-hifi'` once, to
know which apps the launcher buttons can open. The launchers run only when you
click them: `spotify` or `tidal-hifi` through `uwsm-app`, otherwise the
service's web page through `omarchy-launch-webapp`.

## Apple Music

Apple Music has no Linux app, so OmAmp drives music.apple.com in Chromium over
the Chrome DevTools Protocol (CDP). CDP can control the signed-in browser and
read its cookies, so access to it is the asset to protect.

**Transport**

- No DevTools TCP port. `amctl.py daemon` starts Chromium with
  `--remote-debugging-pipe`; CDP is a pair of pipes inherited only by the
  daemon.
- The daemon relays CDP from a Unix socket at
  `$XDG_RUNTIME_DIR/omamp/cdp.sock`. `$XDG_RUNTIME_DIR` is private to your
  user; the `omamp` directory is `0700` and the socket `0600`. The directory
  is checked to be a real directory owned by you before use.
- Each connection's peer user ID is read with `SO_PEERCRED`; connections from
  any other UID are closed without being served. The bridge in turn checks
  that the socket file and the daemon process belong to you.
- A lock file keeps a single daemon per user. The daemon and the socket go
  away when Chromium exits.

**Inputs**

- The shell talks to `amctl.py bridge` over its stdin/stdout only.
- IDs, page types, queue kinds and the search scope are validated against
  allow-lists before they reach page JavaScript or Apple API paths; strings
  are embedded as JSON. There is no command that runs arbitrary JavaScript or
  arbitrary Apple API requests.
- Window addresses passed to `hyprctl eval` must look like `0x…`.

**Data**

- The Chromium profile lives in `~/.local/share/omamp/chromium`, kept at
  `0700`. OmAmp sends nothing anywhere besides the web player's own traffic to
  Apple.

**Not in scope**

Programs running as your own user can connect to the socket, just as they can
read any of your browser profiles directly. Protecting against your own
account is outside what a shell plugin can do.

Set the widget's `appleMusic` setting to `false` and OmAmp never starts the
daemon or Chromium.

## Reporting

Please open an issue at https://github.com/V-EAGLE/omamp/issues, or a private
security advisory on GitHub for anything sensitive.
