import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property string runtimeDirectory: Quickshell.env("XDG_RUNTIME_DIR")
  property var accounts: []
  property string discoveryError: ""
  readonly property string requestedAccount: String(settings.account || "")
  readonly property var account: {
    for (var i = 0; i < accounts.length; i++) {
      if (accounts[i].id === requestedAccount) return accounts[i]
    }
    return requestedAccount === "" && accounts.length > 0 ? accounts[0] : null
  }
  readonly property bool hasAccount: account !== null
  readonly property string accountId: account ? account.id : ""
  readonly property string accountLabel: account ? account.label : ""
  readonly property string syncDir: account ? account.syncDir : ""
  readonly property string accountEmail: account ? account.email : ""
  readonly property string unit: account ? account.unit : ""
  readonly property string eventsPath: account ? runtimeDirectory + "/" + account.eventsDirectory + "/events.jsonl" : ""

  function applyAccounts(raw) {
    try {
      var next = JSON.parse(raw)
      if (!Array.isArray(next)) throw new Error("Invalid account list")
      accounts = next
      discoveryError = ""
    } catch (error) {
      discoveryError = "Unable to read OneDrive accounts"
    }
  }

  onAccountIdChanged: {
    applyEvents("")
    applyUnitStatus("")
    Qt.callLater(refresh)
  }
  property string activeState: "unknown"
  property string subState: ""
  property string result: ""
  property string syncState: ""
  property string statusText: "Waiting for OneDrive service"
  property string lastError: ""
  property var transfers: []

  readonly property bool online: activeState === "active"
  readonly property bool connected: Model.isConnected(activeState, result, syncState)
  readonly property string connectionText: connected ? "Connected" : "Disconnected"
  readonly property bool failed: activeState === "failed" || (result !== "" && result !== "success")
  readonly property bool needsAttention: lastError !== "" || ["error", "authentication-required", "action-required", "completed-with-errors"].indexOf(syncState) >= 0
  readonly property string iconStatus: failed || needsAttention ? "failed"
    : (!online ? "offline"
       : ((syncState === "syncing" || syncState === "processing" || syncState === "initializing") ? "syncing" : "online"))
  readonly property string serviceText: failed ? "Service failed"
    : (online ? "Service online" : "Service offline")

  function applyEvents(raw) {
    var snapshot = Model.eventSnapshot(Model.parseJsonl(raw))
    syncState = String(snapshot.syncState || "")
    statusText = String(snapshot.statusText || "Waiting for sync activity")
    lastError = String(snapshot.lastError || "")
    transfers = snapshot.transfers || []
  }

  function applyUnitStatus(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var index = lines[i].indexOf("=")
      if (index > 0) next[lines[i].slice(0, index)] = lines[i].slice(index + 1)
    }
    activeState = String(next.ActiveState || "unknown")
    subState = String(next.SubState || "")
    result = String(next.Result || "")
  }

  function refresh() {
    if (!accountDiscovery.running) accountDiscovery.running = true
    if (hasAccount) {
      eventsFile.reload()
      if (!serviceStatus.running) {
        serviceStatus.requestedUnit = unit
        serviceStatus.running = true
      }
    }
  }

  FileView {
    id: eventsFile
    path: root.eventsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyEvents(text())
    onLoadFailed: root.applyEvents("")
    onFileChanged: reload()
  }

  Process {
    id: accountDiscovery
    command: ["nier-onedrive-setup", "--list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAccounts(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.discoveryError = "Unable to read OneDrive accounts"
    }
  }

  Process {
    id: serviceStatus
    property string requestedUnit: ""
    command: [
      "systemctl", "--user", "show", requestedUnit,
      "--property=ActiveState,SubState,Result", "--no-pager"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (serviceStatus.requestedUnit === root.unit) root.applyUnitStatus(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && serviceStatus.requestedUnit === root.unit) {
        root.activeState = "unknown"
        root.result = "failed"
      }
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
