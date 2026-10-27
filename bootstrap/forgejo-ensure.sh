#!/usr/bin/env bash
# Makes sure a Forgejo repo or SSH key exists, by running a short Job inside the cluster.
# Runs on the PC. The Job reads the admin credentials from the forgejo-admin Secret, so the
# password never leaves the cluster; only public keys are passed in. Safe to re-run: existing
# repos and keys are reported and left alone.
#
#   bootstrap/forgejo-ensure.sh user-key <title> <public-key-file>
#       adds an SSH key to the admin user (lets that machine push and pull)
#   bootstrap/forgejo-ensure.sh repo <name> [<deploy-key-title> <public-key-file> [read-write]]
#       creates a private repo, optionally with a deploy key (read-only unless "read-write")
#   bootstrap/forgejo-ensure.sh delete-deploy-key <repo> <deploy-key-title>
#       removes a deploy key (to rotate it, or after a failed scripts/new-deploy-key.sh)
#   bootstrap/forgejo-ensure.sh protect-main <repo>
#       lets only you push to main; deploy keys can still push other branches (proposals)
#   bootstrap/forgejo-ensure.sh rename-repo <old-name> <new-name>
#       renames a repo; its deploy keys, branch protection and history move with it
#   bootstrap/forgejo-ensure.sh pull-request <repo> <head-branch> <base-branch> <title> <body.md>
#       opens a pull request for you to review and merge (prints its URL)
#   bootstrap/forgejo-ensure.sh merge-pr <repo> <number> [<style>]
#       merges a pull request you approved; style fast-forward-only (default), merge, rebase or squash
set -euo pipefail

readonly KUBECTL=(kubectl --context homelab -n forgejo)
readonly API=http://forgejo-http.forgejo.svc:3000/api/v1
readonly IMAGE=curlimages/curl:8.11.1

# Runs the given shell snippet in a one-off pod with the admin credentials in its environment,
# prints its output, and fails if the snippet failed.
run_in_cluster() {
  local snippet=$1 job="forgejo-ensure-$(date +%s)"
  # kubectl does the quoting: the snippet travels as a ConfigMap file, not inside the YAML.
  "${KUBECTL[@]}" create configmap "$job" --from-literal=run.sh="$snippet" >/dev/null
  "${KUBECTL[@]}" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: api
          image: $IMAGE
          env:
            - name: FORGEJO_USER
              valueFrom: {secretKeyRef: {name: forgejo-admin, key: username}}
            - name: FORGEJO_PASSWORD
              valueFrom: {secretKeyRef: {name: forgejo-admin, key: password}}
          command: [sh, /script/run.sh]
          volumeMounts:
            - {name: script, mountPath: /script}
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 100m, memory: 32Mi}
      volumes:
        - name: script
          configMap: {name: $job}
EOF
  "${KUBECTL[@]}" wait --for=condition=complete --timeout=120s "job/$job" >/dev/null 2>&1 || true
  "${KUBECTL[@]}" logs "job/$job"
  local succeeded
  succeeded=$("${KUBECTL[@]}" get "job/$job" -o jsonpath='{.status.succeeded}')
  "${KUBECTL[@]}" delete configmap "$job" >/dev/null
  [[ $succeeded == 1 ]]
}

# Builds a curl call that prints "<label>: HTTP <status>" and treats "already exists" as success.
api_post() {
  local label=$1 path=$2 body=$3
  printf 'code=$(curl -s -o /tmp/out -w %%{http_code} -u "$FORGEJO_USER:$FORGEJO_PASSWORD" -H Content-Type:application/json -d %s %s%s); ' \
    "'$body'" "$API" "$path"
  printf 'case $code in 201) echo "%s: created";; 409|422) echo "%s: already exists";; *) echo "%s: HTTP $code"; cat /tmp/out; exit 1;; esac; ' \
    "$label" "$label" "$label"
}

public_key() { tr -d '\r\n' < "$1"; }

