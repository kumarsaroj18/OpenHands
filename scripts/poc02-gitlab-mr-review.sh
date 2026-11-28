#!/usr/bin/env bash
# POC 02 helper: automated code review of a GitLab MR by Agent Canvas.
#   scripts/poc02-gitlab-mr-review.sh setup     create the custom webhook + the review automation (enabled)
#   scripts/poc02-gitlab-mr-review.sh mr        push a test branch, open a draft MR, send the signed event, watch the run
#   scripts/poc02-gitlab-mr-review.sh review [IID]  review an existing MR (default: the newest open MR) and watch the run
#   scripts/poc02-gitlab-mr-review.sh follow    keep running: review every MR opened from now on (for example by the
#                                               issue-to-MR automation), and again after each new push, one at a time.
#                                               Stop with Ctrl+C.
#   scripts/poc02-gitlab-mr-review.sh event IID same as review IID (old name)
#   scripts/poc02-gitlab-mr-review.sh watch     show the latest run of the automation until it finishes
#   scripts/poc02-gitlab-mr-review.sh cleanup   delete the automation, the webhook, the test MR and branch
set -euo pipefail

CANVAS=${CANVAS:-http://localhost:8000}
# glab picks the GitLab host from the current folder's git remote and falls back to
# gitlab.com, so name the company GitLab for every glab call.
export GITLAB_HOST=${GITLAB_HOST:-gitlab.technogise.com}
CONTAINER=${CONTAINER:-agent-canvas}
SOURCE=technogise-gitlab
ORG_ID=46d09c5c-7d7d-585f-8c37-a6b45a3de738   # fixed local org id
# The software-factory copy: the Canvas GITLAB_TOKEN (a software-factory group token) can read it.
PROJECT=${PROJECT:-software-factory/feedback-app-backend}
TARGET=${TARGET:-master}
BRANCH=poc02-agent-canvas-review   # no slash: the repo has a branch named "test"
STATE=${STATE:-$HOME/.poc02}                   # secret + ids, outside any repo
mkdir -p "$STATE" && chmod 700 "$STATE"

KEY=$(docker exec "$CONTAINER" cat /home/openhands/.openhands/agent-canvas/api-key.txt)
api() { curl -sS -H "X-Session-API-Key: $KEY" -H "Content-Type: application/json" "$@"; }
A="$CANVAS/api/automation/v1"

read -r -d '' PROMPT <<'EOF' || true
You are a code reviewer for the feedback-app-backend project.
Your GitLab token is in the environment variable $GITLAB_TOKEN.
A merge request was opened. Read the MR details from the "Event Payload"
section (object_attributes.iid, .title, .description, .source_branch,
.target_branch, project.path_with_namespace).

1. In the cloned repo run: git fetch origin <source_branch> <target_branch>
   and git diff origin/<target_branch>...origin/<source_branch>
2. Review the diff for: bugs, error handling, security (secrets, input
   validation), missing tests, and fit with existing patterns. Be specific:
   file names and line numbers. Do not change any code.
3. Post the review as ONE comment on the MR with the GitLab API:
   POST https://gitlab.technogise.com/api/v4/projects/<url-encoded path>/merge_requests/<iid>/notes
   header PRIVATE-TOKEN: $GITLAB_TOKEN, JSON body {"body": "<review in markdown>"}.
   If the token is missing or the call fails, print the review instead and say why.
EOF

setup() {
  # 1. Webhook: delete an old one (its secret is lost), then create with a fresh secret.
  old=$(api "$A/webhooks" | jq -r --arg s "$SOURCE" '.webhooks[] | select(.source==$s) | .id')
  if [ -n "$old" ]; then api -X DELETE "$A/webhooks/$old" -o /dev/null; echo "deleted old webhook"; fi
  secret="${GITLAB_SIGNING_TOKEN:-whsec_$(openssl rand -base64 32)}"
  printf '%s' "$secret" > "$STATE/secret" && chmod 600 "$STATE/secret"
  api -X POST "$A/webhooks" -d "$(jq -n --arg s "$SOURCE" --arg k "$secret" '{
      name:"Technogise GitLab", source:$s, event_key_expr:"object_kind",
      signature_header:"webhook-signature", signature_scheme:"standard_webhooks",
      event_id_header:"webhook-id", webhook_secret:$k}')" | jq '{source, webhook_url}'

  # 2. Automation (replaces the one this script made before). It runs through an agent
  #    profile: without one it falls back to a default LLM key, which may not be set.
  profile=$(api "$CANVAS/api/agent-profiles" | jq -r --arg n "${AGENT_PROFILE:-default}" '(.profiles // .items // .)[] | select(.name==$n) | .id')
  [ -n "$profile" ] || { echo "No agent profile named '${AGENT_PROFILE:-default}' in Canvas" >&2; exit 1; }
  if [ -f "$STATE/automation" ]; then api -X DELETE "$A/$(cat "$STATE/automation")" -o /dev/null; fi
  api -X POST "$A/preset/prompt" -d "$(jq -n --arg p "$PROMPT" --arg s "$SOURCE" --arg proj "$PROJECT" --arg prof "$profile" '{
      name:"Code Review - feedback-app-backend", prompt:$p, agent_profile_id:$prof, timeout:600, enabled:true,
      trigger:{type:"event", source:$s, on:"merge_request",
               filter:("object_attributes.action == '\''open'\'' && project.path_with_namespace == '\''" + $proj + "'\''")},
      repos:[{url:("https://gitlab.technogise.com/" + $proj + ".git"), provider:"gitlab"}]}')" \
    | tee "$STATE/automation.json" | jq '{id, name, enabled, agent_profile_id, trigger: .trigger | {source, on, filter}}'
  jq -r .id "$STATE/automation.json" > "$STATE/automation"
}

