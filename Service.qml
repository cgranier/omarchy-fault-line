import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads the journal's error lines and the failed units, and remembers how far
// you have looked, what you have muted, and which window you like.
Item {
  id: root

  property var settings: ({})

  property var entries: []
  property var problems: []        // shown
  property var failed: []          // shown
  property var mutedItems: []      // failed units and problems you muted
  property var counts: Model.counts([], [], 0)
  property double seenMs: 0
  property var muted: []
  property var seenFailed: []     // failed-unit keys already looked at
  property string window: "boot"
  property double now: Date.now()
  property string summary: "Checking…"
  property bool loaded: false
  property bool agentAvailable: false
  property string actionStatus: ""

  readonly property int maxPriority: intSetting("maxPriority", 3, 0, 4)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 15, 3600)
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-faultline"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (!journalProcess.running) {
      // Bounded twice: journalctl hands over at most the newest lines it is
      // asked for, and head caps the bytes before anything is buffered here.
      journalProcess.command = ["timeout", "15", "sh", "-c", 'journalctl "$@" | head -c 8000000', "sh",
        "-q", "-o", "json", "-p", String(maxPriority), "-n", String(Model.MAX_RECORDS),
        "--output-fields=MESSAGE,PRIORITY,_TRANSPORT,_SYSTEMD_UNIT,_SYSTEMD_USER_UNIT,SYSLOG_IDENTIFIER,_COMM"]
        .concat(Model.windowById(window).args)
      journalProcess.running = true
    }
    if (!failedSystemProcess.running) failedSystemProcess.running = true
    if (!failedUserProcess.running) failedUserProcess.running = true
    if (!agentProcess.running) agentProcess.running = true
  }

  property var failedSystem: []
  property var failedUser: []

  function recount() {
    now = Date.now()
    var allFailed = failedSystem.concat(failedUser)
    for (var i = 0; i < allFailed.length; i++) allFailed[i].fresh = seenFailed.indexOf(allFailed[i].key) === -1
    var f = Model.splitMuted(allFailed, muted)
    var p = Model.splitMuted(Model.foldProblems(entries, seenMs), muted)
    failed = f.shown
    problems = p.shown
    mutedItems = f.hidden.concat(p.hidden)
    counts = Model.counts(failed, problems, seenMs)
    summary = Model.summaryText(counts, window, mutedItems.length)
  }

  // The state file is never opened by the shell: bin/faultline-state checks
  // the directory chain, refuses links, FIFOs and oversized files, and writes
  // atomically. Writes are serialised; one made while another runs waits.
  readonly property string stateScript: String(Qt.resolvedUrl("bin/faultline-state")).replace(/^file:\/\//, "")
  property string pendingWrite: ""

  function saveState() {
    pendingWrite = Model.serializeState({ seenMs: seenMs, muted: muted, window: window, seenFailed: seenFailed })
    if (!writeProcess.running) flushWrite()
  }

  function flushWrite() {
    if (pendingWrite === "") return
    writeProcess.command = ["timeout", "10", "/usr/bin/python3", stateScript, "write", stateDir + "/state.json", pendingWrite]
    pendingWrite = ""
    writeProcess.running = true
  }

  // A failed unit has no timestamp of its own here; it is new until the panel
  // has been closed once while it was failed, and the list of those is kept.
  function markSeen() {
    var latest = entries.length > 0 ? entries[0].tsMs : 0
    var changed = false
    if (latest > seenMs) { seenMs = latest; changed = true }
    var allFailed = failedSystem.concat(failedUser)
    var keys = seenFailed.slice()
    for (var i = 0; i < allFailed.length; i++) if (keys.indexOf(allFailed[i].key) === -1) { keys.push(allFailed[i].key); changed = true }
    if (keys.length !== seenFailed.length) seenFailed = keys
    if (changed) { saveState(); recount() }
  }

  function toggleMute(item) {
    if (!item) return
    var next = muted.filter(function(key) { return key !== item.key })
    var nowMuted = next.length === muted.length
    if (nowMuted) next.push(item.key)
    muted = next
    saveState()
    recount()
    say((nowMuted ? "Muted " : "Unmuted ") + item.unit)
  }

  function cycleWindow() {
    window = Model.nextWindow(window)
    saveState()
    refresh()
  }

  function say(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // ---- actions --------------------------------------------------------------
  // The agent gets the unit and the command, never the log's own text.
  function diagnose(item) {
    if (!item || !agentAvailable) return
    var prompt = Model.diagnosisPrompt(item, Date.now(), window)
    if (prompt === null) { say("That unit name is not one to hand to a command"); return }
    Quickshell.execDetached(["omarchy-agent-prompt", prompt])
  }

  function showLog(item) {
    var cmd = Model.logCommand(item, window)
    if (!cmd) { if (item) say("That unit name is not one to hand to a command"); return }
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.faultline", "bash", "-c",
      '"$@" 2>&1 | less -R', "bash"].concat(cmd))
  }

  function copyReport(item) {
    if (!item) return
    Quickshell.execDetached(["wl-copy", Model.reportText(item, Date.now(), window)])
    say("Copied " + item.unit)
  }

  onSettingsChanged: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: readProcess
    running: true
    command: ["timeout", "10", "/usr/bin/python3", root.stateScript, "read", root.stateDir + "/state.json"]
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    onExited: function(exitCode) {
      // A refused or missing file means a fresh start; nothing is written
      // over it until the person does something that changes state.
      var state = Model.parseState(exitCode === 0 ? readOut.text : "{}")
      root.seenMs = state.seenMs
      root.muted = state.muted
      root.window = state.window
      root.seenFailed = state.seenFailed
      root.refresh()
    }
  }

  Process {
    id: writeProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) root.say("Could not save Fault Line's state")
      root.flushWrite()
    }
  }

  Process {
    id: journalProcess
    running: false
    command: []
    stdout: StdioCollector { id: journalOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.entries = Model.parseJournal(journalOut.text)
      root.loaded = true
      root.recount()
    }
  }

  Process {
    id: failedSystemProcess
    running: false
    command: ["timeout", "10", "sh", "-c", 'systemctl "$@" | head -c 1000000', "sh", "list-units", "--failed", "--output=json", "--no-pager"]
    stdout: StdioCollector { id: failedSystemOut; waitForEnd: true }
    onExited: function(exitCode) { root.failedSystem = Model.parseFailed(failedSystemOut.text, "system"); root.recount() }
  }

  Process {
    id: failedUserProcess
    running: false
    command: ["timeout", "10", "sh", "-c", 'systemctl "$@" | head -c 1000000', "sh", "--user", "list-units", "--failed", "--output=json", "--no-pager"]
    stdout: StdioCollector { id: failedUserOut; waitForEnd: true }
    onExited: function(exitCode) { root.failedUser = Model.parseFailed(failedUserOut.text, "user"); root.recount() }
  }

  Process {
    id: agentProcess
    running: false
    command: ["timeout", "10", "omarchy-default-agent"]
    stdout: StdioCollector { id: agentOut; waitForEnd: true }
    onExited: function(exitCode) { root.agentAvailable = String(agentOut.text || "").trim() !== "" }
  }
}
