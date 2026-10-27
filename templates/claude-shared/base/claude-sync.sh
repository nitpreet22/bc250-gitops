#!/usr/bin/env bash
# claude-sync: keeps this pod's Claude Code setup in step with nitpreet22/claude-shared (main):
# the shared MCP servers (plugin "homelab"), mods and skills. Runs as a sidecar next to Claude
# Code, with the pod's home volume at /claude-home (templates/claude-shared).
#
# Every SYNC_INTERVAL seconds it pulls main. When the commit changed, it copies each
# plugins/<name>/ and skills/<name>/ into ~/.claude/skills/<name>/, where Claude Code loads
# plugins and skills in place; new sessions get the change, a running one with /reload-plugins.
# The repo's CLAUDE.md becomes ~/.claude/CLAUDE.md (new sessions read it).
# Copies carry a marker file, so a folder the pod made itself is never replaced or removed.
#
# Files:
#   /etc/claude-shared-key/ssh-privatekey   read-write deploy key for claude-shared (Forgejo lets
#                                           it push proposal branches, not main)
set -uo pipefail

readonly CONFIG_DIR=/claude-home/.claude
readonly CLONE=$CONFIG_DIR/claude-shared          # a clone of main, reset on every pull
readonly SKILLS=$CONFIG_DIR/skills
readonly APPLIED=$CONFIG_DIR/claude-shared.applied # the commit last copied into skills/
readonly MARKER=.from-claude-shared
readonly CLAUDE_MD_MARKER="<!-- Synced by claude-sync"
readonly REPO_URL=ssh://git@forgejo-ssh.forgejo.svc:22/nitpreet22/claude-shared.git
readonly INTERVAL=${SYNC_INTERVAL:-300}

log() { printf '[claude-sync] %s\n' "$*"; }

# ssh refuses a key file other users can read, so use a private copy.
install -m 600 /etc/claude-shared-key/ssh-privatekey "$HOME/claude-shared-key"
export GIT_SSH_COMMAND="ssh -i $HOME/claude-shared-key -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$CONFIG_DIR/claude-shared.known_hosts"

pull() {
  if [[ -d $CLONE/.git ]]; then
    git -C "$CLONE" fetch --quiet origin main && git -C "$CLONE" reset --quiet --hard origin/main
  else
    rm -rf "$CLONE"
    git clone --quiet --branch main "$REPO_URL" "$CLONE"
  fi
}

# Installs the Node.js dependencies of every package-lock.json in a copied folder (the homelab
# plugin's jobs and arena servers).
install_dependencies() {
  local folder=$1 lockfile
  while IFS= read -r lockfile; do
    (cd "$(dirname "$lockfile")" &&
      npm ci --omit=dev --no-audit --no-fund --loglevel=error --cache "$HOME/npm-cache") || return 1
  done < <(find "$folder" -name package-lock.json -not -path '*/node_modules/*')
}

# Copies one folder from the clone into skills/, replacing the earlier copy only once the new
# one is complete.
install_entry() {
  local source=$1 name dest staging
  name=$(basename "$source")
  dest=$SKILLS/$name
  staging=$SKILLS/.staging-$name
  if [[ -e $dest && ! -e $dest/$MARKER ]]; then
    log "skipping $name: this pod has its own $dest"
    return 0
  fi
  rm -rf "$staging"
  cp -r "$source" "$staging"
  touch "$staging/$MARKER"
  if ! install_dependencies "$staging"; then
    log "npm ci failed for $name; keeping the previous copy"
    rm -rf "$staging"
    return 1
  fi
  rm -rf "$dest"
  mv "$staging" "$dest"
}

# Removes copies whose folder is gone from the repo.
remove_stale_entries() {
  local dest name
  for dest in "$SKILLS"/*/; do
    [[ -e $dest$MARKER ]] || continue
    name=$(basename "$dest")
    if [[ ! -d $CLONE/plugins/$name && ! -d $CLONE/skills/$name ]]; then
      rm -rf "$dest"
      log "removed $name (no longer in claude-shared)"
    fi
  done
}

# Installs the repo's CLAUDE.md as the pod's user CLAUDE.md (my working style, adapted for pods).
# The synced copy starts with a marker comment; a CLAUDE.md without it is the pod's own and is
# left alone.
install_claude_md() {
  local dest=$CONFIG_DIR/CLAUDE.md
  if [[ -f $dest ]] && ! head -1 "$dest" | grep -qF "$CLAUDE_MD_MARKER"; then
    log "skipping CLAUDE.md: this pod has its own $dest"
  elif [[ -f $CLONE/CLAUDE.md ]]; then
    cp "$CLONE/CLAUDE.md" "$dest.tmp" && mv "$dest.tmp" "$dest"
  elif [[ -f $dest ]]; then
    rm "$dest"
    log "removed CLAUDE.md (no longer in claude-shared)"
  fi
}

apply() {
  local commit source all_installed=1
  commit=$(git -C "$CLONE" rev-parse HEAD)
  [[ $commit == "$(cat "$APPLIED" 2>/dev/null)" ]] && return 0
  mkdir -p "$SKILLS"
  for source in "$CLONE"/plugins/*/ "$CLONE"/skills/*/; do
    [[ -d $source ]] || continue
    install_entry "${source%/}" || all_installed=0
  done
  remove_stale_entries
  install_claude_md
  if ((all_installed)); then
    echo "$commit" >"$APPLIED"
    log "applied ${commit:0:7}"
  else
    log "not all of ${commit:0:7} applied; retrying next round"
  fi
}

while true; do
  if pull; then
    apply
  else
    log "pull failed; keeping the current copy"
  fi
  sleep "$INTERVAL"
done
