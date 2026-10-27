#!/usr/bin/env node
// Submission guard for pods where a person must approve before anything is submitted (a job
// application, an order, a message). It replaces desktop-mcp's DESKTOP_MCP_SUBMIT_GUARD, now that
// browsers are driven by Playwright MCP ("playwright") and native apps by cua-driver.
//
//   submission-guard hook   Claude Code PreToolUse hook (managed settings, matcher
//                           "mcp__playwright__.*|mcp__cua-driver__.*"). It refuses, until approved:
//                             - clicking a control whose accessible name looks like Submit, Apply,
//                               Send... (read from Playwright's latest snapshot, not from the
//                               model's description of it);
//                             - Enter (browser_press_key, or browser_type with submit) unless the
//                               focused field is a search box;
//                             - coordinate mouse input on the page, whose target can't be checked.
//                           In cua-driver it refuses its browser tools and run_script, and any action
//                           aimed at the Chromium process: web pages go through Playwright.
//   submission-guard mcp    stdio MCP server "submission-guard" with one tool, approve_submission,
//                           which grants ONE guarded action for 10 minutes. Managed settings make it
//                           an "ask" rule, so the person approves every call, even in bypass mode.
//
// Like the guard it replaces, this catches mistakes; it is not a sandbox: an agent with a shell in
// the same pod could reach the browser another way.
//
// Environment:
//   SUBMIT_GUARD_PATTERN         case-insensitive pattern for submit-like names (default below)
//   SUBMIT_GUARD_PLAYWRIGHT_SERVER  the Playwright MCP server to guard (default "playwright"). Dev
//                                pods with a browser desktop guard "desktop-browser", the server
//                                attached to the signed-in Chromium, and leave their headless
//                                "playwright" alone (templates/agent/components/desktop-browser).
//   SUBMIT_GUARD_STATE_DIR       where the approval is kept (default ~/.local/state/submission-guard)
//   PLAYWRIGHT_MCP_OUTPUT_DIR    Playwright MCP's --output-dir, where it writes page snapshots
//                                (default ~/.cache/playwright-mcp/output, as the playwright-mcp launcher)

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

export const DEFAULT_PATTERN = "\\b(submit|apply|send|finish|finalise|finalize|confirm|complete|place order|pay)\\b";
export const APPROVAL_TTL_MS = 10 * 60_000;
// The transcript can be hundreds of megabytes; the latest snapshots are always near its end.
const TRANSCRIPT_TAIL_BYTES = 4 * 1024 * 1024;
const NEWEST_SNAPSHOT_FILES = 20;

const CUA_PREFIX = "mcp__cua-driver__";
const COORDINATE_TOOLS = new Set(["browser_mouse_click_xy", "browser_mouse_down", "browser_mouse_up", "browser_mouse_drag_xy"]);
const ENTER_KEYS = new Set(["enter", "return", "numpadenter"]);
const BROWSER_PROCESS = /chrom(e|ium)/i;

export function guardConfig(env = process.env) {
	const home = env.HOME || os.homedir();
	return {
		pattern: new RegExp(env.SUBMIT_GUARD_PATTERN || DEFAULT_PATTERN, "i"),
		playwrightPrefix: `mcp__${env.SUBMIT_GUARD_PLAYWRIGHT_SERVER || "playwright"}__`,
		stateDir: env.SUBMIT_GUARD_STATE_DIR || path.join(home, ".local", "state", "submission-guard"),
		snapshotDir: env.PLAYWRIGHT_MCP_OUTPUT_DIR || path.join(home, ".cache", "playwright-mcp", "output"),
	};
}

// ---------------------------------------------------------------------------------------------
// Approvals: one at a time, in a file shared by the MCP server (grants) and the hook (consumes).

function approvalFile(config) {
	return path.join(config.stateDir, "approval.json");
}

export function grantApproval(config, details, now = Date.now()) {
	fs.mkdirSync(config.stateDir, { recursive: true });
	const approval = { company: details.company, role: details.role, summary: details.summary, grantedAt: now };
	const temporary = `${approvalFile(config)}.${process.pid}.tmp`;
	fs.writeFileSync(temporary, JSON.stringify(approval));
	fs.renameSync(temporary, approvalFile(config));
	return approval;
}

