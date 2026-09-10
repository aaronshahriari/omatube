import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The fullscreen half of OmaTube: playlists down the left, the videos in
// the selected one filling the rest.
//
// The bar popup is for grabbing something you already know is there. This
// is for the other case — scanning a long playlist, clearing out things you
// have finished, playing a run of videos — where a 400px popup anchored to
// the bar runs out of room immediately.
//
// It shares Service.qml with the popup, so the cache, the sync timer and a
// held removal are the same objects in both. Removing a video here and
// opening the popup before the undo window closes shows the same struck-
// through row, not a stale copy.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "aaronshahriari.omatube"

  property bool opened: false

  readonly property var svc: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor(pluginId)
    : null

  readonly property var cache: svc ? svc.cache : Model.parseCache("")
  readonly property bool signedIn: svc ? svc.signedIn === true : false
  readonly property bool syncing: svc ? svc.syncing === true : false
  readonly property string actionError: svc ? svc.actionError : ""
  readonly property string loadingPlaylist: svc ? svc.loadingPlaylist : ""
  readonly property var pendingRemovals: svc ? svc.pendingRemovals : []
  readonly property string undoText: svc ? svc.undoText : ""
  readonly property int undoLeft: svc ? svc.undoLeft : 0
  readonly property bool confirmRemove: svc ? svc.confirmRemove : true

  readonly property var playlists: cache.playlists || []

  property string selectedId: ""
  property int cursor: -1
  property string query: ""
  property string confirmingKey: ""

  readonly property var selectedPlaylist: {
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].id === selectedId) return playlists[i]
    return null
  }

  readonly property var allVideos: Model.videosFor(cache, selectedId)
  // No cap here: the whole point of the fullscreen view is seeing the lot.
  readonly property var videos: Model.filterVideos(allVideos, query)
  readonly property bool loadingVideos: selectedId !== "" && loadingPlaylist === selectedId

  // ---- lifecycle ---------------------------------------------------------

  function open(payloadJson) {
    opened = true
    cursor = -1
    query = ""
    confirmingKey = ""

    // The popup hands over whichever playlist was on screen, so opening
    // fullscreen continues where it left off rather than resetting.
    var wanted = ""
    try {
      var payload = JSON.parse(payloadJson || "{}")
      wanted = payload.playlist || ""
    } catch (e) {
      wanted = ""
    }

    if (svc) svc.refresh(false)
    selectPlaylist(wanted !== "" ? wanted : (playlists.length > 0 ? playlists[0].id : ""))
  }

  // Host-initiated close (`shell hide`). The user-initiated paths route
  // through shell.hide so the host's open-panel state stays consistent,
  // and land back here.
  function close() {
    opened = false
    // Walking away commits what is held rather than dropping it.
    if (svc) svc.flushPending()
    query = ""
    confirmingKey = ""
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // The first sync after a cold open can arrive with no playlist selected;
  // pick one as soon as there is something to pick.
  onPlaylistsChanged: {
    if (opened && selectedId === "" && playlists.length > 0)
      selectPlaylist(playlists[0].id)
  }

  // ---- actions -----------------------------------------------------------

  function selectPlaylist(id) {
    selectedId = id || ""
    cursor = -1
    query = ""
    confirmingKey = ""
    if (svc && selectedId !== "") svc.loadItems(selectedId, false)
  }

  function playVideo(video) {
    if (svc && video && video.available !== false) svc.play(video)
  }

  function openVideo(video) {
    if (svc && video) svc.openInBrowser(video)
  }

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

  function refresh() {
    if (!svc) return
    svc.refresh(true)
    if (selectedId !== "") svc.loadItems(selectedId, true)
  }

  // ---- keyboard ----------------------------------------------------------

  function moveCursor(delta) {
    if (videos.length === 0) return
    var next = cursor + delta
    if (next < 0) next = videos.length - 1
    else if (next >= videos.length) next = 0
    cursor = next
    confirmingKey = ""
    videoList.positionViewAtIndex(next, ListView.Contain)
  }

  function movePlaylist(delta) {
    if (playlists.length === 0) return
    var at = -1
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].id === selectedId) { at = i; break }
    var next = at + delta
    if (next < 0) next = playlists.length - 1
    else if (next >= playlists.length) next = 0
    selectPlaylist(playlists[next].id)
  }

  readonly property color fg: Color.menu.text
  readonly property color mutedFg: Qt.darker(fg, 1.6)

  PanelWindow {
    id: window

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omatube"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Scrim. Clicking it dismisses, the way every other omarchy overlay
    // behaves; the card above stops the click from reaching it.
    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(1100))
      height: Math.min(parent.height - Style.space(80), Style.space(720))
      radius: Math.max(Style.cornerRadius, Style.space(6))
      color: Color.menu.background
      border.width: Math.max(1, Style.space(1))
      border.color: Color.menu.border

      // Swallows clicks so they do not reach the dismissing scrim.
      MouseArea { anchors.fill: parent }

      focus: root.opened
      Keys.onPressed: function(event) {
        if (searchField.activeFocus) return
        if (event.key === Qt.Key_Escape) {
          if (root.confirmingKey !== "") root.confirmingKey = ""
          else if (root.query !== "") root.query = ""
          else root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
          root.moveCursor(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
          root.moveCursor(-1); event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.movePlaylist(event.modifiers & Qt.ShiftModifier ? -1 : 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                   || event.key === Qt.Key_Space) {
          if (root.cursor >= 0) root.playVideo(root.videos[root.cursor])
          event.accepted = true
        } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_D) {
          if (root.cursor >= 0) root.requestRemove(root.videos[root.cursor])
          event.accepted = true
        } else if (event.key === Qt.Key_U) {
          if (root.svc) root.svc.undoRemoval()
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          root.refresh(); event.accepted = true
        } else if (event.key === Qt.Key_O) {
          if (root.cursor >= 0) root.openVideo(root.videos[root.cursor])
          event.accepted = true
        } else if (event.key === Qt.Key_Slash) {
          searchField.forceActiveFocus(); event.accepted = true
        }
      }

      // ---- header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(16)
        height: Style.space(34)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "OmaTube"
          textFormat: Text.PlainText
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 1.25
          font.bold: true
        }

        Text {
          anchors.right: headerActions.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: root.actionError !== "" ? root.actionError
            : (root.cache.channel ? root.cache.channel : "")
          textFormat: Text.PlainText
          color: root.actionError !== "" ? Color.urgent : root.mutedFg
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          id: headerActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          PanelActionButton {
            iconText: ""
            tooltipText: "Play the whole playlist"
            foreground: root.fg
            visible: root.allVideos.length > 0
            onClicked: {
              if (root.svc) root.svc.playPlaylist(root.selectedPlaylist)
            }
          }

          PanelActionButton {
            iconText: "󰑐"
            tooltipText: root.syncing ? "Syncing…" : "Refresh (r)"
            foreground: root.fg
            enabled: !root.syncing
            opacity: root.syncing ? 0.5 : 1
            onClicked: root.refresh()
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Close (Esc)"
            foreground: root.fg
            onClicked: root.dismiss()
          }
        }
      }

      PanelSeparator {
        id: headerRule
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        foreground: root.fg
      }

      // ---- sidebar: playlists
      Item {
        id: sidebar
        anchors.top: headerRule.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.topMargin: Style.space(8)
        anchors.bottomMargin: Style.space(16)
        anchors.leftMargin: Style.space(16)
        width: Style.space(280)

        ListView {
          id: playlistList
          anchors.fill: parent
          model: root.playlists
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: PlaylistRow {
            required property var modelData
            width: playlistList.width - Style.space(8)
            playlist: modelData
            selected: modelData.id === root.selectedId
            foreground: root.fg
            thumbWidth: Style.space(56)
            onActivated: root.selectPlaylist(modelData.id)
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.playlists.length === 0
          text: root.signedIn ? "No playlists" : "Not connected — open the bar widget to sign in"
          textFormat: Text.PlainText
          color: root.mutedFg
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          width: parent.width - Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }

      Rectangle {
        id: divider
        anchors.left: sidebar.right
        anchors.leftMargin: Style.space(12)
        anchors.top: sidebar.top
        anchors.bottom: sidebar.bottom
        width: Math.max(1, Style.space(1))
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
      }

      // ---- main: videos
      Item {
        id: main
        anchors.left: divider.right
        anchors.leftMargin: Style.space(12)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(16)
        anchors.top: sidebar.top
        anchors.bottom: sidebar.bottom

        Item {
          id: mainHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(30)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: searchField.left
            anchors.rightMargin: Style.space(10)
            text: root.selectedPlaylist
              ? root.selectedPlaylist.title + "  ·  " + Model.playlistSubtitle(root.selectedPlaylist)
              : ""
            textFormat: Text.PlainText
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          TextField {
            id: searchField
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(220)
            placeholderText: "Filter videos…  (/)"
            foreground: root.fg
            text: root.query
            onTextChanged: {
              root.query = text
              root.cursor = -1
            }
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else card.forceActiveFocus()
            }
          }
        }

        ListView {
          id: videoList
          anchors.top: mainHeader.bottom
          anchors.topMargin: Style.space(6)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: undoBar.top
          anchors.bottomMargin: Style.space(6)
          model: root.videos
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          // Rows are cheap but thumbnails are not; keeping a screen's worth
          // either side stops a fast scroll from re-fetching what it just
          // scrolled past. Clamped because `height` is briefly negative
          // while the anchors above it are still resolving, and ListView
          // rejects a negative buffer outright.
          cacheBuffer: Math.max(0, height)

          delegate: VideoRow {
            required property var modelData
            required property int index
            width: videoList.width
            video: modelData
            hasCursor: root.cursor === index
            pending: root.svc ? root.svc.isPending(modelData) : false
            foreground: root.fg
            urgent: Color.urgent
            thumbWidth: Style.space(96)
            onActivated: root.playVideo(modelData)
            onOpenRequested: root.openVideo(modelData)
            onRemoveRequested: root.requestRemove(modelData)
          }
        }

        Text {
          anchors.centerIn: videoList
          width: videoList.width - Style.space(40)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: text !== ""
          text: {
            if (root.loadingVideos) return "Loading videos…"
            if (root.selectedId === "") return ""
            if (root.videos.length > 0) return ""
            if (root.query !== "") return "No videos match “" + Model.elide(root.query, 30) + "”"
            if (Model.hasItems(root.cache, root.selectedId)) return "This playlist is empty"
            return ""
          }
          textFormat: Text.PlainText
          color: root.mutedFg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // ---- undo / confirm strip
        Item {
          id: undoBar
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: (root.pendingRemovals.length > 0 || root.confirmingKey !== "")
            ? Style.space(30) : 0
          visible: height > 0

          Text {
            anchors.centerIn: parent
            visible: root.confirmingKey !== "" && root.pendingRemovals.length === 0
            text: "Press remove again to confirm · Esc to cancel"
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.centerIn: parent
            visible: root.pendingRemovals.length > 0
            spacing: Style.space(10)

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
              onClicked: if (root.svc) root.svc.undoRemoval()
            }
          }
        }
      }
    }
  }
}
