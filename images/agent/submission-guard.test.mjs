// Tests for submission-guard.mjs. Run: node --test images/agent/submission-guard.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { collectPids, consumeApproval, decide, findElementByRef, findFocusedElement, grantApproval, guardConfig, readTranscriptSnapshots } from "./submission-guard.mjs";

const GUARD = path.join(path.dirname(fileURLToPath(import.meta.url)), "submission-guard.mjs");

const FORM_SNAPSHOT = `- generic [ref=e1]:
  - heading "Apply for Engineer" [level=1] [ref=e2]
  - iframe [active] [ref=e3]:
    - generic [ref=f1e1]:
      - textbox "Full name" [active] [ref=f1e2]: Sam
      - searchbox "Search jobs" [ref=f1e3]
      - button "Upload CV" [ref=f1e4]
      - button "Submit application" [ref=f1e5]
      - link "Apply now" [ref=f1e6] [cursor=pointer]`;

function tempConfig() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "guard-test-"));
	return { ...guardConfig({ HOME: dir }), stateDir: path.join(dir, "state"), snapshotDir: path.join(dir, "output"), dir };
}

const snapshots = [{ time: 2, text: FORM_SNAPSHOT }];

test("a click on an ordinary button is allowed", () => {
	assert.deepEqual(decide("mcp__playwright__browser_click", { target: "f1e4", element: "Upload CV" }, { snapshots }), { allow: true });
});

test("a click on a submit-like button needs approval, judged by the snapshot's name, not the model's description", () => {
	const decision = decide("mcp__playwright__browser_click", { target: "f1e5", element: "the blue button" }, { snapshots });
	assert.match(decision.approvalNeeded, /button "Submit application"/);
});

test("a click on a link named Apply needs approval", () => {
	assert.ok(decide("mcp__playwright__browser_click", { target: "f1e6" }, { snapshots }).approvalNeeded);
});

test("a click on a ref the guard can't find is refused with a way forward", () => {
	assert.match(decide("mcp__playwright__browser_click", { target: "e99" }, { snapshots }).refuse, /Run browser_snapshot/);
});

test("Enter in a search box is allowed, Enter in another field needs approval", () => {
	const inSearch = [{ time: 3, text: FORM_SNAPSHOT.replace('textbox "Full name" [active]', 'textbox "Full name"').replace('searchbox "Search jobs"', 'searchbox "Search jobs" [active]') }];
	assert.deepEqual(decide("mcp__playwright__browser_press_key", { key: "Enter" }, { snapshots: inSearch }), { allow: true });
	assert.match(decide("mcp__playwright__browser_press_key", { key: "Enter" }, { snapshots }).approvalNeeded, /textbox "Full name"/);
	assert.deepEqual(decide("mcp__playwright__browser_press_key", { key: "Tab" }, { snapshots }), { allow: true });
});

test("typing with submit needs approval unless the field is a search box", () => {
	assert.ok(decide("mcp__playwright__browser_type", { target: "f1e2", text: "Sam", submit: true }, { snapshots }).approvalNeeded);
	assert.deepEqual(decide("mcp__playwright__browser_type", { target: "f1e3", text: "rust", submit: true }, { snapshots }), { allow: true });
	assert.deepEqual(decide("mcp__playwright__browser_type", { target: "f1e2", text: "Sam" }, { snapshots }), { allow: true });
});

test("coordinate mouse input needs approval", () => {
	assert.ok(decide("mcp__playwright__browser_mouse_click_xy", { x: 1, y: 2 }, { snapshots }).approvalNeeded);
});

test("the newest snapshot wins when a ref appears in several", () => {
	const older = { time: 1, text: '- button "Next" [ref=e7]' };
	const newer = { time: 5, text: '- button "Submit" [ref=e7]' };
	assert.equal(findElementByRef([older, newer], "e7").name, "Submit");
	assert.equal(findFocusedElement(snapshots).name, "Full name");
});

test("cua-driver: browser tools and run_script are refused, actions on the browser process too", () => {
	const nameOfProcess = (pid) => (pid === 42 ? "chromium-browse" : "blender");
	assert.ok(decide("mcp__cua-driver__browser_click", {}, { nameOfProcess }).refuse);
	assert.ok(decide("mcp__cua-driver__run_script", { script: "" }, { nameOfProcess }).refuse);
	assert.ok(decide("mcp__cua-driver__click", { pid: 42, element_token: "s1:3" }, { nameOfProcess }).refuse);
	assert.ok(decide("mcp__cua-driver__run_steps", { steps: [{ tool: "click", args: { pid: 42 } }] }, { nameOfProcess }).refuse);
	assert.deepEqual(decide("mcp__cua-driver__click", { pid: 7, element_token: "s1:3" }, { nameOfProcess }), { allow: true });
	assert.deepEqual(collectPids({ steps: [{ args: { pid: 1 } }, { args: { pid: 2 } }] }), [1, 2]);
});