/** Takes the pending approval if there is one and it hasn't expired; it can be used only once. */
export function consumeApproval(config, now = Date.now()) {
	let approval;
	try {
		approval = JSON.parse(fs.readFileSync(approvalFile(config), "utf8"));
		fs.unlinkSync(approvalFile(config));
	} catch {
		return undefined;
	}
	if (!Number.isFinite(approval?.grantedAt) || now - approval.grantedAt > APPROVAL_TTL_MS) return undefined;
	return approval;
}

// ---------------------------------------------------------------------------------------------
// Snapshots: Playwright MCP's accessibility snapshots, newest first. They come from two places:
// inline in tool results (browser_snapshot), and as page-*.yml files in its output directory
// (written after navigations and actions). Each is { time, text }.

export function readSnapshotFiles(snapshotDir) {
	let names;
	try {
		names = fs.readdirSync(snapshotDir).filter((name) => /^page-.*\.yml$/.test(name));
	} catch {
		return [];
	}
	// The directory keeps every snapshot of the session; only the newest few can matter.
	return names
		.map((name) => {
			const file = path.join(snapshotDir, name);
			return { file, time: fs.statSync(file).mtimeMs };
		})
		.sort((a, b) => b.time - a.time)
		.slice(0, NEWEST_SNAPSHOT_FILES)
		.map(({ file, time }) => ({ time, text: fs.readFileSync(file, "utf8") }));
}

function readFileTail(file, maxBytes) {
	const handle = fs.openSync(file, "r");
	try {
		const size = fs.fstatSync(handle).size;
		const start = Math.max(0, size - maxBytes);
		const buffer = Buffer.alloc(size - start);
		fs.readSync(handle, buffer, 0, buffer.length, start);
		const text = buffer.toString("utf8");
		// Drop the first, probably partial, line when we didn't start at the beginning.
		return start > 0 ? text.slice(text.indexOf("\n") + 1) : text;
	} finally {
		fs.closeSync(handle);
	}
}

function toolResultText(block) {
	if (typeof block.content === "string") return block.content;
	if (Array.isArray(block.content)) return block.content.map((part) => part?.text ?? "").join("\n");
	return "";
}

/**
 * Inline snapshots (```yaml blocks) in the transcript's recent tool results, from the guarded
 * server's tools only (toolPrefix, e.g. "mcp__playwright__"): another browser's snapshots reuse
 * the same refs (e1, e2, ...) for different elements.
 */
export function readTranscriptSnapshots(transcriptPath, toolPrefix) {
	if (!transcriptPath || !fs.existsSync(transcriptPath)) return [];
	const guardedCallIds = new Set();
	const snapshots = [];
	for (const line of readFileTail(transcriptPath, TRANSCRIPT_TAIL_BYTES).split("\n")) {
		const mayHoldGuardedCall = line.includes('"tool_use"') && line.includes(toolPrefix);
		if (!mayHoldGuardedCall && !line.includes("[ref=")) continue;
		let entry;
		try {
			entry = JSON.parse(line);
		} catch {
			continue;
		}
		const time = Date.parse(entry.timestamp ?? "") || 0;
		for (const block of Array.isArray(entry.message?.content) ? entry.message.content : []) {
			// A call is written before its result, so its id is known when the result is read.
			if (block?.type === "tool_use" && String(block.name ?? "").startsWith(toolPrefix)) guardedCallIds.add(block.id);
			if (block?.type !== "tool_result" || !guardedCallIds.has(block.tool_use_id)) continue;
			const yaml = toolResultText(block).match(/```yaml\n([\s\S]*?)```/);
			if (yaml) snapshots.push({ time, text: yaml[1] });
		}
	}
	return snapshots;
}

function newestFirst(snapshots) {
	return [...snapshots].sort((a, b) => b.time - a.time);
}

/** Parses a snapshot line such as `- button "Submit application" [ref=f1e3]`. */
export function parseSnapshotLine(line) {
	const match = line.match(/^\s*-\s+([a-z]+)(?:\s+"((?:[^"\\]|\\.)*)")?/);
	return match ? { role: match[1], name: match[2] ?? "", line: line.trim() } : undefined;
}

