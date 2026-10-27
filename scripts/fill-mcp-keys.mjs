#!/usr/bin/env node
// Copies the shared MCP servers' API keys from this PC's keyring (keyring-secrets, Windows
// Credential Manager) into templates/claude-shared/base/claude-mcp-keys.sops.yaml. Each value
// goes straight from the keyring into `sops set` on stdin: it is never printed, written to a
// plain file or passed on a command line.
//
//   node scripts/fill-mcp-keys.mjs            fill every key in KEYS
//   node scripts/fill-mcp-keys.mjs exa github fill only these
//
// Then commit the file, push and reconcile; pods see a changed key within about a minute,
// without a restart. A new key: add it to KEYS here and to the Secret's stringData.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Secret key → keyring alias on this PC (see ~/.claude/tools/register-mcp.mjs).
const KEYS = {
  context7: "context7",
  exa: "exa1",
  github: "github",
  huggingface: "huggingface",
  consensus: "consensus",
  firecrawl: "firecrawl1",
  apify: "apify",
  adzuna: "adzuna",
  jooble: "jooble",
  arena: "arena",
  fal: "fal", // "<key_id>:<key_secret>", a key made for the pods (fal charges per generation)
};
const KEYRING_LIB = join(process.env.USERPROFILE ?? "", ".claude/tools/keyring-secrets/lib.mjs");
const SECRET_FILE = join(dirname(fileURLToPath(import.meta.url)), "../templates/claude-shared/base/claude-mcp-keys.sops.yaml");

// keyring-secrets' own modules: its config and lookup, and the native keyring binding it uses.
const { loadConfig, loadSecrets } = await import(pathToFileURL(KEYRING_LIB).href);
const { findCredentialsAsync } = createRequire(KEYRING_LIB)("@napi-rs/keyring");

const wanted = process.argv.slice(2);
for (const name of wanted) {
  if (!(name in KEYS)) {
    console.error(`unknown key '${name}'; known: ${Object.keys(KEYS).join(", ")}`);
    process.exit(2);
  }
}
const names = wanted.length > 0 ? wanted : Object.keys(KEYS);

const config = loadConfig();
let failed = 0;
for (const name of names) {
  let value;
  try {
    value = (await loadSecrets(config, [KEYS[name]], findCredentialsAsync)).get(KEYS[name]);
  } catch (error) {
    console.log(`${name}: not in the keyring (${error.message}); left as it was`);
    failed++;
    continue;
  }
  const result = spawnSync("sops", ["set", "--value-stdin", SECRET_FILE, `["stringData"]["${name}"]`], {
    input: JSON.stringify(value),
    stdio: ["pipe", "ignore", "pipe"],
    encoding: "utf8",
  });
  if (result.status === 0) {
    console.log(`${name}: filled`);
  } else {
    // sops's message names the file and the key, never the value.
    console.log(`${name}: sops failed: ${result.stderr.trim().split("\n").pop()}`);
    failed++;
  }
}
process.exit(failed > 0 ? 1 : 0);
