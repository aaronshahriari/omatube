// Pure helpers for the OmaTube plugin.
//
// Everything here is data in, data out: no QML types, no side effects, no
// network. That keeps the awkward parts — cache shape, search ranking, the
// removal undo stack — testable under `node --test` instead of only being
// observable by clicking around a bar popup.
//
// Loaded by QML as `import "Model.js" as Model` and by the tests as an
// ordinary CommonJS module; the export block at the bottom is guarded so
// the same file works in both.

// ---- cache ----------------------------------------------------------------

// Shape the panel can render unconditionally. Every consumer reads these
// fields without checking for undefined, so a missing or half-written
// data.json has to come back as an empty cache rather than null.
function emptyCache() {
  return {
    syncedAt: 0,
    authRequired: false,
    error: "",
    channel: "",
    playlists: [],
    items: ({}),
    itemsSyncedAt: ({})
  }
}

function parseCache(text) {
  var base = emptyCache()
  if (!text) return base

  var raw
  try {
    raw = JSON.parse(text)
  } catch (e) {
    // A FileView can read the file mid-write. Returning the empty cache
    // shows "syncing" for one frame; throwing would break the binding.
    return base
  }
  if (!raw || typeof raw !== "object") return base

  base.syncedAt = Number(raw.syncedAt) || 0
  base.authRequired = raw.authRequired === true
  base.error = raw.error ? String(raw.error) : ""
  base.channel = raw.channel ? String(raw.channel) : ""
  base.playlists = Array.isArray(raw.playlists) ? raw.playlists : []
  base.items = (raw.items && typeof raw.items === "object") ? raw.items : ({})
  base.itemsSyncedAt = (raw.itemsSyncedAt && typeof raw.itemsSyncedAt === "object")
    ? raw.itemsSyncedAt : ({})
  return base
}

function videosFor(cache, playlistId) {
  if (!cache || !cache.items || !playlistId) return []
  var found = cache.items[playlistId]
  return Array.isArray(found) ? found : []
}

// Whether a playlist's videos have ever been fetched. Distinct from "has
// no videos": an unopened playlist and an empty one both list zero rows,
// but only one of them should show a spinner.
function hasItems(cache, playlistId) {
  if (!cache || !cache.itemsSyncedAt || !playlistId) return false
  return Number(cache.itemsSyncedAt[playlistId]) > 0
}

function staleMinutes(syncedAt, nowMs) {
  if (!syncedAt) return 0
  return Math.max(0, Math.floor((nowMs - syncedAt * 1000) / 60000))
}

function totalVideos(playlists) {
  var total = 0
  for (var i = 0; i < (playlists || []).length; i++)
    total += Number(playlists[i].count) || 0
  return total
}

// ---- text -----------------------------------------------------------------

function elide(text, max) {
  var value = String(text === undefined || text === null ? "" : text)
  if (max <= 1 || value.length <= max) return value
  return value.slice(0, max - 1).replace(/\s+$/, "") + "…"
}

function plural(count, word) {
  return count + " " + word + (count === 1 ? "" : "s")
}

function playlistSubtitle(playlist) {
  if (!playlist) return ""
  var parts = [plural(Number(playlist.count) || 0, "video")]
  // Public is the default and says nothing worth a line of the popup;
  // private and unlisted are the states you would want to be reminded of.
  if (playlist.privacy === "private") parts.push("private")
  else if (playlist.privacy === "unlisted") parts.push("unlisted")
  return parts.join(" · ")
}

function videoSubtitle(video) {
  if (!video) return ""
  if (video.available === false) return "unavailable"
  var parts = []
  if (video.channel) parts.push(video.channel)
  if (video.duration) parts.push(video.duration)
  return parts.join(" · ")
}

// ---- search ---------------------------------------------------------------

function normalize(text) {
  return String(text === undefined || text === null ? "" : text).toLowerCase().trim()
}

// Substring, not fuzzy. A playlist is tens to hundreds of rows with titles
// the user chose themselves, so typing the words they remember is enough —
// and fuzzy matching on short queries surfaces noise ahead of the obvious
// hit, which is worse than no ranking at all.
function matches(video, query) {
  var needle = normalize(query)
  if (!needle) return true
  return normalize(video.title).indexOf(needle) !== -1
    || normalize(video.channel).indexOf(needle) !== -1
}

function filterVideos(videos, query) {
  var needle = normalize(query)
  if (!needle) return videos || []
  var out = []
  for (var i = 0; i < (videos || []).length; i++)
    if (matches(videos[i], needle)) out.push(videos[i])
  return out
}

function filterPlaylists(playlists, query) {
  var needle = normalize(query)
  if (!needle) return playlists || []
  var out = []
  for (var i = 0; i < (playlists || []).length; i++)
    if (normalize(playlists[i].title).indexOf(needle) !== -1) out.push(playlists[i])
  return out
}

// ---- bar label ------------------------------------------------------------

function cycleBarLabel(mode) {
  var order = ["Icon", "Playlists", "Videos"]
  // An unrecognized stored value renders as Icon, so it has to advance
  // from Icon too — otherwise the first right-click looks like a no-op.
  var at = order.indexOf(mode)
  return order[((at === -1 ? 0 : at) + 1) % order.length]
}