case ${1:-} in
  user-key)
    title=$2 key=$(public_key "$3")
    run_in_cluster "$(api_post "user key '$title'" /user/keys "{\"title\":\"$title\",\"key\":\"$key\"}")"
    ;;
  repo)
    name=$2
    snippet=$(api_post "repo $name" /user/repos "{\"name\":\"$name\",\"private\":true,\"default_branch\":\"main\"}")
    if [[ $# -ge 4 ]]; then
      title=$3 key=$(public_key "$4") read_only=true
      [[ ${5:-} == read-write ]] && read_only=false
      snippet+=$(api_post "deploy key '$title' on $name (read_only=$read_only)" \
        "/repos/\$FORGEJO_USER/$name/keys" "{\"title\":\"$title\",\"key\":\"$key\",\"read_only\":$read_only}")
    fi
    run_in_cluster "$snippet"
    ;;
  delete-deploy-key)
    # Looks the key up by title. The curl image has no jq; Forgejo writes a deploy key's fields in
    # a fixed order (id, key_id, key, url, title, ...), so the id is matched up to the title.
    name=$2 title=$3
    run_in_cluster "$(cat <<EOF
curl -sf -u "\$FORGEJO_USER:\$FORGEJO_PASSWORD" "$API/repos/\$FORGEJO_USER/$name/keys" > /tmp/keys || exit 1
id=\$(grep -o '"id":[0-9]*,"key_id":[0-9]*,"key":"[^"]*","url":"[^"]*","title":"$title"' /tmp/keys | head -1 | sed 's/^"id":\([0-9]*\),.*/\1/')
if [ -z "\$id" ]; then echo "deploy key '$title' on $name: not found"; exit 1; fi
code=\$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -u "\$FORGEJO_USER:\$FORGEJO_PASSWORD" "$API/repos/\$FORGEJO_USER/$name/keys/\$id")
if [ "\$code" = 204 ]; then echo "deploy key '$title' on $name: deleted"; else echo "deploy key '$title' on $name: HTTP \$code"; exit 1; fi
EOF
)"
    ;;
  protect-main)
    # Forgejo blocks deploy keys from a branch with a push whitelist unless
    # push_whitelist_deploy_keys is set, so only the owner (the admin user) can push main.
    name=$2
    body='{"rule_name":"main","branch_name":"main","enable_push":true,"enable_push_whitelist":true,"push_whitelist_usernames":["nitpreet22"],"push_whitelist_deploy_keys":false}'
    run_in_cluster "$(api_post "main protection on $name" "/repos/\$FORGEJO_USER/$name/branch_protections" "$body")"
    ;;
  rename-repo)
    # Clones that still point at the old name need `git remote set-url` to the new one.
    old=$2 new=$3
    run_in_cluster "$(cat <<EOF
code=\$(curl -s -o /tmp/out -w '%{http_code}' -X PATCH -u "\$FORGEJO_USER:\$FORGEJO_PASSWORD" -H Content-Type:application/json -d '{"name":"$new"}' "$API/repos/\$FORGEJO_USER/$old")
if [ "\$code" = 200 ]; then echo "repo $old: renamed to $new"; else echo "repo $old: HTTP \$code"; cat /tmp/out; exit 1; fi
EOF
)"
    ;;
  pull-request)
    # The JSON body is built here (node, as the PC has no jq) and travels base64-encoded, so the
    # Markdown needs no shell quoting inside the snippet.
    name=$2 head=$3 base=$4 title=$5 body_file=$6
    payload=$(node -e 'const fs=require("fs");const [h,b,t,f]=process.argv.slice(1);process.stdout.write(Buffer.from(JSON.stringify({head:h,base:b,title:t,body:fs.readFileSync(f,"utf8")})).toString("base64"))' \
      "$head" "$base" "$title" "$body_file")
    run_in_cluster "$(cat <<EOF
echo "$payload" | base64 -d > /tmp/pr.json
code=\$(curl -s -o /tmp/out -w '%{http_code}' -X POST -u "\$FORGEJO_USER:\$FORGEJO_PASSWORD" -H Content-Type:application/json -d @/tmp/pr.json "$API/repos/\$FORGEJO_USER/$name/pulls")
if [ "\$code" = 201 ]; then echo "pull request on $name: #\$(grep -o '"number":[0-9]*' /tmp/out | head -1 | cut -d: -f2) (Forgejo: \$FORGEJO_USER/$name, Pull requests)"; else echo "pull request on $name: HTTP \$code"; cat /tmp/out; exit 1; fi
EOF
)"
    ;;
  merge-pr)
    # Fast-forward-only by default: main gets the branch's own commits, and Forgejo refuses the
    # merge instead of creating a merge commit when main has moved on.
    name=$2 number=$3 style=${4:-fast-forward-only}
    run_in_cluster "$(cat <<EOF
code=\$(curl -s -o /tmp/out -w '%{http_code}' -X POST -u "\$FORGEJO_USER:\$FORGEJO_PASSWORD" -H Content-Type:application/json -d '{"Do":"$style"}' "$API/repos/\$FORGEJO_USER/$name/pulls/$number/merge")
if [ "\$code" = 200 ]; then echo "pull request $name#$number: merged ($style)"; else echo "pull request $name#$number: HTTP \$code"; cat /tmp/out; exit 1; fi
EOF
)"
    ;;
  *)
    sed -n '2,22p' "$0"; exit 2 ;;
esac