# Stop early when setup has not run or cleanup removed what it made; otherwise
# events reach Canvas, match nothing, and watch waits forever.
require_setup() {
  [ -s "$STATE/automation" ] && [ -s "$STATE/secret" ] \
    || { echo "The review automation is not set up (or cleanup removed it). Run: $0 setup" >&2; exit 1; }
  api "$A/$(cat "$STATE/automation")" | jq -e .id >/dev/null 2>&1 \
    || { echo "The review automation no longer exists in Canvas. Run: $0 setup" >&2; exit 1; }
}

last_run() { api "$A/$(cat "$STATE/automation")/runs?limit=1" | jq -r '.runs[0].id // ""'; }

event() {  # $1 = MR iid. Sends the event GitLab would send when the MR is opened.
  # The MR's real branches, title and description, so the reviewer diffs the right code.
  mr_json=$(glab mr view "$1" -R "$PROJECT" -F json) || { echo "MR !$1 not found in $PROJECT" >&2; return 1; }
  echo "Reviewing MR !$1: $(jq -r '.title + "  (" + .source_branch + " -> " + .target_branch + ")"' <<<"$mr_json")"
  SECRET=$(cat "$STATE/secret") MR_JSON="$mr_json" PROJECT="$PROJECT" \
  URL="$CANVAS/api/automation/v1/events/$ORG_ID/$SOURCE" \
  python3 - <<'PY'
import os, json, time, hmac, hashlib, base64, urllib.request
e = os.environ
mr = json.loads(e["MR_JSON"])
body = json.dumps({"object_kind": "merge_request", "user": {"username": "poc"},
  "project": {"path_with_namespace": e["PROJECT"]},
  "object_attributes": {"action": "open", "iid": mr["iid"], "title": mr["title"],
    "description": mr.get("description") or "", "source_branch": mr["source_branch"],
    "target_branch": mr["target_branch"], "url": mr.get("web_url", "")}}).encode()
msg_id, ts = "msg_%d" % time.time_ns(), str(int(time.time()))
raw = e["SECRET"].removeprefix("whsec_")
try: key = base64.b64decode(raw, validate=True)
except ValueError: key = e["SECRET"].encode()
sig = base64.b64encode(hmac.new(key, f"{msg_id}.{ts}.".encode() + body, hashlib.sha256).digest()).decode()
req = urllib.request.Request(e["URL"], body, {"Content-Type": "application/json",
  "webhook-id": msg_id, "webhook-timestamp": ts, "webhook-signature": "v1," + sig})
print(urllib.request.urlopen(req).read().decode())
PY
}

mr() {
  # Fresh shallow clone in a throwaway folder: no local checkout needed or touched.
  rm -rf "$STATE/wt"
  glab repo clone "$PROJECT" "$STATE/wt" -- -q --depth 1 -b "$TARGET"
  cd "$STATE/wt" && git switch -q -c "$BRANCH"
  mkdir -p poc && cat > poc/ReviewSample.kt <<'KT'
// POC file for the automated review test. Contains deliberate problems.
object ReviewSample {
    val password = "admin123"
    fun ratio(a: Int, b: Int): Int = a / b
}
KT
  git add poc/ReviewSample.kt && git commit -qm "POC: test Agent Canvas code review"
  git push -qf -u origin "$BRANCH"
  url=$(glab mr create -R "$PROJECT" -s "$BRANCH" -b "$TARGET" --draft -y \
        -t "POC: Test Agent Canvas Code Review" -d "Throwaway MR for POC 02." 2>&1 | grep -o 'https://[^ ]*merge_requests/[0-9]*' | head -1)
  [ -z "$url" ] && url=$(glab mr view "$BRANCH" -R "$PROJECT" -F json | jq -r .web_url)
  echo "MR: $url"
  cd / && rm -rf "$STATE/wt"
  review "${url##*/}"
}