function barLabelDescription(mode) {
  if (mode === "Playlists") return "the playlist count"
  if (mode === "Videos") return "the total video count"
  return "the icon alone"
}

function barLabel(mode, cache) {
  var playlists = (cache && cache.playlists) || []
  if (mode === "Playlists") return playlists.length > 0 ? String(playlists.length) : ""
  if (mode === "Videos") {
    var total = totalVideos(playlists)
    return total > 0 ? String(total) : ""
  }
  return ""
}

// ---- settings -------------------------------------------------------------

function syncIntervalSeconds(label) {
  if (label === "15 minutes") return 900
  if (label === "1 hour") return 3600
  if (label === "Only when opened") return 0
  return 1800
}

// ---- commands -------------------------------------------------------------

// The CLI is the only thing that touches YouTube, so every action the UI
// offers is an argv built here. Keeping them in one tested place means a
// mistyped flag fails a test rather than silently doing nothing on click.

function playArgs(video, player, command) {
  if (!video || !video.videoId) return null
  var args = ["play", String(video.videoId)]
  if (player) args = args.concat(["--player", String(player)])
  if (player === "custom" && command) args = args.concat(["--command", String(command)])
  return args
}

function playPlaylistArgs(playlist, player, command) {
  if (!playlist || !playlist.id) return null
  var args = ["play", "--playlist", String(playlist.id)]
  if (player) args = args.concat(["--player", String(player)])
  if (player === "custom" && command) args = args.concat(["--command", String(command)])
  return args
}

function removeArgs(video) {
  if (!video || !video.itemId) return null
  return ["remove", String(video.itemId)]
}

function openArgs(video) {
  if (!video || !video.videoId) return null
  return ["open", String(video.videoId)]
}

function itemsArgs(playlistId, maxAge, limit) {
  if (!playlistId) return null
  var args = ["items", String(playlistId)]
  if (maxAge > 0) args = args.concat(["--max-age", String(maxAge)])
  if (limit > 0) args = args.concat(["--limit", String(limit)])
  return args
}

// ---- removal undo ---------------------------------------------------------

// A removal is held for a few seconds before it is sent, so the row can
// come back without a second API call. Held entries are a stack, oldest
// first: removing three videos in a row holds all three rather than
// committing the earlier ones the moment the next arrives.

function pendingKey(video) {
  return video && video.itemId ? String(video.itemId) : ""
}

function undoSecondsLeft(deadline, nowMs) {
  if (!deadline) return 0
  return Math.max(0, Math.ceil((deadline - nowMs) / 1000))
}

function expirePending(pending, nowMs) {
  var due = [], remaining = []
  for (var i = 0; i < (pending || []).length; i++) {
    var entry = pending[i]
    if (entry.deadline <= nowMs) due.push(entry)
    else remaining.push(entry)
  }
  return { due: due, remaining: remaining }
}

function topPending(pending) {
  if (!pending || pending.length === 0) return null
  return pending[pending.length - 1]
}

function dropTopPending(pending) {
  if (!pending || pending.length === 0) return []
  return pending.slice(0, pending.length - 1)
}

function undoLabel(pending) {
  var top = topPending(pending)
  if (!top) return ""
  var count = pending.length
  if (count > 1) return "Removed " + plural(count, "video")
  return "Removed " + elide(top.title, 34)
}

// Rows still held are drawn struck through rather than removed outright,
// so undo has something to put back and the list does not jump.
function isPending(pending, video) {
  var key = pendingKey(video)
  if (!key) return false
  for (var i = 0; i < (pending || []).length; i++)
    if (pending[i].key === key) return true
  return false
}

function visibleVideos(videos, pending, max) {
  var out = []
  for (var i = 0; i < (videos || []).length; i++) {
    if (max > 0 && out.length >= max) break
    out.push(videos[i])
  }
  return out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    emptyCache: emptyCache,
    parseCache: parseCache,
    videosFor: videosFor,
    hasItems: hasItems,
    staleMinutes: staleMinutes,
    totalVideos: totalVideos,
    elide: elide,
    plural: plural,
    playlistSubtitle: playlistSubtitle,
    videoSubtitle: videoSubtitle,
    matches: matches,
    filterVideos: filterVideos,
    filterPlaylists: filterPlaylists,
    cycleBarLabel: cycleBarLabel,
    barLabelDescription: barLabelDescription,
    barLabel: barLabel,
    syncIntervalSeconds: syncIntervalSeconds,
    playArgs: playArgs,
    playPlaylistArgs: playPlaylistArgs,
    removeArgs: removeArgs,
    openArgs: openArgs,
    itemsArgs: itemsArgs,
    pendingKey: pendingKey,
    undoSecondsLeft: undoSecondsLeft,
    expirePending: expirePending,
    topPending: topPending,
    dropTopPending: dropTopPending,
    undoLabel: undoLabel,
    isPending: isPending,
    visibleVideos: visibleVideos
  }
}