/** The element a ref points at, from the newest snapshot that contains it. */
export function findElementByRef(snapshots, ref) {
	const marker = `[ref=${ref}]`;
	for (const snapshot of newestFirst(snapshots)) {
		const line = snapshot.text.split("\n").find((candidate) => candidate.includes(marker));
		if (line) return parseSnapshotLine(line);
	}
	return undefined;
}

/** The focused element in the newest snapshot: the innermost line marked [active]. */
export function findFocusedElement(snapshots) {
	const newest = newestFirst(snapshots)[0];
	if (!newest) return undefined;
	const activeLines = newest.text.split("\n").filter((line) => line.includes("[active]"));
	return activeLines.length > 0 ? parseSnapshotLine(activeLines[activeLines.length - 1]) : undefined;
}

function isSearchField(element) {
	if (!element) return false;
	if (element.role === "searchbox") return true;
	return ["textbox", "combobox"].includes(element.role) && /search|filter|find/i.test(element.name);
}

// ---------------------------------------------------------------------------------------------
// Decisions. Each returns { allow: true } or { approvalNeeded: reason } or { refuse: reason }.

function decidePlaywright(tool, input, snapshots, config) {
	if (COORDINATE_TOOLS.has(tool)) return { approvalNeeded: "a coordinate mouse action on the page can't be checked" };

	if (tool === "browser_click") {
		const element = findElementByRef(snapshots, input.target ?? input.ref);
		if (!element) {
			return { refuse: `the guard can't find ref ${input.target ?? input.ref} in Playwright's latest snapshot. Run browser_snapshot, then retry with a ref from it` };
		}
		if (config.pattern.test(element.name)) return { approvalNeeded: `clicking ${element.role} "${element.name}" looks like a submission` };
		return { allow: true };
	}

	const pressesEnter =
		(tool === "browser_press_key" && String(input.key ?? "").split("+").some((part) => ENTER_KEYS.has(part.trim().toLowerCase()))) ||
		(tool === "browser_type" && (input.submit === true || /[\r\n]/.test(String(input.text ?? ""))));
	if (pressesEnter) {
		const field = tool === "browser_type" ? findElementByRef(snapshots, input.target ?? input.ref) : findFocusedElement(snapshots);
		if (isSearchField(field)) return { allow: true };
		const where = field ? `${field.role} "${field.name}"` : "a field the guard can't identify";
		return { approvalNeeded: `Enter in ${where} can submit a form` };
	}
	return { allow: true };
}

/** Every `pid` in a tool input, including those of run_steps' steps. */
export function collectPids(value, pids = []) {
	if (Array.isArray(value)) value.forEach((item) => collectPids(item, pids));
	else if (value && typeof value === "object") {
		for (const [key, item] of Object.entries(value)) {
			if (key === "pid" && Number.isInteger(item)) pids.push(item);
			else collectPids(item, pids);
		}
	}
	return pids;
}

export function processName(pid) {
	try {
		return fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim();
	} catch {
		return "";
	}
}

function decideCuaDriver(tool, input, nameOfProcess) {
	if (tool.startsWith("browser_") || tool === "page") {
		return { refuse: `cua-driver's ${tool} is off in this pod: use the playwright tools for web pages` };
	}
	if (tool === "run_script") return { refuse: "run_script is off in this pod: the guard can't check what a script does. Use run_steps or single actions" };
	const browserPid = collectPids(input).find((pid) => BROWSER_PROCESS.test(nameOfProcess(pid)));
	if (browserPid !== undefined) {
		return { refuse: `pid ${browserPid} is the browser: use the playwright tools for web pages, so the submission guard can check them` };
	}
	return { allow: true };
}

export function decide(toolName, toolInput, { snapshots = [], config = guardConfig(), nameOfProcess = processName } = {}) {
	const input = toolInput ?? {};
	if (toolName.startsWith(config.playwrightPrefix)) return decidePlaywright(toolName.slice(config.playwrightPrefix.length), input, snapshots, config);
	if (toolName.startsWith(CUA_PREFIX)) return decideCuaDriver(toolName.slice(CUA_PREFIX.length), input, nameOfProcess);
	return { allow: true };
}

// ---------------------------------------------------------------------------------------------
// The hook: reads the PreToolUse event, decides, and prints a deny decision when it refuses.

