import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root

  moduleName: "nier.onedrive"
  ipcTarget: "nier.onedrive." + (onedrive.requestedAccount || onedrive.accountId || "setup")
  manageIpc: false
  implicitWidth: onedrive.hasAccount ? button.implicitWidth : addAccountButton.implicitWidth
  implicitHeight: onedrive.hasAccount ? button.implicitHeight : addAccountButton.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function statusColor(status) {
    if (status === "failed") return urgent
    if (status === "offline") return dim
    if (status === "syncing") return Color.accent
    return foreground
  }

  readonly property bool hasAccount: onedrive.hasAccount
  readonly property string accountId: onedrive.accountId
  readonly property string accountLabel: onedrive.accountLabel
  readonly property string accountEmail: onedrive.accountEmail

  function openFolder() {
    if (!onedrive.syncDir) return
    Util.execArgv(["xdg-open", onedrive.syncDir])
    root.close()
  }

  function addAccount() {
    if (!setup.running) setup.running = true
    root.close()
  }

  Process {
    id: setup
    command: ["nier-launch-tui", "--app-id=org.nier.onedrive-setup", "nier-onedrive-setup"]
  }

  Service {
    id: onedrive
    settings: root.settings
  }

  IpcHandler {
    enabled: onedrive.hasAccount
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { onedrive.refresh(); return "ok" }
    function status(): string { return onedrive.accountLabel + ": " + onedrive.serviceText + ": " + onedrive.statusText }
  }

  component OneDriveMark: Item {
    id: mark
    property bool connected: false

    implicitWidth: Style.space(14)
    implicitHeight: Style.space(14)
    width: implicitWidth
    height: implicitHeight

    Image {
      anchors.centerIn: parent
      source: Qt.resolvedUrl(mark.connected ? "onedrive.svg" : "onedrive-offline.svg")
      sourceSize.width: parent.width
      sourceSize.height: parent.height
      fillMode: Image.PreserveAspectFit
    }
  }

  WidgetButton {
    id: addAccountButton
    objectName: "addAccountButton"
    anchors.fill: parent
    visible: !onedrive.hasAccount
    bar: root.bar
    text: "+ Add account"
    tooltipText: onedrive.discoveryError || "Set up a OneDrive account"
    onPressed: root.addAccount()
  }

  WidgetButton {
    id: button
    objectName: "accountStatusButton"
    anchors.fill: parent
    visible: onedrive.hasAccount
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    implicitWidth: vertical ? barSize : Style.space(30)
    tooltipText: "OneDrive · " + onedrive.accountLabel + " · " + onedrive.connectionText
    OneDriveMark {
      anchors.centerIn: parent
      connected: onedrive.connected
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) onedrive.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && onedrive.hasAccount
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.addAccount()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") onedrive.refresh()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
          id: content
          width: parent.width
          spacing: Style.space(12)

          RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(14)
            Layout.rightMargin: Style.space(14)
            Layout.topMargin: Style.space(14)
            spacing: Style.space(10)

            OneDriveMark {
              connected: onedrive.connected
              Layout.alignment: Qt.AlignTop
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "OneDrive · " + onedrive.accountLabel
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: onedrive.accountEmail || "Not recorded"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }

              Text {
                Layout.fillWidth: true
                text: onedrive.connectionText + " · " + onedrive.statusText
                color: root.statusColor(onedrive.iconStatus)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              objectName: "openFolderButton"
              iconText: "󰉋"
              tooltipText: Model.displayPath(onedrive.syncDir, Quickshell.env("HOME"))
              enabled: onedrive.syncDir !== ""
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openFolder()
            }

            PanelActionButton {
              objectName: "panelAddAccountButton"
              iconText: "+"
              tooltipText: "Add an account"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.addAccount()
            }

            PanelActionButton {
              tooltipText: "Refresh"
              iconText: "󰑐"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: onedrive.refresh()
            }
          }

          Text {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(14)
            Layout.rightMargin: Style.space(14)
            visible: onedrive.lastError !== ""
            textFormat: Text.PlainText
            text: onedrive.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(14)
            Layout.rightMargin: Style.space(14)
            height: Style.spacing.hairline
            color: root.foreground
            opacity: 0.12
          }

          Text {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(14)
            Layout.rightMargin: Style.space(14)
            text: onedrive.transfers.length > 0 ? "Synchronizing files" : "No files are currently synchronizing"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: onedrive.transfers

            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              Layout.leftMargin: Style.space(14)
              Layout.rightMargin: Style.space(14)
              spacing: Style.space(9)

              Text {
                text: Model.fileGlyph(modelData.path)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                Layout.alignment: Qt.AlignTop
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelData.path
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideMiddle
                }

                Text {
                  Layout.fillWidth: true
                  text: Model.transferText(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(8)
          }
        }
      }
    }
  }
}
