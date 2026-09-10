import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything that must exist once, not once per screen.
//
// A bar surface is created per monitor, so a two-display desktop runs two of
// every panel. Left in the panel, the sync timer fires twice, the cache is
// parsed twice, and a held removal is committed twice — the second one a
// 404 against a playlistItem that is already gone.
//
// The shell mounts a `service` plugin exactly once and hands it to views
// through shell.serviceFor(id). This holds the cache, the sync timer, the
// write queue, and the undo window. Panels render it.
Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null

  // Views hand their inline shell.json settings over; every view instance
  // has the same ones, so whichever arrives first is as good as any.
  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string cli: pluginDir + "bin/omatube"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/omatube"

  readonly property string player: setting("player", "mpv")
  readonly property string playerCommand: setting("playerCommand", "")
  readonly property int maxVideos: Math.max(5, parseInt(setting("maxVideos", 40), 10) || 40)
  readonly property bool confirmRemove: setting("confirmRemove", true) !== false

  // ---- cache -------------------------------------------------------------

  property var cache: Model.parseCache("")
  property date nowDate: new Date()

  readonly property bool signedIn: cache.syncedAt > 0 && !cache.authRequired
  readonly property var playlists: cache.playlists || []
  readonly property string cacheError: cache.error || ""

  property FileView dataFile: FileView {
    path: root.statePath + "/data.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.cache = Model.parseCache(text())
      // The write that lands here is the authority on what is still in the
      // playlist, so optimistic removals stop being needed once it arrives.
      root.pendingRemovals = []
    }
    onLoadFailed: root.cache = Model.parseCache("")
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.nowDate = date
  }

  // ---- sync --------------------------------------------------------------

  readonly property int refreshIntervalSec: Model.syncIntervalSeconds(setting("syncInterval", "30 minutes"))
  readonly property bool autoSyncs: refreshIntervalSec > 0
  readonly property bool syncing: syncProc.running
  property string actionError: ""

  // `force` is an explicit user action — opening a panel, the refresh
  // button. A timer tick is not, and passes a max age so a sync another
  // process just completed is not repeated.
  function refresh(force) {
    nowDate = new Date()
    if (syncProc.running) return
    syncProc.command = force === false
      ? [root.cli, "sync", "--max-age", String(Math.max(30, refreshIntervalSec - 15))]
      : [root.cli, "sync"]
    syncProc.running = true
  }

  Process {
    id: syncProc
    command: [root.cli, "sync"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 120)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.nowDate = new Date()
    }
  }

  Timer {
    interval: Math.max(60, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.autoSyncs
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // With background sync off the cache would still be stale on the first
  // paint after a shell restart. One sync at startup is not a poll; it is
  // the bar having something to show.
  Timer {
    interval: 1500
    running: !root.autoSyncs
    repeat: false
    onTriggered: root.refresh(false)
  }

  // ---- per-playlist video loading ----------------------------------------
  //
  // Videos are fetched when a playlist is opened, not on every sync. A
  // account with forty playlists would otherwise spend hundreds of quota
  // units and several seconds refreshing lists nobody is looking at.

  property string loadingPlaylist: ""

  function loadItems(playlistId, force) {
    if (!playlistId) return
    if (itemsProc.running) {
      queuedPlaylist = playlistId
      return
    }
    // Videos already on screen are re-fetched quietly in the background;
    // only a first open shows a spinner.
    loadingPlaylist = Model.hasItems(cache, playlistId) ? "" : playlistId
    var args = Model.itemsArgs(playlistId, force === true ? 0 : 120, 0)
    itemsProc.command = [root.cli].concat(args)
    itemsProc.running = true
  }

  property string queuedPlaylist: ""

  Process {
    id: itemsProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 120)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.loadingPlaylist = ""
      // Clicking through playlists faster than they load must not drop the
      // one that is actually on screen now.
      if (root.queuedPlaylist !== "") {
        var next = root.queuedPlaylist
        root.queuedPlaylist = ""
        root.loadItems(next, false)
      }
    }
  }

  // ---- writes ------------------------------------------------------------

  property var actionQueue: []

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = Model.elide(raw, 120)
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.connecting = false
      root.drainQueue()
    }
  }

  function runAction(args) {
    if (!args) return
    if (actionProc.running) {
      actionQueue = actionQueue.concat([args])
      return
    }
    actionProc.command = [root.cli].concat(args)
    actionProc.running = true
  }

  function drainQueue() {
    if (actionQueue.length === 0) return
    var queued = actionQueue.slice()
    var next = queued.shift()
    actionQueue = queued
    actionProc.command = [root.cli].concat(next)
    actionProc.running = true
  }

  // ---- playing -----------------------------------------------------------
  //
  // Playing is fire-and-forget: the CLI detaches the player and exits, so
  // it never joins the write queue behind a slow removal.

  function play(video) {
    var args = Model.playArgs(video, player, playerCommand)
    if (args) runAction(args)
  }

  function playPlaylist(playlist) {
    var args = Model.playPlaylistArgs(playlist, player, playerCommand)
    if (args) runAction(args)
  }

  function openInBrowser(video) {
    var args = Model.openArgs(video)
    if (args) runAction(args)
  }

  // ---- removal, with undo ------------------------------------------------

  property var pendingRemovals: []
  property int undoTick: 0

  readonly property int undoSeconds: 6
  readonly property var pendingRemoval: Model.topPending(pendingRemovals)
  readonly property int pendingCount: pendingRemovals.length
  readonly property string undoText: Model.undoLabel(pendingRemovals)
  readonly property int undoLeft: pendingRemoval
    ? Model.undoSecondsLeft(pendingRemoval.deadline, Date.now() + undoTick * 0)
    : 0

  function isPending(video) {
    return Model.isPending(pendingRemovals, video)
  }

  // The row is struck through immediately and the DELETE is held, so undo
  // costs nothing. Sending it right away and re-adding on undo would need
  // playlistItems.insert, which lands the video at the end of the playlist
  // rather than where it was.
  function removeVideo(video) {
    var args = Model.removeArgs(video)
    if (!args) return
    pendingRemovals = pendingRemovals.concat([{
      key: Model.pendingKey(video),
      title: video.title,
      args: args,
      deadline: Date.now() + undoSeconds * 1000
    }])
  }

  function undoRemoval() {
    var top = Model.topPending(pendingRemovals)
    if (!top) return
    pendingRemovals = Model.dropTopPending(pendingRemovals)
  }

  // Anything whose window has closed goes out, oldest first.
  function flushExpired() {
    var split = Model.expirePending(pendingRemovals, Date.now())
    if (split.due.length === 0) return
    pendingRemovals = split.remaining
    for (var i = 0; i < split.due.length; i++) runAction(split.due[i].args)
  }

  // Closing the panel commits what is still held rather than dropping it:
  // the user asked for these removals and walked away.
  function flushPending() {
    if (pendingRemovals.length === 0) return
    var held = pendingRemovals
    pendingRemovals = []
    for (var i = 0; i < held.length; i++) runAction(held[i].args)
  }

  // One ticker drives both the countdown and expiry, so N held removals do
  // not mean N timers.
  Timer {
    interval: 250
    repeat: true
    running: root.pendingRemovals.length > 0
    onTriggered: {
      root.undoTick++
      root.flushExpired()
    }
  }

  // ---- sign-in -----------------------------------------------------------

  property bool connecting: false

  property FileView clientFile: FileView {
    path: root.statePath + "/client-paste.json"
    atomicWrites: true
    printErrors: false
  }

  // The client secret goes through a file rather than a command line, where
  // it would sit in the process table for any other user to read.
  function connectWithClient(clientId, clientSecret) {
    var id = String(clientId || "").trim()
    var secret = String(clientSecret || "").trim()
    if (id === "" || secret === "") return
    connecting = true
    actionError = ""
    clientFile.setText(JSON.stringify({ client_id: id, client_secret: secret }) + "\n")
    runAction(["login", "--client-file", root.statePath + "/client-paste.json"])
  }

  function signOut() {
    runAction(["logout"])
  }
}
