import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One video in a playlist: thumbnail, title, channel and length, plus the
// two actions worth a click — play it, or drop it from the list.
//
// The action buttons only appear on hover or under the keyboard cursor. A
// remove button sitting permanently beside every row invites the misclick
// it cannot take back.
Item {
  id: root

  property var video: null
  property bool hasCursor: false
  property bool pending: false
  property color foreground: Color.popups.text
  property color urgent: Color.urgent
  property real thumbWidth: Style.space(64)

  signal activated()
  signal removeRequested()
  signal openRequested()

  readonly property bool available: video ? video.available !== false : false
  // A HoverHandler, not the MouseArea's containsMouse: the action buttons
  // sit above that MouseArea, so moving onto one would clear containsMouse
  // and hide the very button being reached for. A handler on the root
  // stays hovered anywhere inside the row, children included.
  readonly property bool hot: hover.hovered || hasCursor
  readonly property bool showActions: hot && !pending

  implicitHeight: Math.max(thumb.implicitHeight, text.implicitHeight) + Style.space(10)
  height: implicitHeight
  opacity: pending ? 0.45 : 1

  Rectangle {
    anchors.fill: parent
    radius: Math.max(2, Style.space(4))
    color: root.hot
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
      : "transparent"
  }

  Thumb {
    id: thumb
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    source: root.video ? (root.video.thumb || "") : ""
    foreground: root.foreground
    boxWidth: root.thumbWidth
  }

  Column {
    id: text
    anchors.left: thumb.right
    anchors.leftMargin: Style.space(10)
    anchors.right: actions.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      text: root.video ? root.video.title : ""
      textFormat: Text.PlainText
      // A held removal is struck through rather than pulled out of the
      // list, so undo has a row to put back and nothing jumps.
      font.strikeout: root.pending
      color: root.available ? root.foreground : Qt.darker(root.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    Text {
      width: parent.width
      text: Model.videoSubtitle(root.video)
      textFormat: Text.PlainText
      color: root.available ? Qt.darker(root.foreground, 1.6) : root.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      maximumLineCount: 1
    }
  }

  HoverHandler { id: hover }

  // Declared before the action buttons so they paint and take presses on
  // top of it; this catches clicks on the rest of the row.
  MouseArea {
    anchors.fill: parent
    cursorShape: root.available ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function(event) {
      if (!root.available) return
      if (event.button === Qt.MiddleButton) root.openRequested()
      else root.activated()
    }
  }

  Row {
    id: actions
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)
    // Kept in the layout even when hidden, so titles do not re-elide and
    // shuffle sideways as the pointer travels down the list.
    opacity: root.showActions ? 1 : 0
    visible: opacity > 0

    Behavior on opacity { NumberAnimation { duration: 90 } }

    PanelActionButton {
      iconText: ""
      tooltipText: "Play"
      foreground: root.foreground
      // A video YouTube will not serve cannot be played; removing it is
      // the only action left, so the play button goes away rather than
      // failing silently in a detached mpv nobody sees.
      visible: root.available
      onClicked: root.activated()
    }

    PanelActionButton {
      iconText: "󰖟"
      tooltipText: "Open on youtube.com"
      foreground: root.foreground
      visible: root.available
      onClicked: root.openRequested()
    }

    PanelActionButton {
      iconText: "󰩹"
      tooltipText: "Remove from playlist"
      foreground: root.foreground
      hoverColor: root.urgent
      onClicked: root.removeRequested()
    }
  }

}
