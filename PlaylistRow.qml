import QtQuick
import qs.Commons
import "Model.js" as Model

// One playlist: thumbnail, title, and how many videos are in it.
Item {
  id: root

  property var playlist: null
  property bool selected: false
  property bool hasCursor: false
  property color foreground: Color.popups.text
  property real thumbWidth: Style.space(64)

  signal activated()

  readonly property bool hot: mouse.containsMouse || hasCursor

  implicitHeight: Math.max(thumb.implicitHeight, text.implicitHeight) + Style.space(10)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: Math.max(2, Style.space(4))
    // Selection outranks hover: while a playlist is open, its row stays lit
    // even as the pointer moves down the video list beside it.
    color: root.selected
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
      : (root.hot ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                  : "transparent")
  }

  Thumb {
    id: thumb
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    source: root.playlist ? (root.playlist.thumb || "") : ""
    foreground: root.foreground
    boxWidth: root.thumbWidth
  }

  Column {
    id: text
    anchors.left: thumb.right
    anchors.leftMargin: Style.space(10)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      text: root.playlist ? root.playlist.title : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    Text {
      width: parent.width
      text: Model.playlistSubtitle(root.playlist)
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      maximumLineCount: 1
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