review() {  # [$1 = MR iid], default: the newest open MR in the project
  iid=${1:-$(glab mr list -R "$PROJECT" -F json -P 100 | jq -r 'max_by(.created_at) | .iid // empty')}
  [ -n "$iid" ] || { echo "No open MR in $PROJECT" >&2; return 1; }
  require_setup
  before=$(last_run)
  resp=$(event "$iid") || return 1
  echo "$resp"
  # Canvas answers {"matched": N, ...}; with 0 no review run starts.
  if ! jq -e '.matched > 0' >/dev/null 2>&1 <<<"$(tail -1 <<<"$resp")"; then
    echo "No automation accepted the event for MR !$iid, so no review started. Run: $0 setup" >&2
    return 1
  fi
  watch "$before"
}

follow() {  # Polls GitLab; reviews each new MR, and reviews it again after each new push.
  require_setup
  seen="$STATE/reviewed-sha"; touch "$seen"   # one line per review: "<iid> <head commit>"
  open_mrs() { glab mr list -R "$PROJECT" -F json -P 100 | jq -r 'sort_by(.created_at) | .[] | "\(.iid) \(.sha)"'; }
  last_sha() { awk -v i="$1" '$1 == i { s = $2 } END { print s }' "$seen"; }
  # MRs open when follow first sees them are not reviewed until their next push; use "review IID" for those.
  # MRs follow already knows keep their last reviewed commit, so pushes made while it was stopped are reviewed.
  rows=$(open_mrs)
  while read -r iid sha; do
    if [ -n "$iid" ] && [ -z "$(last_sha "$iid")" ]; then echo "$iid $sha" >> "$seen"; fi
  done <<<"$rows"
  echo "Watching $PROJECT for new MRs and new commits every ${INTERVAL:-30}s (Ctrl+C to stop). Open: $(cut -d' ' -f1 <<<"$rows" | tr '\n' ' ')"
  while :; do
    rows=$(open_mrs)
    while read -r iid sha; do
      [ -n "$iid" ] || continue
      prev=$(last_sha "$iid")
      if [ "$prev" = "$sha" ]; then continue; fi
      # Record before reviewing: a push during the review changes the commit again and is caught next round.
      echo "$iid $sha" >> "$seen"
      if [ -z "$prev" ]; then echo "$(date +%T) new MR !$iid"; else echo "$(date +%T) new commits on MR !$iid (now ${sha:0:8})"; fi
      review "$iid" </dev/null || echo "Review of MR !$iid failed. Retry it with: $0 review $iid"
    done <<<"$rows"
    sleep "${INTERVAL:-30}"
  done
}

watch() {  # [$1 = run id to ignore: waits for a run newer than that one]
  require_setup
  id=$(cat "$STATE/automation")
  waited=0
  while :; do
    run=$(api "$A/$id/runs?limit=1" | jq '.runs[0] // empty')
    if [ -z "$run" ] || { [ -n "${1:-}" ] && [ "$(jq -r .id <<<"$run")" = "$1" ]; }; then
      waited=$((waited + 5))
      [ "$waited" -ge 300 ] && { echo "No review run started within 5 minutes; check the automation in Canvas." >&2; return 1; }
      echo "waiting for the run to start"; sleep 5; continue
    fi
    st=$(jq -r .status <<<"$run"); echo "$(date +%T) run $(jq -r .id <<<"$run"): $st"
    case "$st" in COMPLETED|FAILED|CANCELLED|SKIPPED)
      jq '{status, conversation_id, cost, error_detail}' <<<"$run"
      echo "Open the conversation in Canvas: $CANVAS/conversations/$(jq -r .conversation_id <<<"$run")"; break;; esac
    sleep 15
  done
}

cleanup() {
  if [ -f "$STATE/automation" ]; then api -X DELETE "$A/$(cat "$STATE/automation")" -o /dev/null; echo "automation deleted"; fi
  old=$(api "$A/webhooks" | jq -r --arg s "$SOURCE" '.webhooks[] | select(.source==$s) | .id')
  if [ -n "$old" ]; then api -X DELETE "$A/webhooks/$old" -o /dev/null; echo "webhook deleted"; fi
  glab mr close "$BRANCH" -R "$PROJECT" 2>/dev/null || true
  glab api -X DELETE "projects/${PROJECT//\//%2F}/repository/branches/$BRANCH" >/dev/null 2>&1 && echo "branch deleted" || true
  rm -rf "$STATE"
}

case "${1:-}" in
  setup|mr|watch|cleanup|follow) "$1" ;;
  review) review "${2:-}" ;;
  event) review "${2:?MR number needed}" ;;
  *) sed -n 2,11p "$0" ;;
esac
