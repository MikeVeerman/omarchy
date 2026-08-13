#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

collector="$ROOT/bin/omarchy-agent-usage-opencode"

# opencode records one JSON file per message under storage/message/<session>/.
# Timestamps are epoch milliseconds, so today's rows have to be generated.
now_ms=$(($(date +%s) * 1000))

write_message() {
  local home="$1" session="$2" id="$3" body="$4"
  local dir="$home/.local/share/opencode/storage/message/$session"

  mkdir -p "$dir"
  printf '%s\n' "$body" >"$dir/$id.json"
}

# ---------------------------------------------------------------- file storage

FILE_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME"' EXIT

write_message "$FILE_HOME" ses_a msg_1 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_1", sessionID: "ses_a", role: "assistant",
  providerID: "llama-swap", modelID: "qwen3.6-35b",
  time: {created: $t},
  tokens: {input: 100, output: 20, reasoning: 5, cache: {read: 10, write: 2}}
}')"

write_message "$FILE_HOME" ses_a msg_2 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_2", sessionID: "ses_a", role: "assistant",
  providerID: "openrouter", modelID: "qwen/qwen3-coder-next",
  time: {created: $t},
  tokens: {input: 50, output: 10, reasoning: 0, cache: {read: 0, write: 0}}
}')"

# A user message carries a nested .model and no tokens; it must not be counted.
write_message "$FILE_HOME" ses_a msg_3 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_3", sessionID: "ses_a", role: "user",
  model: {providerID: "llama-swap", modelID: "qwen3.6-35b"},
  time: {created: $t}
}')"

result=$(HOME="$FILE_HOME" XDG_DATA_HOME="$FILE_HOME/.local/share" \
  XDG_CACHE_HOME="$FILE_HOME/.cache" "$collector" --force)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "197" ]] ||
  fail "opencode collector totals today's tokens from file storage" "$result"
pass "opencode collector totals today's tokens from file storage"

[[ $(jq -c '.modelUsage["qwen3.6-35b"]' <<<"$result") == '{"inputTokens":100,"outputTokens":25,"cacheReadInputTokens":10,"cacheCreationInputTokens":2}' ]] ||
  fail "opencode collector folds reasoning tokens into output" "$result"
pass "opencode collector folds reasoning tokens into output"

# opencode model ids carry a vendor path; the panel lists the bare model.
[[ $(jq -r '.modelUsage | has("qwen3-coder-next")' <<<"$result") == "true" ]] ||
  fail "opencode collector strips the vendor prefix from model ids" "$result"
pass "opencode collector strips the vendor prefix from model ids"

[[ $(jq -r '.totalPrompts' <<<"$result") == "2" ]] ||
  fail "opencode collector counts assistant messages only" "$result"
pass "opencode collector counts assistant messages only"

[[ $(jq -c '.id + "/" + (.limits|tostring) + "/" + (.ready|tostring)' <<<"$result") == '"opencode/[]/true"' ]] ||
  fail "opencode collector identifies itself with an empty limits list" "$result"
pass "opencode collector identifies itself with an empty limits list"

# An empty tierLabel makes the panel call the hero a "Subscription", which
# opencode never is: it spends a local runner or a per-token API key.
[[ $(jq -r '.tierLabel' <<<"$result") == "Bring your own model" ]] ||
  fail "opencode collector names what the hero actually is" "$result"
pass "opencode collector names what the hero actually is"

[[ $(jq -r '.recentDays | length' <<<"$result") == "7" ]] ||
  fail "opencode collector reports a full week of days" "$result"
[[ $(jq -r '.recentDays[-1].messageCount' <<<"$result") == "197" ]] ||
  fail "opencode collector puts today's tokens in the last recent day" "$result"
pass "opencode collector reports a full week of days"

# ------------------------------------------------------- provider ownership

OWNED_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME" "$OWNED_HOME"' EXIT

write_message "$OWNED_HOME" ses_b msg_1 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_1", sessionID: "ses_b", role: "assistant",
  providerID: "anthropic", modelID: "claude-opus-4-5",
  time: {created: $t},
  tokens: {input: 999, output: 999, reasoning: 0, cache: {read: 0, write: 0}}
}')"

write_message "$OWNED_HOME" ses_b msg_2 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_2", sessionID: "ses_b", role: "assistant",
  providerID: "openai", modelID: "gpt-5.6",
  time: {created: $t},
  tokens: {input: 888, output: 888, reasoning: 0, cache: {read: 0, write: 0}}
}')"

write_message "$OWNED_HOME" ses_b msg_3 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_3", sessionID: "ses_b", role: "assistant",
  providerID: "mistral", modelID: "devstral-medium-latest",
  time: {created: $t},
  tokens: {input: 7, output: 3, reasoning: 0, cache: {read: 0, write: 0}}
}')"

result=$(HOME="$OWNED_HOME" XDG_DATA_HOME="$OWNED_HOME/.local/share" \
  XDG_CACHE_HOME="$OWNED_HOME/.cache" "$collector" --force)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "10" ]] ||
  fail "opencode collector leaves anthropic and openai to their own collectors" "$result"
[[ $(jq -c '.modelUsage | keys' <<<"$result") == '["devstral-medium-latest"]' ]] ||
  fail "opencode collector reports only unclaimed providers" "$result"
pass "opencode collector leaves anthropic and openai to their own collectors"

# ------------------------------------------------------------- legacy database

