#!/usr/bin/env bash
# Prepares a dev pod, then idles so people (and herdr panes) can attach with
# `hl attach <project>`, which runs `claude --continue` in the project's checkout.
#
# Environment (set by templates/agent):
#   REPO_URL        ssh URL of the project's Forgejo repo (optional; no clone without it)
#   REPO_DIR        checkout directory, e.g. /workspace/<repo>; also Claude's working directory
#   GIT_USER_NAME, GIT_USER_EMAIL   commit identity for the agent
#   DESKTOP_BROWSER_CDP   the project's browser desktop's CDP endpoint, if it has one
#                         (templates/agent/components/desktop-browser)
# Files:
#   /etc/git-deploy-key/ssh-privatekey   the repo's read-write deploy key (Secret), if any
set -euo pipefail

log() { printf '[agent-entrypoint] %s\n' "$*"; }

# Seed Claude Code's user settings once: skip permission prompts inside this pod (the pod is the
# sandbox). Existing settings on the volume are never overwritten.
mkdir -p "$CLAUDE_CONFIG_DIR"
if [[ ! -f $CLAUDE_CONFIG_DIR/settings.json ]]; then
  cp /etc/homelab/claude-settings.json "$CLAUDE_CONFIG_DIR/settings.json"
  log "seeded $CLAUDE_CONFIG_DIR/settings.json"
fi

# The browser and desktop MCP servers, "playwright" and "cua-driver" (the same names as on the PC),
# in images that have them. They live in ~/.claude.json on the volume; claude-mcp-setup also
# removes the "desktop" server (desktop-mcp) that older images registered. A project with a
# browser desktop also gets "desktop-browser" and the submission guard for it.
if [[ -x /usr/local/bin/claude-mcp-setup ]]; then
  mcp_setup_args=()
  if [[ -n ${DESKTOP_BROWSER_CDP:-} ]]; then
    mcp_setup_args+=(--desktop-browser "$DESKTOP_BROWSER_CDP")
  fi
  claude-mcp-setup "${mcp_setup_args[@]}" && log "registered the MCP servers (desktop browser: ${DESKTOP_BROWSER_CDP:-none})"
fi

git config --global user.name "${GIT_USER_NAME:-homelab agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@homelab.lan}"
git config --global init.defaultBranch main

# SSH to Forgejo with the deploy key. The host key is learned on first use and kept on the volume.
if [[ -s /etc/git-deploy-key/ssh-privatekey ]]; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  install -m 600 /etc/git-deploy-key/ssh-privatekey ~/.ssh/deploy-key
  git config --global core.sshCommand \
    "ssh -i ~/.ssh/deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi

if [[ -n ${REPO_URL:-} && -n ${REPO_DIR:-} && ! -d $REPO_DIR/.git ]]; then
  log "cloning $REPO_URL into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR" || log "clone failed; the pod stays up so you can fix it"
fi

log "ready; attach with: hl attach <project>"
exec sleep infinity
