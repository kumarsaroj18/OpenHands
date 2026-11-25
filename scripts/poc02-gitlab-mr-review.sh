#!/usr/bin/env bash
# POC 02 helper: automated code review of a GitLab MR by Agent Canvas.
#   scripts/poc02-gitlab-mr-review.sh setup     create the custom webhook + the review automation (enabled)
#   scripts/poc02-gitlab-mr-review.sh mr        push a test branch, open a draft MR, send the signed event, watch the run
#   scripts/poc02-gitlab-mr-review.sh event IID send the signed merge_request event for an existing MR number
#   scripts/poc02-gitlab-mr-review.sh watch     show the latest run of the automation until it finishes
#   scripts/poc02-gitlab-mr-review.sh cleanup   delete the automation, the webhook, the test MR and branch
set -euo pipefail

CANVAS=${CANVAS:-http://localhost:8000}
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

event() {  # $1 = MR iid
  title=$(glab mr view "$1" -R "$PROJECT" -F json 2>/dev/null | jq -r .title || echo "POC test")
  SECRET=$(cat "$STATE/secret") IID="$1" TITLE="$title" PROJECT="$PROJECT" \
  BRANCH="$BRANCH" TARGET="$TARGET" URL="$CANVAS/api/automation/v1/events/$ORG_ID/$SOURCE" \
  python3 - <<'PY'
import os, json, time, hmac, hashlib, base64, urllib.request
e = os.environ
body = json.dumps({"object_kind": "merge_request", "user": {"username": "poc"},
  "project": {"path_with_namespace": e["PROJECT"]},
  "object_attributes": {"action": "open", "iid": int(e["IID"]), "title": e["TITLE"],
    "description": "", "source_branch": e["BRANCH"], "target_branch": e["TARGET"]}}).encode()
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
  event "${url##*/}"
  watch
}

watch() {
  id=$(cat "$STATE/automation")
  while :; do
    run=$(api "$A/$id/runs?limit=1" | jq '.runs[0] // empty')
    [ -z "$run" ] && { echo "no run yet"; sleep 5; continue; }
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
  setup|mr|watch|cleanup) "$1" ;;
  event) event "${2:?MR number needed}"; watch ;;
  *) sed -n 2,7p "$0" ;;
esac
