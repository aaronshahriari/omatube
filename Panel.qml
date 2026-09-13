import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaTube popup: your playlists, and the videos inside whichever one you
// opened. Two levels deep and no further — the bar is not the place to
// browse YouTube, only to get at something you already saved.
//
// The panel never talks to YouTube itself. `bin/omatube` owns the OAuth
// credentials and every request; this reads the JSON cache that CLI writes
// and shells back out for plays and removals. That keeps a long-lived
// refresh token out of the shell process and makes every mutation a single
// auditable command.
Panel {
  id: root
  moduleName: "io.github.aaronshahriari.omatube"
  ipcTarget: "io.github.aaronshahriari.omatube"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- the shared service ------------------------------------------------
  //
  // A bar exists per monitor, so this panel exists per monitor too. The
  // cache, the sync timer, the write queue and the undo window are all
  // single-instance concerns and live in Service.qml; this reads them.
  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.aaronshahriari.omatube")
    : null

  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  function pushSettings() {
    if (svc && "settings" in svc) svc.settings = root.settings
  }

  readonly property var cache: svc ? svc.cache : Model.parseCache("")
  readonly property date nowDate: svc ? svc.nowDate : new Date()
  readonly property bool signedIn: svc ? svc.signedIn === true : false
  readonly property bool syncing: svc ? svc.syncing === true : false
  readonly property bool connecting: svc ? svc.connecting === true : false
  readonly property string actionError: svc ? svc.actionError : ""
  // A play is probed for a few seconds after the panel has already closed,
  // so its failure lands here and is waiting the next time you open up.
  readonly property string playError: svc ? svc.playError : ""
  readonly property string cacheError: cache.error || ""
  readonly property string loadingPlaylist: svc ? svc.loadingPlaylist : ""
  readonly property var pendingRemovals: svc ? svc.pendingRemovals : []
  readonly property string undoText: svc ? svc.undoText : ""
  readonly property int undoLeft: svc ? svc.undoLeft : 0
  readonly property int staleMinutes: Model.staleMinutes(cache.syncedAt, nowDate.getTime())

  readonly property int maxVideos: svc ? svc.maxVideos : 40
  readonly property bool confirmRemove: svc ? svc.confirmRemove : true

  // ---- view state --------------------------------------------------------

  // "" is the playlist list; anything else is that playlist's videos.
  property string selectedId: ""
  property int cursor: -1
  property string query: ""
  property string confirmingKey: ""

  readonly property var playlists: cache.playlists || []
  readonly property var selectedPlaylist: {
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].id === selectedId) return playlists[i]
    return null
  }

  readonly property var allVideos: Model.videosFor(cache, selectedId)
  readonly property var videos: Model.visibleVideos(
    Model.filterVideos(allVideos, query), pendingRemovals, maxVideos)

  readonly property bool inPlaylist: selectedId !== ""
  readonly property int rowCount: inPlaylist ? videos.length : playlists.length
  readonly property bool loadingVideos: inPlaylist && loadingPlaylist === selectedId
  // An opened-but-empty playlist and one still loading both show no rows.
  readonly property bool emptyPlaylist: inPlaylist && !loadingVideos
    && Model.hasItems(cache, selectedId) && allVideos.length === 0

  function openPlaylist(playlist) {
    if (!playlist) return
    animateNav(1)
    selectedId = playlist.id
    cursor = -1
    query = ""
    confirmingKey = ""
    if (svc) svc.loadItems(playlist.id, false)
  }

  function goBack() {
    if (inPlaylist) animateNav(-1)
    selectedId = ""
    cursor = -1
    query = ""
    confirmingKey = ""
  }

  function refresh(force) {
    if (!svc) return
    svc.refresh(force === undefined ? true : force)
    if (inPlaylist) svc.loadItems(selectedId, true)
  }

  // Starting playback dismisses the panel. You asked for a video; the list
  // you picked it from is in the way of the thing about to open.
  function playVideo(video) {
    if (!svc || !video || video.available === false) return
    svc.play(video)
    close()
  }

  function openVideo(video) {
    if (!svc || !video) return
    svc.openInBrowser(video)
    close()
  }

  // Removal is destructive and the confirm setting decides how it is
  // guarded: either a second click on the same row, or the undo window.
  function requestRemove(video) {
    if (!svc || !video) return
    var key = Model.pendingKey(video)
    if (confirmRemove && confirmingKey !== key) {
      confirmingKey = key
      return
    }
    confirmingKey = ""
    svc.removeVideo(video)
  }

  function undoRemoval() {
    if (svc) svc.undoRemoval()
  }

  function openFullscreen() {
    close()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("io.github.aaronshahriari.omatube", JSON.stringify({ playlist: selectedId }))
  }

  // A short travel, not a full-width fly-in: enough to read as direction
  // without making every step feel like it has to be waited out.
  function animateNav(direction) {
    if (!rowArea) return
    rowArea.slide = direction * Style.space(36)
    slideAnim.restart()
  }

  NumberAnimation {
    id: slideAnim
    target: rowArea
    property: "slide"
    to: 0
    duration: 150
    easing.type: Easing.OutCubic
  }

  // ---- keyboard ----------------------------------------------------------

  function moveCursor(delta) {
    if (rowCount === 0) return
    var next = cursor + delta
    if (next < 0) next = rowCount - 1
    else if (next >= rowCount) next = 0
    cursor = next
    confirmingKey = ""
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= rowCount) return
    if (inPlaylist) playVideo(videos[cursor])
    else openPlaylist(playlists[cursor])
  }

  function removeAtCursor() {
    if (!inPlaylist || cursor < 0 || cursor >= rowCount) return
    requestRemove(videos[cursor])
  }

  // Opening always syncs; the interval setting only governs the idle case.
  onOpenedChanged: {
    if (opened) {
      cursor = -1
      confirmingKey = ""
      refresh(false)
    } else {
      // Walking away commits what is held rather than dropping it: the
      // user asked for those removals.
      if (svc) svc.flushPending()
      query = ""
      confirmingKey = ""
    }
  }

  // ---- surface -----------------------------------------------------------

  readonly property color fg: Color.popups.text
  readonly property color mutedFg: Qt.darker(fg, 1.6)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: search.activeFocus || clientId.activeFocus || clientSecret.activeFocus

      // Escape backs out one layer at a time — a pending confirm, then the
      // playlist, then the panel itself.
      onCloseRequested: {
        if (root.confirmingKey !== "") root.confirmingKey = ""
        else if (root.query !== "") root.query = ""
        else if (root.inPlaylist) root.goBack()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
      }
      // Enter emits both returnRequested and activateRequested; Space emits
      // only activate, which makes activate the one to listen to.
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeAtCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh(true)
        else if (text === "u") root.undoRemoval()
        else if (text === "f") root.openFullscreen()
        else if (text === "d") root.removeAtCursor()
        else if (text === "h") root.goBack()
        else if (text === "/") search.forceActiveFocus()
        else if (text === "o" && root.inPlaylist && root.cursor >= 0)
          root.openVideo(root.videos[root.cursor])
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(6)

          // ---- header
          Item {
            width: parent.width
            height: Math.max(headerText.implicitHeight, headerActions.implicitHeight)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              // Naming the destination beats a bare chevron: "‹ Playlists"
              // says both that there is a way back and where it goes, which
              // an arrow on its own leaves you to infer.
              Item {
                width: parent.width
                height: root.inPlaylist ? crumbText.implicitHeight : 0
                visible: root.inPlaylist
                clip: true

                Text {
                  id: crumbText
                  text: "‹ Playlists"
                  textFormat: Text.PlainText
                  color: crumbMouse.containsMouse ? root.fg : Qt.darker(root.fg, 1.7)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: crumbMouse
                  anchors.verticalCenter: crumbText.verticalCenter
                  height: parent.height + Style.space(6)
                  width: crumbText.implicitWidth + Style.space(10)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goBack()
                }
              }

              Text {
                width: parent.width
                text: root.inPlaylist && root.selectedPlaylist
                  ? root.selectedPlaylist.title
                  : "OmaTube"
                textFormat: Text.PlainText
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Text {
                width: parent.width
                text: {
                  if (!root.signedIn) return "not connected"
                  if (root.inPlaylist) return Model.playlistSubtitle(root.selectedPlaylist)
                  if (root.playlists.length === 0) return "no playlists"
                  return Model.plural(root.playlists.length, "playlist")
                    + (root.cache.channel ? " · " + root.cache.channel : "")
                }
                textFormat: Text.PlainText
                color: root.mutedFg
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                iconText: "\uDB81\uDC0A"  // nf-md-play
                tooltipText: "Play the whole playlist"
                foreground: root.fg
                visible: root.inPlaylist && root.allVideos.length > 0
                onClicked: {
                  if (root.svc) root.svc.playPlaylist(root.selectedPlaylist)
                  root.close()
                }
              }

              PanelActionButton {
                iconText: "\uDB80\uDE93"  // nf-md-fullscreen
                tooltipText: "Open fullscreen (f)"
                foreground: root.fg
                visible: root.signedIn
                onClicked: root.openFullscreen()
              }

              PanelActionButton {
                iconText: "\uDB81\uDC50"  // nf-md-refresh
                tooltipText: root.syncing ? "Syncing…" : "Refresh (r)"
                foreground: root.fg
                enabled: !root.syncing
                opacity: root.syncing ? 0.5 : 1
                onClicked: root.refresh(true)
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---- error banner
          Text {
            width: parent.width
            visible: text !== ""
            // While the connect form is up, the cache's own "not signed in"
            // is the same sentence twice — but a sign-in that just failed is
            // the only thing that explains why the form is still there, so
            // that one is shown and the cached one is not.
            text: !root.signedIn ? root.actionError
              : (root.playError !== "" ? root.playError
                : (root.actionError !== "" ? root.actionError : root.cacheError))
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- sign-in
          Column {
            width: parent.width
            visible: !root.signedIn
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "OmaTube needs its own YouTube API client — run "
                + "`bin/omatube setup` in a terminal for the two-minute walkthrough, "
                + "then paste the client ID and secret here."
              textFormat: Text.PlainText
              color: root.mutedFg
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: clientId
              width: parent.width
              placeholderText: "Client ID"
              foreground: root.fg
              onAccepted: clientSecret.forceActiveFocus()
            }

            TextField {
              id: clientSecret
              width: parent.width
              placeholderText: "Client secret"
              password: true
              foreground: root.fg
              onAccepted: root.connect()
            }

            Button {
              text: root.connecting ? "Connecting…" : "Connect"
              enabled: !root.connecting && clientId.text !== "" && clientSecret.text !== ""
              onClicked: root.connect()
            }
          }

          // ---- search
          TextField {
            id: search
            width: parent.width
            visible: root.signedIn && root.inPlaylist && root.allVideos.length > 8
            placeholderText: "Filter videos…"
            foreground: root.fg
            text: root.query
            onTextChanged: {
              root.query = text
              root.cursor = -1
            }
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else keyCatcher.forceActiveFocus()
            }
          }

          // ---- rows
          //
          // The list slides in from whichever side the navigation came
          // from — right when you open a playlist, left when you come back.
          // Without it the popup swaps one list of rows for another with no
          // sign that anything moved, which reads as a glitch rather than a
          // step.
          Column {
            id: rowArea
            width: parent.width
            spacing: 0

            property real slide: 0
            transform: Translate { x: rowArea.slide }

          // ---- playlists
          Repeater {
            model: root.signedIn && !root.inPlaylist ? root.playlists : []

            PlaylistRow {
              required property var modelData
              required property int index
              width: content.width
              playlist: modelData
              hasCursor: root.cursor === index
              foreground: root.fg
              onActivated: root.openPlaylist(modelData)
            }
          }

          // ---- videos
          Repeater {
            model: root.signedIn && root.inPlaylist ? root.videos : []

            VideoRow {
              required property var modelData
              required property int index
              width: content.width
              video: modelData
              hasCursor: root.cursor === index
              pending: root.svc ? root.svc.isPending(modelData) : false
              foreground: root.fg
              urgent: Color.urgent
              onActivated: root.playVideo(modelData)
              onOpenRequested: root.openVideo(modelData)
              onRemoveRequested: root.requestRemove(modelData)
            }
          }

          }

          // ---- confirm strip
          //
          // Sits under the list rather than replacing the row, so the video
          // being removed is still readable while the question is asked.
          Text {
            width: parent.width
            visible: root.confirmingKey !== ""
            text: "Click remove again to confirm · Esc to cancel"
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          // ---- empty and loading states
          Text {
            width: parent.width
            visible: root.signedIn && (root.loadingVideos || root.emptyPlaylist
              || (root.inPlaylist && root.query !== "" && root.videos.length === 0)
              || (!root.inPlaylist && root.playlists.length === 0 && !root.syncing))
            text: {
              if (root.loadingVideos) return "Loading videos…"
              if (root.inPlaylist && root.query !== "" && root.videos.length === 0)
                return "No videos match “" + Model.elide(root.query, 24) + "”"
              if (root.emptyPlaylist) return "This playlist is empty"
              return "No playlists yet"
            }
            textFormat: Text.PlainText
            color: root.mutedFg
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(10)
            bottomPadding: Style.space(10)
          }

          // ---- undo
          Item {
            width: parent.width
            height: visible ? undoRow.implicitHeight + Style.space(8) : 0
            visible: root.pendingRemovals.length > 0

            Row {
              id: undoRow
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.undoText
                textFormat: Text.PlainText
                color: root.mutedFg
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "Undo (" + root.undoLeft + ")"
                onClicked: root.undoRemoval()
              }
            }
          }

          // ---- footer
          Text {
            width: parent.width
            visible: root.signedIn && root.staleMinutes > 5
            text: "synced " + root.staleMinutes + "m ago"
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 2.0)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  function connect() {
    if (!svc) return
    svc.connectWithClient(clientId.text, clientSecret.text)
    clientSecret.text = ""
  }
}
