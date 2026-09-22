// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

const NOW = 1790100000000
const line = (o) => JSON.stringify(Object.assign({ PRIORITY: "3", __REALTIME_TIMESTAMP: String((NOW - 60000) * 1000) }, o))
const raw = [
  line({ MESSAGE: "wlp2s0: nl80211: kernel reports: multicast RX registrations are not supported", _SYSTEMD_UNIT: "wpa_supplicant.service", SYSLOG_IDENTIFIER: "wpa_supplicant", __REALTIME_TIMESTAMP: String((NOW - 30000) * 1000) }),
  line({ MESSAGE: "wlp2s0: nl80211: kernel reports: multicast RX registrations are not supported", _SYSTEMD_UNIT: "wpa_supplicant.service", __REALTIME_TIMESTAMP: String((NOW - 3600000) * 1000) }),
  line({ MESSAGE: "usb 2-2: device not accepting address 5, error -62", _TRANSPORT: "kernel", __REALTIME_TIMESTAMP: String((NOW - 120000) * 1000) }),
  line({ MESSAGE: "usb 2-2: device not accepting address 7, error -62", _TRANSPORT: "kernel", PRIORITY: "2", __REALTIME_TIMESTAMP: String((NOW - 100000) * 1000) }),
  line({ MESSAGE: "Failed to start", _SYSTEMD_USER_UNIT: "tablet-autorotate.service", _SYSTEMD_UNIT: "user@1000.service", __REALTIME_TIMESTAMP: String((NOW - 10000) * 1000) }),
  line({ MESSAGE: [72, 105, 200], SYSLOG_IDENTIFIER: "weird" }),
  line({ MESSAGE: "   " }),
  "not json",
  ""
].join("\n")

const entries = M.parseJournal(raw)

test("parseJournal picks the most specific unit, newest first, and survives junk", () => {
  assert.strictEqual(entries.length, 6)
  assert.deepStrictEqual(entries.map((e) => e.scope + ":" + e.unit),
    ["user:tablet-autorotate.service", "system:wpa_supplicant.service", "system:weird", "kernel:kernel", "kernel:kernel", "system:wpa_supplicant.service"])
  assert.strictEqual(entries[2].message, "Hi?")
  assert.strictEqual(entries[3].priority, 2)
  assert.deepStrictEqual(M.parseJournal(""), [])
})

test("normalize makes lines that differ only in numbers the same problem", () => {
  assert.strictEqual(M.normalize("usb 2-2: device not accepting address 5, error -62"), M.normalize("usb 2-2: device not accepting address 7, error -62"))
  assert.strictEqual(M.normalize("<error> [1789872522.8036] device (wlp2s0): x"), "<error> [#] device (wlp2s0): x")
  assert.strictEqual(M.normalize("Opcode 0x0c01 failed: -110"), "Opcode 0x# failed: -#")
  assert.notStrictEqual(M.normalize("Failed to start"), M.normalize("Failed to stop"))
})

const problems = M.foldProblems(entries, NOW - 50000)

test("foldProblems: one row per unit and message shape, worst priority, latest sample, fresh count", () => {
  assert.deepStrictEqual(problems.map((p) => p.unit + "×" + p.count), ["tablet-autorotate.service×1", "wpa_supplicant.service×2", "weird×1", "kernel×2"])
  const usb = problems[3]
  assert.strictEqual(usb.sample, "usb 2-2: device not accepting address 7, error -62")
  assert.strictEqual(usb.priority, 2)
  assert.strictEqual(usb.fresh, 0)
  assert.strictEqual(problems[1].fresh, 1)
  assert.strictEqual(M.problemMeta(usb, NOW), "×2 · critical · 1m ago")
})

test("parseFailed reads systemctl's JSON for either scope", () => {
  const failed = M.parseFailed('[{"unit":"run-p1.service","load":"loaded","active":"failed","sub":"failed","description":"[systemd-run] /usr/bin/timeout 4 monitor-sensor"}]', "user")
  assert.deepStrictEqual(failed, [{ key: "failed:user:run-p1.service", scope: "user", unit: "run-p1.service", description: "[systemd-run] /usr/bin/timeout 4 monitor-sensor", sub: "failed" }])
  assert.deepStrictEqual(M.parseFailed("", "system"), [])
  assert.deepStrictEqual(M.parseFailed("No failed units.", "system"), [])
})

test("state round-trips and rejects junk; windows cycle", () => {
  const s = M.parseState(M.serializeState({ seenMs: 7, muted: ["a", "a", ""], window: "day", seenFailed: ["failed:user:x.service"] }))
  assert.deepStrictEqual(s, { seenMs: 7, muted: ["a"], window: "day", seenFailed: ["failed:user:x.service"] })
  assert.deepStrictEqual(M.parseState("{\"window\":\"never\"}"), { seenMs: 0, muted: [], window: "boot", seenFailed: [] })
  assert.deepStrictEqual(["boot", "day", "week", "x"].map(M.nextWindow), ["day", "week", "boot", "boot"])
})

test("rows: failed first, problems under unit headers, muted last; summary and bar", () => {
  const failed = M.parseFailed('[{"unit":"x.service","description":"X","sub":"failed"}]', "system")
  failed[0].fresh = true
  const split = M.splitMuted(problems, [problems[1].key])
  const rows = M.buildRows(failed, split.shown, split.hidden)
  assert.deepStrictEqual(rows.map((r) => r.type === "header" ? "H:" + r.text : r.type),
    ["H:FAILED · 1", "failed", "H:TABLET-AUTOROTATE.SERVICE (USER)", "problem", "H:WEIRD", "problem", "H:KERNEL", "problem", "H:MUTED · 1", "problem"])
  assert.strictEqual(M.cursorRows(rows).length, 5)
  assert.strictEqual(rows[9].muted, true)
  const c = M.counts(failed, split.shown, NOW - 50000)
  assert.deepStrictEqual(c, { failed: 1, problems: 3, lines: 4, fresh: 2 })
  assert.strictEqual(M.summaryText(c, "boot", 1), "1 failed unit · 3 problems (4 lines) · this boot · 1 muted")
  assert.strictEqual(M.summaryText({ failed: 0, problems: 0, lines: 0, fresh: 0 }, "week", 0), "Nothing wrong in 7 days")
  assert.strictEqual(M.barLabel(c, false), M.GLYPHS.fault + " 2")
  assert.strictEqual(M.barLabel(c, true), M.GLYPHS.fault)
})

test("handoff: the log command fits the scope, and the prompt carries the report", () => {
  assert.deepStrictEqual(M.logCommand(problems[0], "boot"), ["journalctl", "--no-pager", "-b", "--user-unit=tablet-autorotate.service", "-p", "3"])
  assert.deepStrictEqual(M.logCommand(problems[3], "day"), ["journalctl", "--no-pager", "--since=-24h", "-k", "-p", "3"])
  const failed = M.parseFailed('[{"unit":"x.service","description":"X"}]', "system")[0]
  assert.deepStrictEqual(M.logCommand(failed, "boot"), ["journalctl", "--no-pager", "-b", "-u", "x.service"])
  const prompt = M.diagnosisPrompt(problems[3], NOW, "boot")
  assert.ok(prompt.indexOf("Message:  usb 2-2: device not accepting address 7, error -62") !== -1)
  assert.ok(prompt.indexOf("journalctl --no-pager -b -k -p 3") !== -1)
  assert.ok(M.reportText(failed, NOW, "boot").indexOf("Failed unit: x.service (system)") === 0)
})

console.log("\n" + passed + " tests passed")
