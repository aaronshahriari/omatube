# OmaTube

Your YouTube playlists in the [Omarchy](https://omarchy.org) bar. Open a playlist, play a video in mpv or your browser, drop it from the list — without opening youtube.com and without the sidebar of things you did not ask for.

Two surfaces, one cache:

- **Bar widget** — click the glyph for your playlists, click a playlist for its videos. For grabbing something you already know is in there.
- **Fullscreen view** — playlists down the left, the whole video list on the right, with search. For scanning a long playlist or clearing out things you have finished.

## Install

```bash
omarchy plugin add https://github.com/aaronshahriari/omatube.git --enable --yes
```

Or by hand: clone into `~/.config/omarchy/plugins/io.github.aaronshahriari.omatube/`, then `omarchy-shell shell rescanPlugins` and `omarchy plugin enable io.github.aaronshahriari.omatube`.

There is no build step. The CLI is a single Python 3 file using nothing but the standard library.

### Requirements

| | | |
|---|---|---|
| Omarchy | the Quattro shell | the plugin host |
| `python3` | 3.8 or newer | `bin/omatube`, no third-party packages |
| `mpv` + `yt-dlp` | optional | only if you keep the default player |
| `xdg-open` | | the OAuth approval page, and "open on youtube.com" |
| A Google account | | and your own OAuth client, see below |

Nothing is installed for you, and there is no post-install script, service unit or remote build. If mpv is missing, set `player` to `browser` and the plugin needs nothing beyond Python.

## Connect it

OmaTube talks to YouTube through the official Data API, so it needs its own OAuth client. It is free and takes about two minutes:

```bash
~/.config/omarchy/plugins/io.github.aaronshahriari.omatube/bin/omatube setup
```

That prints the exact steps. In short: make a Google Cloud project, enable the YouTube Data API, create a **Desktop app** OAuth client, then paste the client ID and secret into the bar widget (or pass them to `omatube login`). Your browser opens once to approve, and the refresh token lands in `~/.local/state/omarchy/omatube/token.json` with mode `0600`.

You create the client rather than OmaTube shipping one, because a shared client would put every user's quota in one bucket and would be revoked by Google the moment it appeared in a public repo.

### Why the API, and not yt-dlp

yt-dlp can read a playlist, but it cannot edit one. Removing a video is a write, and `playlistItems.delete` is the only way to do it. yt-dlp is still in the picture — it is what mpv streams through — just as the player, not as the data source.

## Use it

| Action | Bar widget | Fullscreen |
|---|---|---|
| Open | click the glyph | `f` from the panel |
| Into a playlist / back | click / `h`, `Esc` | click in the sidebar, `Tab` |
| Move | `↑` `↓` | `↑` `↓`, `j` `k` |
| Play | `Enter`, click the row | same |
| Play whole playlist | ▶ in the header | ▶ in the header |
| Open on youtube.com | `o`, middle-click | same |
| Remove from playlist | `d`, `Delete` | same |
| Undo a removal | `u` | `u` |
| Search | `/` | `/` |
| Refresh | `r`, middle-click the bar | `r` |

Right-click the bar widget to cycle what it shows: the icon alone, your playlist count, or your total video count.

Removals are held for six seconds before they are sent, so `u` takes one back without a second API call. The row stays visible and struck through in the meantime. Closing the panel commits what is still held rather than dropping it — you asked for those removals.

## Settings

In **Setup > Plugins > OmaTube**, or inline on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `player` | `mpv` | `mpv`, `browser`, or `custom` |
| `playerCommand` | `""` | Used when `player` is `custom`. `{url}` and `{id}` are substituted; with no placeholder the URL is appended |
| `skipCookies` | `true` | Clears a `cookies-from-browser` setting in your `mpv.conf` for OmaTube's launches only. See below |
| `barLabel` | `Icon` | `Icon`, `Playlists`, or `Videos` |
| `maxVideos` | `40` | Cap on rows in the bar popup. The fullscreen view always shows everything |
| `confirmRemove` | `true` | Off makes removal one click, still undoable |
| `syncInterval` | `30 minutes` | Idle refresh. Opening a surface always syncs |

`mpv` streams through yt-dlp, so there is no browser and no ads. OmaTube deliberately passes **no** `--ytdl-format`: stream quality is a standing preference and belongs in your own `~/.config/mpv/mpv.conf`, not in an override from a playlist widget.

Custom examples: `freetube {url}`, `mpv --fs {url}`, `vlc` (URL appended).

### Why mpv starts fast

If your `mpv.conf` sets `ytdl-raw-options=cookies-from-browser=...`, yt-dlp re-reads and decrypts the browser's cookie database on **every** launch. Measured on one machine, playing the same video:

| | time to first frame | format |
|---|---|---|
| `skipCookies: true` (default) | **1.7s** | 1080p60 av01, 207k |
| following `mpv.conf` | 6.3s | 1080p60 av01, 236k Premium |

Four and a half seconds per video, to gain the Premium bitrate of a stream that is otherwise the same resolution, codec and frame rate. So OmaTube clears the option by default — for the player it starts, and nothing else. mpv run any other way still honours your config.

Set `skipCookies` to `false` if you want it back. You will want it for age-restricted videos, which do not resolve without a signed-in session. If you do, and your `mpv.conf` pulls cookies from a Chromium-family browser, yt-dlp needs the `python-secretstorage` package to decrypt them — install it from the Arch repos, not with `python3 -m pip`, which yt-dlp's error text suggests but which Arch's externally-managed Python refuses. Firefox reads its cookie database directly and needs nothing extra.

### When a video will not play

OmaTube starts the player detached, but watches it for a few seconds first. A player that dies immediately gets its error read back and shown in the panel and the bar tooltip, rather than failing silently. The full output of the last launch is kept at `~/.local/state/omarchy/omatube/player.log`.

If mpv fails on every YouTube URL, test it outside OmaTube first — `mpv "https://www.youtube.com/watch?v=..."`. A failure there is an mpv or yt-dlp problem, not a plugin one.

## Quota

The default YouTube API allowance is 10,000 units a day. A sync of your playlist list costs about 2 units; opening a playlist costs 1 plus 1 per 50 videos for their durations; removing a video costs 50. Ordinary use lands nowhere near the ceiling — the 30-minute default sync is roughly 100 units a day.

Videos are fetched when you open a playlist, not on every sync, so forty playlists do not mean forty requests you never asked for.

## What is not here

**Watch Later** and **History** do not appear. Google closed both to the API in 2016 and no API client can reach them. Everything else on your account — including private and unlisted playlists — shows up.

## CLI

The plugin shells out to `bin/omatube` for everything; it works standalone too.

```
omatube [--deadline SECONDS] <command>

omatube setup                    what to create in Google Cloud, and why
omatube login --client-id ... --client-secret ...
omatube logout
omatube status                   one line of JSON
omatube sync                     refresh the playlist list into the cache
omatube items <playlistId>       refresh one playlist's videos
omatube playlists                print the cached playlists as JSON
omatube play <videoId> [--player mpv|browser|custom] [--command ...]
                       [--cookies skip|auto] [--probe SECONDS]
omatube play --playlist <id>     play the whole playlist
omatube open <videoId>           open the watch page in the browser
omatube remove <playlistItemId>  delete a video from its playlist
```

`--deadline` puts a ceiling on the run: at the deadline the process, and the process group it made for itself, get a `TERM`, then a `KILL` three seconds later. The player is started in a session of its own and is deliberately outside that group, so a deadline on the run is never a deadline on what you are watching. The shell passes one on every invocation — 30s for a removal, 90s for a sync, 420s for a sign-in that is waiting on a consent screen.

Standalone player settings live in `~/.config/omarchy/omatube/config.json`:

```json
{ "player": "mpv", "playerCommand": "", "cookies": "skip" }
```

## What it touches

Omarchy plugins share the shell process and run unsandboxed with your user permissions, so here is the whole footprint.

**Network.** `bin/omatube` and nothing else. It talks to `accounts.google.com` and `oauth2.googleapis.com` to sign you in, and to `www.googleapis.com/youtube/v3` for your playlists. The QML never opens a socket. There is no telemetry, no analytics and no server of mine anywhere in the path.

**Files.**

| Path | | What |
|---|---|---|
| `~/.local/state/omarchy/omatube/token.json` | written, `0600` | your refresh token and OAuth client |
| `~/.local/state/omarchy/omatube/data.json` | written | the playlist cache |
| `~/.local/state/omarchy/omatube/player.log` | written | output of the last launch, for when a play fails |
| `~/.config/omarchy/omatube/config.json` | read only | standalone CLI player settings, if you write one |

Nothing else is written anywhere. Your `mpv.conf` is read by mpv, never by OmaTube.

**Processes.** `xdg-open`, and your chosen player — `mpv`, or whatever `playerCommand` names. Launched detached, watched for a few seconds so a failure can be reported, then let go. No second Quickshell process is ever started.

The two OmaTube picks for itself, `mpv` and `xdg-open`, are resolved to an absolute path under `/usr/local/bin`, `/usr/bin` or `/bin` and executed there — a default is not an instruction to run whatever answers to that name first on `PATH`. A `playerCommand` is you naming a program, and is run as named. Either way the child gets a built environment rather than an inherited one: a display, a sound server, your XDG directories, and a fixed `PATH`. Nothing that could name a program for something else to run — `BROWSER`, `LD_PRELOAD` and the rest — is passed on.

**Bounds.** The shell is long-lived, which is what makes an unbounded read expensive. Nothing here grows with what a server, a file, or a stuck process decides to do.

| | |
|---|---|
| HTTP response | 4 MB, and the declared length is checked before the read |
| OAuth token response | 64 KB |
| API error body | 16 KB, whatever the tooltip ends up saying |
| Hosts | the three above, over HTTPS, on the request and on every redirect |
| Redirects | 3, and the bearer token is dropped if the host changes |
| Pagination | 40 pages, 2000 items, 120 seconds — and a `pageToken` is never followed twice |
| State file read | 16 MB, refused rather than truncated |
| Run time | the `--deadline` above, enforced by the CLI and again by the shell |
| stderr held by the shell | 400 characters a run, control characters stripped, read a line at a time rather than collected whole |

**State.** `token.json` and `data.json` are reached through a descriptor on their directory, opened once, rather than by pathname each time. Files are opened `O_NOFOLLOW`, and their type, owner and mode are confirmed on the descriptor actually held. A write goes to a randomly named `O_EXCL` temporary and is `rename`d into place, so it can neither inherit a file that was waiting there nor be pointed out of the directory by a link. This does not pretend to defend the token from something already running as you — that can read the file outright, and the UID is the only boundary there is. It removes the narrower case where a link or a swapped directory turns a write meant for `~/.local/state` into a write somewhere else.

**Account access.** The OAuth scope is `youtube`, which is read and write: write is what makes "remove from playlist" possible. `omatube logout` deletes the local token and cache. Revoking the grant itself is done at Google's end, at [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

## How it fits together

```
bin/omatube ──► YouTube Data API v3
     │
     ├── ~/.local/state/omarchy/omatube/token.json   credentials, 0600
     └── ~/.local/state/omarchy/omatube/data.json    the cache
                    │
                    ▼  FileView, watched
              Service.qml          one instance, shell-wide
               │        │
        BarWidget/Panel  Overlay   one instance per monitor
```

The shell never talks to YouTube. The CLI owns the credentials and every request; the QML reads the cache it writes and shells back out for plays and removals. That keeps a long-lived refresh token out of a process that loads third-party plugin code unsandboxed, and makes every mutation a single auditable command you can also run by hand.

`Service.qml` exists because a bar surface is created per monitor. Left in the panel, a two-display desktop would run two sync timers and commit each held removal twice.

## Remove

```bash
omarchy plugin remove io.github.aaronshahriari.omatube
```

That takes the widget out of the bar and deletes the plugin folder. It does not touch your token or cache, so a reinstall picks up where you left off. To go the rest of the way, before removing the plugin:

```bash
~/.config/omarchy/plugins/io.github.aaronshahriari.omatube/bin/omatube logout
rm -rf ~/.local/state/omarchy/omatube ~/.config/omarchy/omatube
```

`logout` only deletes the local token — the grant on Google's side is yours to revoke, at [myaccount.google.com/permissions](https://myaccount.google.com/permissions). Do that whether or not you get to `logout` first; deleting the plugin folder alone leaves both the grant and the token behind.

## Development

```bash
node --test tests/*.test.js    # pure logic in Model.js
python3 tests/cli_test.py      # the bounds in bin/omatube
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" *.qml
```

`Model.js` holds everything that is data in, data out — cache shape, search, the removal undo stack — so the awkward parts are testable without a running shell. QML imports it; the tests `require` it.

`tests/cli_test.py` covers the other half: it plants a symlink where a state file should be and checks it is neither read nor written through, feeds `paged()` a feed that never ends, hands `read_capped()` a `Content-Length` that lies, and starts a run that ignores `TERM` to watch the deadline take the process group without taking the player with it.

After changing plugin code, `omarchy-shell shell rescanPlugins`. If the plugin directory is a symlink to a checkout elsewhere, the file watcher will not see your edits — use `omarchy-restart-shell`.

## License

MIT
