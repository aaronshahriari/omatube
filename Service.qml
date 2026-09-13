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

  // The CLI runs with this instead of whatever the shell happens to have
  // inherited. Built once: the names come from Model so they can be read
  // and tested in one place.
  readonly property var cliEnvironment: {
    var env = ({})
    var names = Model.envPassthrough()
    for (var i = 0; i < names.length; i++) {
      var value = Quickshell.env(names[i])
      if (value !== undefined && value !== null && value !== "")
        env[names[i]] = String(value)
    }
    return env
  }

  readonly property string player: setting("player", "mpv")
  readonly property string playerCommand: setting("playerCommand", "")
  readonly property bool skipCookies: setting("skipCookies", true) !== false
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

  // A FileView arms its watch when its path is set, and on a first run that
  // happens before ~/.local/state/omarchy/omatube exists. There is no file
  // to watch and no directory to watch it in, so the watch comes up empty
  // and stays empty: the data.json that the first `login` writes lands
  // unseen, and the panel sits on the sign-in form until the bar restarts.
  //
  // So the cache is re-read after every run that could have written it
  // rather than only when something says so. reload() also re-arms the
  // watch, which by then has a directory to attach to.
  function reloadCache() {
    dataFile.reload()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.nowDate = date
  }

  // ---- sync --------------------------------------------------------------

  readonly property int refreshIntervalSec: Model.syncIntervalSeconds(setting("syncInterval", "30 minutes"))
  readonly property bool autoSyncs: refreshIntervalSec > 0
  readonly property bool syncing: syncProc.busy
  property string actionError: ""

  // `force` is an explicit user action — opening a panel, the refresh
  // button. A timer tick is not, and passes a max age so a sync another
  // process just completed is not repeated.
  function refresh(force) {
    nowDate = new Date()
    // True whether or not the sync below actually runs: what is on disk now
    // is at least as new as what we last parsed.
    reloadCache()
    if (syncProc.busy) return
    var args = force === false
      ? ["sync", "--max-age", String(Math.max(30, refreshIntervalSec - 15))]
      : ["sync"]
    syncProc.start(args, Model.deadlineSeconds(args))
  }

  SupervisedProcess {
    id: syncProc
    cli: root.cli
    environment: root.cliEnvironment
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      else if (errorText !== "") root.actionError = Model.elide(errorText, 120)
      root.reloadCache()
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
    if (itemsProc.busy) {
      queuedPlaylist = playlistId
      return
    }
    // Videos already on screen are re-fetched quietly in the background;
    // only a first open shows a spinner.
    loadingPlaylist = Model.hasItems(cache, playlistId) ? "" : playlistId
    var args = Model.itemsArgs(playlistId, force === true ? 0 : 120, 0)
    itemsProc.start(args, Model.deadlineSeconds(args))
  }

  property string queuedPlaylist: ""

  SupervisedProcess {
    id: itemsProc
    cli: root.cli
    environment: root.cliEnvironment
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      else if (errorText !== "") root.actionError = Model.elide(errorText, 120)
      root.reloadCache()
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

  // What actionProc is running right now, so `connecting` below can be read
  // off the queue instead of being raised and lowered by hand.
  property var actionRunning: null

  SupervisedProcess {
    id: actionProc
    cli: root.cli
    environment: root.cliEnvironment
    onExited: function(code) {
      root.actionRunning = null
      if (code === 0) root.actionError = ""
      else if (errorText !== "") root.actionError = Model.elide(errorText, 120)
      // login writes the cache for the first time, logout empties it, and a
      // removal rewrites it. All three are worth a re-read.
      root.reloadCache()
      root.drainQueue()
    }
  }

  function startAction(args) {
    actionRunning = args
    actionProc.start(args, Model.deadlineSeconds(args))
  }

  function runAction(args) {
    if (!args) return
    if (actionProc.busy) {
      actionQueue = actionQueue.concat([args])
      return
    }
    startAction(args)
  }

  function drainQueue() {
    if (actionQueue.length === 0) return
    var queued = actionQueue.slice()
    var next = queued.shift()
    actionQueue = queued
    startAction(next)
  }

  // ---- playing -----------------------------------------------------------
  //
  // Plays get their own Process rather than joining the write queue. The CLI
  // stays alive for a few seconds after starting a player to catch one that
  // dies immediately, and a removal must not sit behind that window.

  property string playError: ""
  // At most one play is ever waiting: it is the latest thing asked for, and
  // anything older has been superseded rather than stacked up.
  property var playPending: null

  readonly property bool playing: playProc.busy

  SupervisedProcess {
    id: playProc
    cli: root.cli
    environment: root.cliEnvironment
    onExited: function(code) {
      if (code === 0) root.playError = ""
      else if (errorText !== "") root.playError = Model.elide(errorText, 160)
      if (root.playPending) {
        var next = root.playPending
        root.playPending = null
        // A cancelled probe reports a signal, not a failure of the player it
        // was watching; do not leave its exit dressed up as an error.
        root.playError = ""
        playProc.start(next, Model.deadlineSeconds(next))
      }
    }
  }

  function runPlay(args) {
    if (!args) return
    // Clearing up front means the panel does not show the previous
    // failure's message while a fresh attempt is still being probed.
    playError = ""
    // A play that succeeded leaves the CLI watching its player for several
    // seconds. Queueing behind that would make picking a second video sit and
    // do nothing for most of that window, so a newer request preempts.
    //
    // Cancelling kills only the CLI that was watching: the player it started
    // is in its own session and plays on. What is lost is the error report
    // for the first one, which stopped mattering the moment something else
    // was asked for.
    if (playProc.busy) {
      playPending = args
      playProc.stop()
      return
    }
    playProc.start(args, Model.deadlineSeconds(args))
  }

  function play(video) {
    runPlay(Model.playArgs(video, player, playerCommand, skipCookies))
  }

  function playPlaylist(playlist) {
    runPlay(Model.playPlaylistArgs(playlist, player, playerCommand, skipCookies))
  }

  function openInBrowser(video) {
    runPlay(Model.openArgs(video))
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

  // Raising a flag on Connect and lowering it on the next exit meant a
  // removal finishing first put the button back before the browser had even
  // opened, and a run that never reported back left it disabled for good.
  readonly property bool connecting: Model.isLoginPending(actionRunning, actionQueue)

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
    actionError = ""
    clientFile.setText(JSON.stringify({ client_id: id, client_secret: secret }) + "\n")
    runAction(["login", "--client-file", root.statePath + "/client-paste.json"])
  }

  function signOut() {
    runAction(["logout"])
  }
}