test("an approval is used once and expires after 10 minutes", () => {
	const config = tempConfig();
	grantApproval(config, { company: "Acme", role: "Engineer", summary: "CV v3" }, 1_000);
	assert.equal(consumeApproval(config, 2_000).company, "Acme");
	assert.equal(consumeApproval(config, 2_000), undefined);
	grantApproval(config, { company: "Acme", role: "Engineer", summary: "" }, 0);
	assert.equal(consumeApproval(config, 11 * 60_000), undefined);
});

// A transcript with one tool call and its result, as Claude Code writes them (one JSON per line).
function transcriptLines(id, toolName, snapshotYaml, timestamp) {
	const call = { timestamp, message: { role: "assistant", content: [{ type: "tool_use", id, name: toolName, input: {} }] } };
	const result = {
		timestamp,
		message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: [{ type: "text", text: "### Snapshot\n```yaml\n" + snapshotYaml + "\n```" }] }] },
	};
	return `${JSON.stringify(call)}\n${JSON.stringify(result)}\n`;
}

test("inline snapshots are read from the transcript's tool results", () => {
	const config = tempConfig();
	const transcript = path.join(config.dir, "t.jsonl");
	fs.writeFileSync(transcript, "not json\n" + transcriptLines("t1", "mcp__playwright__browser_snapshot", '- button "Send" [ref=e4]', "2026-11-18T00:00:00Z"));
	assert.equal(findElementByRef(readTranscriptSnapshots(transcript, config.playwrightPrefix), "e4").name, "Send");
});

// Dev pods with a browser desktop guard a second Playwright server ("desktop-browser", attached to
// the signed-in Chromium) and leave their headless "playwright" unguarded.
test("the guarded Playwright server is configurable; the other one is left alone", () => {
	const config = guardConfig({ HOME: os.tmpdir(), SUBMIT_GUARD_PLAYWRIGHT_SERVER: "desktop-browser" });
	const submit = { target: "f1e5", element: "Submit application" };
	assert.match(decide("mcp__desktop-browser__browser_click", submit, { snapshots, config }).approvalNeeded, /Submit application/);
	assert.deepEqual(decide("mcp__playwright__browser_click", submit, { snapshots, config }), { allow: true });
});

test("transcript snapshots come only from the guarded server's tool results", () => {
	const config = tempConfig();
	const transcript = path.join(config.dir, "t.jsonl");
	// The headless browser's newer page reuses ref e4 for a harmless button.
	fs.writeFileSync(
		transcript,
		transcriptLines("d1", "mcp__desktop-browser__browser_snapshot", '- button "Place order" [ref=e4]', "2026-11-18T00:00:00Z") +
			transcriptLines("h1", "mcp__playwright__browser_snapshot", '- button "Next" [ref=e4]', "2026-11-18T00:05:00Z"),
	);
	const guarded = readTranscriptSnapshots(transcript, "mcp__desktop-browser__");
	assert.equal(findElementByRef(guarded, "e4").name, "Place order");
});

// End to end, as Claude Code runs them: the hook refuses, approve_submission over MCP, the hook
// lets exactly one action through.
test("hook and approval server work together over their real interfaces", () => {
	const config = tempConfig();
	fs.mkdirSync(config.snapshotDir, { recursive: true });
	fs.writeFileSync(path.join(config.snapshotDir, "page-1.yml"), FORM_SNAPSHOT);
	const env = { ...process.env, HOME: config.dir, SUBMIT_GUARD_STATE_DIR: config.stateDir, PLAYWRIGHT_MCP_OUTPUT_DIR: config.snapshotDir };
	const event = JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "mcp__playwright__browser_click", tool_input: { target: "f1e5", element: "Submit" } });
	const runHook = () => spawnSync(process.execPath, [GUARD, "hook"], { input: event, env, encoding: "utf8" });

	const refused = runHook();
	assert.equal(refused.status, 0);
	assert.equal(JSON.parse(refused.stdout).hookSpecificOutput.permissionDecision, "deny");
	assert.match(refused.stdout, /approve_submission/);

	const requests = [
		{ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
		{ jsonrpc: "2.0", method: "notifications/initialized" },
		{ jsonrpc: "2.0", id: 2, method: "tools/list" },
		{ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "approve_submission", arguments: { company: "Acme", role: "Engineer", summary: "CV v3" } } },
	];
	const server = spawnSync(process.execPath, [GUARD, "mcp"], { input: requests.map((r) => JSON.stringify(r)).join("\n") + "\n", env, encoding: "utf8" });
	const replies = server.stdout.trim().split("\n").map((line) => JSON.parse(line));
	assert.deepEqual(replies.map((reply) => reply.id), [1, 2, 3]);
	assert.equal(replies[1].result.tools[0].name, "approve_submission");
	assert.match(replies[2].result.content[0].text, /Approved: Engineer at Acme/);

	assert.equal(runHook().stdout, "", "the approved action goes ahead");
	assert.equal(JSON.parse(runHook().stdout).hookSpecificOutput.permissionDecision, "deny", "and only once");
});

test("the hook fails closed on bad input", () => {
	const result = spawnSync(process.execPath, [GUARD, "hook"], { input: "not json", encoding: "utf8" });
	assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, "deny");
});
