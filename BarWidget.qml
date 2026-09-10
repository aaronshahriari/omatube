import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for OmaTube. The service owns the cache and the CLI; this reads
// the already-shaped label off it so the count stays live whether or not
// the popup has ever been opened.
BarWidget {
  id: root
  moduleName: "aaronshahriari.omatube"

  // nf-md-playlist_play. A bare play triangle reads as "media is playing",
  // which is the media widget's job; the stacked lines say "a list" first.
  //
  // Written as an escape rather than the literal glyph: a raw private-use
  // character does not survive every editor and tool that touches this
  // file, and when it is silently dropped the widget renders a bare number.
  readonly property string icon: "󰒛"

  // A plug says "needs setup". A dimmed playlist glyph with no count would
  // read as "you have no playlists", which is the opposite.
  readonly property string setupIcon: ""

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("aaronshahriari.omatube")
    : null

  readonly property var cache: service ? service.cache : Model.parseCache("")
  readonly property bool signedIn: service ? service.signedIn === true : false
  readonly property bool syncing: service ? service.syncing === true : false
  readonly property int playlistCount: (cache.playlists || []).length

  readonly property string barLabelMode: setting("barLabel", "Icon")
  readonly property string activeIcon: signedIn ? icon : setupIcon
  readonly property string activeLabel: signedIn ? Model.barLabel(barLabelMode, cache) : "setup"

  readonly property string displayText: activeLabel === ""
    ? activeIcon
    : activeIcon + "  " + activeLabel
  readonly property var verticalLines: activeLabel === ""
    ? [activeIcon]
    : [activeIcon, activeLabel]

  // Right-click cycles what the bar shows, the way the built-in clock and
  // the calendar plugin do. Writing it back through the shell means the
  // choice survives a restart instead of being re-picked every session.
  function cycleBarLabel() {
    var next = Model.cycleBarLabel(barLabelMode)
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.barLabel = next

    // Applied locally first so the bar changes on the click itself; the
    // persisted write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (service) service.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function openFullscreen() {
    if (panelLoader.item && panelLoader.item.openFullscreen) panelLoader.item.openFullscreen()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // An IPC target routes to exactly one handler, but this widget is live
  // once per monitor, so the instance that claimed the target is rarely the
  // one you are looking at. The bar already resolves this for shell.summon
  // by asking Hyprland which output is focused; these borrow that instead
  // of acting locally and opening a panel on the other screen.
  function focusedInstance() {
    if (root.bar && typeof root.bar.findPanelWidget === "function") {
      var item = root.bar.findPanelWidget(root.moduleName)
      if (item) return item
    }
    return root
  }

  IpcHandler {
    target: "aaronshahriari.omatube"

    // Refresh is not a place, so it goes to every instance.
    function sync(): void { root.broadcast("refresh") }

    function cycleLabel(): void { root.focusedInstance().cycleBarLabel() }
    function open(): void { root.focusedInstance().open() }
    function close(): void { root.focusedInstance().close() }
    function show(): void { root.focusedInstance().open() }
    function hide(): void { root.focusedInstance().close() }
    function toggle(): void { root.focusedInstance().togglePanel() }

    // Bindable: `omarchy-shell aaronshahriari.omatube fullscreen` opens the
    // grid without going through the bar at all.
    function fullscreen(): void { root.focusedInstance().openFullscreen() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    fixedWidth: !root.vertical && root.activeLabel === "" ? Style.bar.iconSlot : -1
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1

    active: root.opened
    // A disconnected plugin should look inert rather than like zero videos.
    dimmed: !root.signedIn

    tooltipText: root.signedIn
      ? "OmaTube — " + Model.plural(root.playlistCount, "playlist")
        + "\nright click for " + Model.barLabelDescription(Model.cycleBarLabel(root.barLabelMode))
        + "\nmiddle click to refresh"
      : "OmaTube — click to connect your YouTube account"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.cycleBarLabel()
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 2 ? button.fontSize * 0.85 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
