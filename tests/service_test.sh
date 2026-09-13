#!/usr/bin/env bash
# Service.qml against a fake CLI, in a HOME of its own.
#
#   tests/service_test.sh
#
# Model.js is data in, data out and is tested next door without a shell.
# What is *not* testable that way is the part that goes wrong first on a
# machine that has never run OmaTube: a sign-in whose result the panel never
# notices, because the cache file it is watching for did not exist — nor did
# the directory it would appear in — at the moment the watch was armed.
#
# So this runs the real Service.qml under quickshell with HOME pointed at an
# empty directory, presses Connect, and asks whether it ended up signed in.
set -u

command -v quickshell >/dev/null || { echo "SKIP: quickshell not installed"; exit 0; }

here=$(cd -- "$(dirname -- "$0")" && pwd)
plugin=$(dirname -- "$here")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A plugin tree holding the real Service.qml and a CLI that only pretends.
mkdir -p "$work/plugin" "$work/home"
cp "$plugin/Service.qml" "$plugin/SupervisedProcess.qml" "$plugin/Model.js" "$work/plugin/"

mkdir -p "$work/plugin/bin"
cat > "$work/plugin/bin/omatube" <<'CLI'
#!/usr/bin/env bash
dir="$HOME/.local/state/omarchy/omatube"
for a in "$@"; do case "$a" in
  login)
    # What the real one does on a first run: makes the state directory,
    # writes the cache into it, and says so on stderr.
    sleep 0.3
    mkdir -p "$dir"
    printf '%s' '{"syncedAt":1757500000,"authRequired":false,"channel":"Test","playlists":[{"id":"PL1","title":"Watch","count":3}],"items":{},"itemsSyncedAt":{},"error":""}' > "$dir/.data.tmp"
    mv "$dir/.data.tmp" "$dir/data.json"
    echo connected >&2
    exit 0 ;;
  sync|logout) exit 0 ;;
esac; done
CLI
chmod +x "$work/plugin/bin/omatube"
# Service.qml builds the CLI path from its own directory; whether that comes
# back with a trailing slash is up to the loader, so answer to both.
cp -r "$work/plugin/bin" "$work/pluginbin"

cat > "$work/plugin/Harness.qml" <<'QML'
import QtQuick

Item {
  Service {
    id: svc
    // Manual sync only: the login run is then the only thing that can have
    // written the cache, so a pass cannot be a background sync's doing.
    settings: ({ "syncInterval": "Only when opened" })
  }

  Timer {
    interval: 800; running: true; repeat: false
    onTriggered: {
      if (svc.signedIn) console.log("FAIL signed in before connecting")
      svc.connectWithClient("id-123", "secret-456")
      if (!svc.connecting) console.log("FAIL not connecting after Connect")
    }
  }

  Timer {
    interval: 3500; running: true; repeat: false
    onTriggered: {
      if (!svc.signedIn) console.log("FAIL still signed out after a sign-in that worked")
      if (svc.connecting) console.log("FAIL still connecting after the run ended")
      if (svc.playlists.length !== 1) console.log("FAIL playlists =", svc.playlists.length)
      if (svc.actionError !== "") console.log("FAIL actionError =", svc.actionError)
      console.log("DONE")
      Qt.quit()
    }
  }
}
QML

cat > "$work/plugin/shell.qml" <<'QML'
import Quickshell
ShellRoot { Harness {} }
QML

out=$(HOME="$work/home" QT_QPA_PLATFORM=offscreen timeout 60 \
  quickshell -p "$work/plugin/shell.qml" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

echo "$out" | grep -q "DONE" || {
  echo "FAIL: the harness never finished"
  echo "$out"
  exit 1
}

if echo "$out" | grep -q "FAIL"; then
  echo "$out" | grep "FAIL"
  exit 1
fi

echo "ok — a first-run sign-in reaches the panel without a restart"