DB_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME" "$OWNED_HOME" "$DB_HOME"' EXIT
mkdir -p "$DB_HOME/.local/share/opencode"

python3 - "$DB_HOME/.local/share/opencode/opencode.db" "$now_ms" <<'PY'
import json
import sqlite3
import sys

db, created = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE message (session_id TEXT, data TEXT)")
conn.execute(
  "INSERT INTO message VALUES (?, ?)",
  ("ses_db", json.dumps({
    "id": "msg_db", "role": "assistant",
    "providerID": "llama-swap", "modelID": "glm-4.5-air",
    "time": {"created": created},
    "tokens": {"input": 30, "output": 12, "reasoning": 0, "cache": {"read": 0, "write": 0}},
  })),
)
conn.commit()
conn.close()
PY

result=$(HOME="$DB_HOME" XDG_DATA_HOME="$DB_HOME/.local/share" \
  XDG_CACHE_HOME="$DB_HOME/.cache" "$collector" --force)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "42" ]] ||
  fail "opencode collector still reads the legacy message database" "$result"
pass "opencode collector still reads the legacy message database"

# ------------------------------------------------------------- damaged input

JUNK_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME" "$OWNED_HOME" "$DB_HOME" "$JUNK_HOME"' EXIT

write_message "$JUNK_HOME" ses_c msg_1 '{"id": "msg_1", "role": "assistant",'
write_message "$JUNK_HOME" ses_c msg_2 '[]'

# ollama reports no usage at all; a zero-token message is not a prompt.
write_message "$JUNK_HOME" ses_c msg_3 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_3", sessionID: "ses_c", role: "assistant",
  providerID: "ollama", modelID: "qwen2.5-coder:7b",
  time: {created: $t},
  tokens: {input: 0, output: 0, reasoning: 0, cache: {read: 0, write: 0}}
}')"

write_message "$JUNK_HOME" ses_c msg_4 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_4", sessionID: "ses_c", role: "assistant",
  providerID: "llama-swap", modelID: "qwen3.6-27b",
  time: {created: $t},
  tokens: {input: 4, output: 1, reasoning: 0, cache: {read: 0, write: 0}}
}')"

result=$(HOME="$JUNK_HOME" XDG_DATA_HOME="$JUNK_HOME/.local/share" \
  XDG_CACHE_HOME="$JUNK_HOME/.cache" "$collector" --force)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "5" ]] ||
  fail "opencode collector survives damaged message files" "$result"
[[ $(jq -c '.modelUsage | keys' <<<"$result") == '["qwen3.6-27b"]' ]] ||
  fail "opencode collector skips messages that recorded no tokens" "$result"
pass "opencode collector survives damaged message files"

# --------------------------------------------------------------- no opencode

EMPTY_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME" "$OWNED_HOME" "$DB_HOME" "$JUNK_HOME" "$EMPTY_HOME"' EXIT

result=$(HOME="$EMPTY_HOME" XDG_DATA_HOME="$EMPTY_HOME/.local/share" \
  XDG_CACHE_HOME="$EMPTY_HOME/.cache" "$collector" --force)

jq -e . >/dev/null 2>&1 <<<"$result" ||
  fail "opencode collector prints a valid record without opencode" "$result"
[[ $(jq -r '.ready' <<<"$result") == "false" ]] ||
  fail "opencode collector stays out of the panel without recorded usage" "$result"
pass "opencode collector stays out of the panel without recorded usage"

# ------------------------------------------------------------------- caching

CACHE_HOME=$(mktemp -d)
trap 'rm -rf "$FILE_HOME" "$OWNED_HOME" "$DB_HOME" "$JUNK_HOME" "$EMPTY_HOME" "$CACHE_HOME"' EXIT

write_message "$CACHE_HOME" ses_d msg_1 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_1", sessionID: "ses_d", role: "assistant",
  providerID: "mistral", modelID: "codestral-latest",
  time: {created: $t},
  tokens: {input: 6, output: 2, reasoning: 0, cache: {read: 0, write: 0}}
}')"

HOME="$CACHE_HOME" XDG_DATA_HOME="$CACHE_HOME/.local/share" \
  XDG_CACHE_HOME="$CACHE_HOME/.cache" "$collector" >/dev/null

write_message "$CACHE_HOME" ses_d msg_2 "$(jq -cn --argjson t "$now_ms" '{
  id: "msg_2", sessionID: "ses_d", role: "assistant",
  providerID: "mistral", modelID: "codestral-latest",
  time: {created: $t},
  tokens: {input: 1000, output: 1000, reasoning: 0, cache: {read: 0, write: 0}}
}')"

cached=$(HOME="$CACHE_HOME" XDG_DATA_HOME="$CACHE_HOME/.local/share" \
  XDG_CACHE_HOME="$CACHE_HOME/.cache" "$collector")
[[ $(jq -r '.todayTotalTokens' <<<"$cached") == "8" ]] ||
  fail "opencode collector reuses a recent scan" "$cached"

forced=$(HOME="$CACHE_HOME" XDG_DATA_HOME="$CACHE_HOME/.local/share" \
  XDG_CACHE_HOME="$CACHE_HOME/.cache" "$collector" --force)
[[ $(jq -r '.todayTotalTokens' <<<"$forced") == "2008" ]] ||
  fail "opencode collector rescans on --force" "$forced"
pass "opencode collector reuses a recent scan until forced"