function denyOutput(reason) {
	return JSON.stringify({
		hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: `Submission guard: ${reason}` },
	});
}

export function runHook(event, config = guardConfig()) {
	const toolName = String(event.tool_name ?? "");
	const needsSnapshots = toolName.startsWith(config.playwrightPrefix);
	const snapshots = needsSnapshots
		? [...readSnapshotFiles(config.snapshotDir), ...readTranscriptSnapshots(event.transcript_path, config.playwrightPrefix)]
		: [];
	const decision = decide(toolName, event.tool_input, { snapshots, config });
	if (decision.allow) return "";
	if (decision.refuse) return denyOutput(decision.refuse);
	if (consumeApproval(config)) return ""; // approved: this one action goes ahead
	return denyOutput(
		`${decision.approvalNeeded}. Ask the user first, then call approve_submission (company, role, summary); ` +
			"one approval allows one such action for 10 minutes. Don't work around the guard.",
	);
}

// ---------------------------------------------------------------------------------------------
// The approval MCP server: newline-delimited JSON-RPC on stdio, one tool.

const APPROVE_TOOL = {
	name: "approve_submission",
	description:
		"Ask the user to approve ONE submission (a submit-like click or Enter in a form) that the submission guard refused. " +
		"The user is prompted for every call. Once approved, repeat the refused action once, within 10 minutes.",
	inputSchema: {
		type: "object",
		properties: {
			company: { type: "string", description: "Who it goes to (company, shop, recipient)" },
			role: { type: "string", description: "What it is (the role applied for, the order, the message)" },
			summary: { type: "string", description: "What will be sent: documents, notable answers, totals" },
		},
		required: ["company", "role", "summary"],
	},
};

export function handleMcpRequest(request, config = guardConfig()) {
	switch (request.method) {
		case "initialize":
			return {
				protocolVersion: request.params?.protocolVersion ?? "2025-06-18",
				capabilities: { tools: {} },
				serverInfo: { name: "submission-guard", version: "1.0.0" },
			};
		case "ping":
			return {};
		case "tools/list":
			return { tools: [APPROVE_TOOL] };
		case "tools/call": {
			if (request.params?.name !== APPROVE_TOOL.name) {
				return { isError: true, content: [{ type: "text", text: `Unknown tool ${request.params?.name}` }] };
			}
			const args = request.params.arguments ?? {};
			const approval = grantApproval(config, { company: String(args.company ?? ""), role: String(args.role ?? ""), summary: String(args.summary ?? "") });
			return {
				content: [
					{
						type: "text",
						text: `Approved: ${approval.role} at ${approval.company}. Repeat the refused action once, within 10 minutes.`,
					},
				],
			};
		}
		default:
			throw Object.assign(new Error(`Method not found: ${request.method}`), { code: -32601 });
	}
}

function runMcpServer(config) {
	const lines = readline.createInterface({ input: process.stdin });
	lines.on("line", (line) => {
		if (!line.trim()) return;
		let request;
		try {
			request = JSON.parse(line);
		} catch {
			return;
		}
		if (request.id === undefined) return; // a notification: nothing to answer
		let reply;
		try {
			reply = { jsonrpc: "2.0", id: request.id, result: handleMcpRequest(request, config) };
		} catch (error) {
			reply = { jsonrpc: "2.0", id: request.id, error: { code: error.code ?? -32603, message: error.message } };
		}
		process.stdout.write(`${JSON.stringify(reply)}\n`);
	});
}

// ---------------------------------------------------------------------------------------------

async function readStdin() {
	let text = "";
	for await (const chunk of process.stdin) text += chunk;
	return text;
}

async function main(mode) {
	const config = guardConfig();
	if (mode === "mcp") return runMcpServer(config);
	if (mode !== "hook") {
		console.error("usage: submission-guard hook|mcp");
		process.exit(2);
	}
	try {
		const output = runHook(JSON.parse(await readStdin()), config);
		if (output) process.stdout.write(`${output}\n`);
	} catch (error) {
		// Fail closed: a guard that crashes must not let the action through.
		process.stdout.write(`${denyOutput(`the guard failed (${error.message}); the action was not run`)}\n`);
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
	await main(process.argv[2]);
}
