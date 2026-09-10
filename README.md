# OmaTube

Your YouTube playlists in the [Omarchy](https://omarchy.org) bar. Open a
playlist, play a video in mpv or your browser, drop it from the list — without
opening youtube.com and without the sidebar of things you did not ask for.

Two surfaces, one cache:

- **Bar widget** — click the glyph for your playlists, click a playlist for its
  videos. For grabbing something you already know is in there.
- **Fullscreen view** — playlists down the left, the whole video list on the
  right, with search. For scanning a long playlist or clearing out things you
  have finished.

## Install

```bash
omarchy plugin add https://github.com/aaronshahriari/omatube.git --enable --yes
```

Or by hand: clone into `~/.config/omarchy/plugins/aaronshahriari.omatube/`,
then `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable aaronshahriari.omatube`.

There is no build step. The CLI is a single Python 3 file using nothing but
the standard library.

## Connect it

OmaTube talks to YouTube through the official Data API, so it needs its own
OAuth client. It is free and takes about two minutes:

```bash
~/.config/omarchy/plugins/aaronshahriari.omatube/bin/omatube setup
```

That prints the exact steps. In short: make a Google Cloud project, enable the
YouTube Data API, create a **Desktop app** OAuth client, then paste the client
ID and secret into the bar widget (or pass them to `omatube login`). Your
browser opens once to approve, and the refresh token lands in
`~/.local/state/omarchy/omatube/token.json` with mode `0600`.

You create the client rather than OmaTube shipping one, because a shared
client would put every user's quota in one bucket and would be revoked by
Google the moment it appeared in a public repo.

### Why the API, and not yt-dlp

yt-dlp can read a playlist, but it cannot edit one. Removing a video is a
write, and `playlistItems.delete` is the only way to do it. yt-dlp is still
in the picture — it is what mpv streams through — just as the player, not as
the data source.

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

Right-click the bar widget to cycle what it shows: the icon alone, your
playlist count, or your total video count.

Removals are held for six seconds before they are sent, so `u` takes one back
without a second API call. The row stays visible and struck through in the
meantime. Closing the panel commits what is still held rather than dropping
it — you asked for those removals.

## Settings

In **Setup > Plugins > OmaTube**, or inline on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `player` | `mpv` | `mpv`, `browser`, or `custom` |
| `playerCommand` | `""` | Used when `player` is `custom`. `{url}` and `{id}` are substituted; with no placeholder the URL is appended |
| `skipCookies` | `true` | Clears a `cookies-from-browser` setting in your `mpv.conf` for OmaTube's launches only. See below |
| `barLabel` | `Icon` | `Icon`, `Playlists`, or `Videos` |
| `maxVideos` | `40` | Cap on rows in the bar popup. The fullscreen view always shows everything |
| `confirmRemove` | `true` | Off makes removal one click, still undoable |
| `syncInterval` | `30 minutes` | Idle refresh. Opening a surface always syncs |

`mpv` streams through yt-dlp, so there is no browser and no ads. OmaTube
deliberately passes **no** `--ytdl-format`: stream quality is a standing
preference and belongs in your own `~/.config/mpv/mpv.conf`, not in an
override from a playlist widget.

Custom examples: `freetube {url}`, `mpv --fs {url}`, `vlc` (URL appended).

### Why mpv starts fast

If your `mpv.conf` sets `ytdl-raw-options=cookies-from-browser=...`, yt-dlp
re-reads and decrypts the browser's cookie database on **every** launch.
Measured on one machine, playing the same video:

| | time to first frame | format |
|---|---|---|
| `skipCookies: true` (default) | **1.7s** | 1080p60 av01, 207k |
| following `mpv.conf` | 6.3s | 1080p60 av01, 236k Premium |

Four and a half seconds per video, to gain the Premium bitrate of a stream
that is otherwise the same resolution, codec and frame rate. So OmaTube
clears the option by default — for the player it starts, and nothing else.
mpv run any other way still honours your config.

Set `skipCookies` to `false` if you want it back. You will want it for
age-restricted videos, which do not resolve without a signed-in session.

### When a video will not play

OmaTube starts the player detached, but watches it for a few seconds first.
A player that dies immediately gets its error read back and shown in the
panel and the bar tooltip, rather than failing silently. The full output of
the last launch is kept at `~/.local/state/omarchy/omatube/player.log`.

If mpv fails on every YouTube URL, test it outside OmaTube first —
`mpv "https://www.youtube.com/watch?v=..."`. A failure there is an mpv or
yt-dlp problem, not a plugin one. A common one on Arch: `mpv.conf` sets
`ytdl-raw-options=cookies-from-browser=...`, which needs the keyring module —
`sudo pacman -S python-secretstorage`. Install it from the repos, not with
`python3 -m pip`, which yt-dlp's error text suggests but which Arch's
externally-managed Python refuses.

## Quota

The default YouTube API allowance is 10,000 units a day. A sync of your
playlist list costs about 2 units; opening a playlist costs 1 plus 1 per 50
videos for their durations; removing a video costs 50. Ordinary use lands
nowhere near the ceiling — the 30-minute default sync is roughly 100 units a
day.

Videos are fetched when you open a playlist, not on every sync, so forty
playlists do not mean forty requests you never asked for.

## What is not here

**Watch Later** and **History** do not appear. Google closed both to the API
in 2016 and no API client can reach them. Everything else on your account —
including private and unlisted playlists — shows up.

## CLI

The plugin shells out to `bin/omatube` for everything; it works standalone
too.

```
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

Standalone player settings live in `~/.config/omarchy/omatube/config.json`:

```json
{ "player": "mpv", "playerCommand": "", "cookies": "skip" }
```

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

The shell never talks to YouTube. The CLI owns the credentials and every
request; the QML reads the cache it writes and shells back out for plays and
removals. That keeps a long-lived refresh token out of a process that loads
third-party plugin code unsandboxed, and makes every mutation a single
auditable command you can also run by hand.

`Service.qml` exists because a bar surface is created per monitor. Left in the
panel, a two-display desktop would run two sync timers and commit each held
removal twice.

## Development

```bash
node --test tests/          # pure logic in Model.js
python3 -m py_compile bin/omatube
```

`Model.js` holds everything that is data in, data out — cache shape, search,
the removal undo stack — so the awkward parts are testable without a running
shell. QML imports it; the tests `require` it.

After changing plugin code, `omarchy-shell shell rescanPlugins`. If the plugin
directory is a symlink to a checkout elsewhere, the file watcher will not see
your edits — use `omarchy-restart-shell`.

## License

MIT
