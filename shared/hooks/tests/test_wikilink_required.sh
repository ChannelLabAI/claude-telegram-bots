#!/usr/bin/env bash
# Tests for wikilink-required.sh.
# Run: bash ~/.claude-bots/shared/hooks/tests/test_wikilink_required.sh
set -uo pipefail

HOOK="$HOME/.claude-bots/shared/hooks/wikilink-required.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# Build a fake HOME so paths resolve under the real Wiki/tasks prefixes.
# We can't change $HOME for path matching, so we test with REAL prefixes
# but use file paths inside a tmp shadow tree that we then `mkdir -p` and `rm`.
# To keep test isolation we use the actual prefixes with a "test-wikilink-hook"
# subdir which we clean up afterwards.

WIKI_TEST_DIR="$HOME/Documents/Obsidian Vault/Ocean/_test-wikilink-hook"
TASKS_TEST_DIR="$HOME/.claude-bots/tasks/_test-wikilink-hook"
# Real-prefix dirs for whitelist tests; cleaned up via TEST_TOUCHED list.
REAL_PEARL_DRAFTS="$HOME/Documents/Obsidian Vault/Ocean/珍珠卡/_drafts"
REAL_REVIEWS="$HOME/Documents/Obsidian Vault/Ocean/審查"
mkdir -p "$WIKI_TEST_DIR/Pearl/_drafts" "$WIKI_TEST_DIR/Reviews" "$TASKS_TEST_DIR" \
    "$REAL_PEARL_DRAFTS" "$REAL_REVIEWS"
TEST_TOUCHED=(
    "$REAL_PEARL_DRAFTS/_wikilink_test_foo.md"
    "$REAL_REVIEWS/CR-20260408-_wikilink_test.md"
)
cleanup() {
    rm -rf "$TMPROOT" "$WIKI_TEST_DIR" "$TASKS_TEST_DIR"
    for f in "${TEST_TOUCHED[@]}"; do rm -f "$f"; done
}
trap cleanup EXIT

# Note: WIKI_TEST_DIR begins with "_" so its basename ("_test-wikilink-hook")
# does NOT short-circuit the whitelist (whitelist matches the FILE basename, not dir).
# But sub-files like notes.md inside it ARE in scope.

run_case() {
    local name="$1" expected="$2" payload="$3"
    local rc
    echo "$payload" | bash "$HOOK" >/dev/null 2>"$TMPROOT/err"
    rc=$?
    if [[ "$rc" == "$expected" ]]; then
        printf '  PASS  %s (rc=%s)\n' "$name" "$rc"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$name" "$expected" "$rc"
        printf '        stderr: %s\n' "$(cat "$TMPROOT/err")"
        FAIL=$((FAIL+1))
    fi
}

# Helper to build tool_input JSON.
write_payload() {
    local fp="$1" content="$2"
    python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]}}))" "$fp" "$content"
}

edit_payload() {
    local fp="$1" old="$2" new="$3"
    python3 -c "import json,sys; print(json.dumps({'tool_name':'Edit','tool_input':{'file_path':sys.argv[1],'old_string':sys.argv[2],'new_string':sys.argv[3]}}))" "$fp" "$old" "$new"
}

bash_payload() {
    local fp="$1" content="$2"
    python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]}}))" "$fp" "$content"
}

echo "wikilink-required.sh tests"
echo "=========================="

# Case 1: Wiki .md WITH wikilink → allow (rc 0)
run_case "wiki_md_with_link" 0 \
    "$(write_payload "$WIKI_TEST_DIR/note1.md" "Hello [[some-link]] world")"

# Case 2: Wiki .md WITHOUT wikilink → block (rc 2)
run_case "wiki_md_without_link" 2 \
    "$(write_payload "$WIKI_TEST_DIR/note2.md" "Hello world no link here")"

# Case 3: tasks/.json WITH wikilink → allow
run_case "task_json_with_link" 0 \
    "$(write_payload "$TASKS_TEST_DIR/task1.json" '{"spec":"see [[ron-builder]]"}')"

# Case 4: tasks/.json WITHOUT wikilink → block
run_case "task_json_without_link" 2 \
    "$(write_payload "$TASKS_TEST_DIR/task2.json" '{"spec":"no link"}')"

# Case 5: _README.md (whitelist by underscore prefix) → allow even without link
run_case "underscore_readme_no_link" 0 \
    "$(write_payload "$WIKI_TEST_DIR/_README.md" "no link here")"

# Case 6: Pearl/_drafts/foo.md → allow even without link
run_case "cards_drafts_no_link" 0 \
    "$(write_payload "$REAL_PEARL_DRAFTS/_wikilink_test_foo.md" "draft content")"

# Case 7: Reviews/CR-foo.md → allow even without link
run_case "reviews_cr_no_link" 0 \
    "$(write_payload "$REAL_REVIEWS/CR-20260408-_wikilink_test.md" "review body")"

# Case 8: out-of-scope file → allow regardless
run_case "out_of_scope_no_link" 0 \
    "$(write_payload "/tmp/somefile.md" "no link, not in scope")"

# Case 9: non-Edit/Write tool → allow
run_case "non_edit_tool" 0 \
    "$(bash_payload "$WIKI_TEST_DIR/note3.md" "no link")"

# Case 10: *_archive.md → allow even without link
run_case "archive_no_link" 0 \
    "$(write_payload "$WIKI_TEST_DIR/old_archive.md" "archived content no link")"

# Case 11: Edit on existing file that already has a link → allow
mkdir -p "$WIKI_TEST_DIR"
echo "existing [[anchor]] text" > "$WIKI_TEST_DIR/existing.md"
run_case "edit_preserves_link" 0 \
    "$(edit_payload "$WIKI_TEST_DIR/existing.md" "text" "modified text")"

# Case 12: Edit on existing file with no link, edit adds none → block
echo "no anchor here" > "$WIKI_TEST_DIR/empty.md"
run_case "edit_still_no_link" 2 \
    "$(edit_payload "$WIKI_TEST_DIR/empty.md" "no anchor here" "still no anchor")"

# Case 13: Edit adds the first link → allow
echo "no anchor here" > "$WIKI_TEST_DIR/empty2.md"
run_case "edit_adds_first_link" 0 \
    "$(edit_payload "$WIKI_TEST_DIR/empty2.md" "no anchor here" "now has [[anchor]] here")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
