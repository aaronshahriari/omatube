import QtQuick
import qs.Commons

// A YouTube thumbnail in its 16:9 box.
//
// The box is drawn whether or not an image arrives: a private video has no
// thumbnail at all, and a remote fetch can be slow or fail outright. Without
// a placeholder holding the space, every row would reflow as images land.
Rectangle {
  id: root

  property string source: ""
  property color foreground: Color.popups.text
  property real boxWidth: Style.space(64)

  implicitWidth: boxWidth
  implicitHeight: Math.round(boxWidth * 9 / 16)
  radius: Math.max(2, Style.space(3))
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.07)
  clip: true

  Image {
    id: thumbImage
    anchors.fill: parent
    source: root.source
    // Off the QML thread: a panel with forty rows would otherwise block on
    // forty network fetches before painting anything at all.
    asynchronous: true
    cache: true
    // YouTube's medium thumbnail is 320x180 with letterbox bars on some
    // uploads; cropping to the box trims them instead of showing black.
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: Math.round(root.boxWidth * 2)
    visible: status === Image.Ready
  }

  // Stands in while loading, permanently for rows that have no image, and
  // for one that has a URL the server will not serve — a thumbnail can 404
  // at any time, and a silently empty box looks like a broken widget.
  Text {
    anchors.centerIn: parent
    visible: root.source === "" || thumbImage.status === Image.Error
    text: "\uDB81\uDDC3"  // nf-md-youtube
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
