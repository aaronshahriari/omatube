import QtQuick
import Quickshell.Io

// A CLI run with a ceiling on every way it could cost the shell something.
//
// The shell is the long-lived process here, and three things a child does
// are unbounded by default: how much it writes back, how long it takes, and
// what it leaves running when it is stopped. This puts a limit on each.
//
//   output   stderr arrives a line at a time through a SplitParser and is
//            kept up to a fixed character count, rather than collected whole
//            into memory the shell never gets back.
//   time     the CLI is given its own deadline, which it enforces on itself
//            and reports through; if that fails, the timer here terminates
//            it, and if that fails too the group is killed outright.
//   reach    the CLI makes itself a process group leader, so the escalation
//            below reaches everything it started. The player is not in that
//            group — it is started in a session of its own and plays on.
//
// And one thing a run must always do is report back. A command that cannot
// be started at all is reported by Quickshell as `running` going false with
// no exited() behind it, which would leave every caller waiting on this run
// waiting for good; it is turned into an ordinary failed exit below.
Item {
  id: root

  property string cli: ""
  property var environment: ({})

  // The CLI's own deadline. It fires first, because it is the one that can
  // say what timed out; everything after it is force.
  property int timeoutSeconds: 90
  property int graceMs: 3000

  // stderr is a sentence in a bar tooltip, never a document.
  property int maxChars: 400

  readonly property bool running: proc.running
  // False only once a finished run's last line has had a chance to arrive.
  readonly property bool busy: proc.running || settle.running

  property string errorText: ""

  signal exited(int code)
  signal timedOut()

  function start(args, seconds) {
    if (!args || args.length === 0) return
    _seconds = seconds > 0 ? seconds : timeoutSeconds
    _buffer = ""
    _dropped = 0
    _timedOut = false
    _live = true
    _exitSeen = false
    errorText = ""
    settle.stop()
    proc.command = [root.cli, "--deadline", String(_seconds)].concat(args)
    proc.running = true
    deadline.interval = _seconds * 1000 + 2 * graceMs
    deadline.restart()
  }

  // A polite stop: the same TERM the deadline would send, without the wait.
  function stop() {
    deadline.stop()
    killer.stop()
    proc.running = false
  }

  property int _seconds: 90
  property string _buffer: ""
  property int _dropped: 0
  property bool _timedOut: false
  property int _code: 0
  // A run is live from start() until its exit has been reported; _exitSeen
  // says whether that exit actually came from the process.
  property bool _live: false
  property bool _exitSeen: false

  // The exit a process that never ran would have had. 127 is what a shell
  // gives a command it could not find, and the callers here only ask
  // whether the code was zero.
  function _failedToStart() {
    _live = false
    deadline.stop()
    killer.stop()
    settle.stop()
    errorText = "could not run " + root.cli
    root.exited(127)
  }

  function _collect(data) {
    // Control characters are stripped on the way in: this text is about to
    // be drawn in a tooltip, and a stream that can paint the bar is one
    // more thing a failing command should not be able to do.
    var line = String(data || "").replace(/[\x00-\x1f\x7f]/g, " ").trim()
    if (line === "") return
    if (_buffer.length >= maxChars) {
      _dropped++
      return
    }
    _buffer = _buffer === "" ? line : _buffer + " " + line
    if (_buffer.length > maxChars) _buffer = _buffer.slice(0, maxChars)
  }

  Process {
    id: proc
    // Not the shell's environment: a curated one, so what the CLI and the
    // player it starts can see is a decision rather than an inheritance.
    clearEnvironment: true
    environment: root.environment

    stdout: SplitParser {
      splitMarker: "\n"
      // Discarded deliberately. Only `items --json` prints to stdout, and
      // the shell reads that result from the cache file instead.
      onRead: function(_data) {}
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root._collect(data) }
    }

    onExited: function(code) {
      root._code = code
      root._exitSeen = true
      deadline.stop()
      killer.stop()
      // A line written just before exit can still be in flight. One frame
      // of slack costs nothing and is the difference between a reported
      // failure and a silent one.
      settle.restart()
    }

    // A real exit raises this too, but only after exited() — so an exit
    // that was never seen by the time running drops is one that is never
    // coming. A stop() on a live process is not that: it terminates, and
    // the exit arrives normally.
    onRunningChanged: {
      if (!proc.running && root._live && !root._exitSeen) root._failedToStart()
    }
  }

  Timer {
    id: settle
    interval: 16
    repeat: false
    onTriggered: {
      var text = root._buffer
      if (root._dropped > 0) text += " (+" + root._dropped + " more)"
      // A run that was stopped on time says so first. Whatever it managed
      // to print before that is context, not the headline.
      if (root._timedOut)
        text = "timed out after " + root._seconds + "s" + (text ? " — " + text : "")
      root.errorText = text
      root._live = false
      if (root._timedOut) root.timedOut()
      root.exited(root._code)
    }
  }

  // The CLI should already have stopped itself by now and said why. This is
  // for the case where it did not.
  Timer {
    id: deadline
    repeat: false
    onTriggered: {
      root._timedOut = true
      killer.pid = proc.processId
      proc.running = false          // SIGTERM
      killer.restart()
    }
  }

  // And this is for the case where TERM was not enough.
  Timer {
    id: killer
    property var pid: null
    interval: root.graceMs
    repeat: false
    onTriggered: {
      if (!proc.running) return
      // Negative pid is the process group. The CLI called setsid, so its
      // group id is its pid and this reaches anything still inside it; if
      // setsid somehow did not happen there is no group by that id and the
      // kill is a no-op rather than a wider blast.
      if (killer.pid !== null && killer.pid !== undefined && killer.pid > 1) {
        reaper.command = ["/usr/bin/kill", "-KILL", "--", "-" + killer.pid]
        reaper.running = true
      }
    }
  }

  Process { id: reaper }
}
