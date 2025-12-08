#!/bin/bash
set -euo pipefail

if [[ -z "${COMMENTS_FILE:-}" || -z "${PR_NUMBER:-}" || -z "${REPO:-}" || -z "${HEAD_SHA:-}" ]]; then
  echo "Missing required environment variables" >&2
  exit 1
fi

if [[ ! -f "$COMMENTS_FILE" ]] || [[ ! -s "$COMMENTS_FILE" ]]; then
  echo "No comments to post"
  exit 0
fi

# Separate inline and general comments
inline_comments=$(jq -s '[.[] | select(.type == "inline")]' "$COMMENTS_FILE")
general_comments=$(jq -s '[.[] | select(.type == "general")]' "$COMMENTS_FILE")

# Build review body from general comments
body=$(echo "$general_comments" | jq -r '[.[].message] | join("\n\n")')

# Build inline comments array for GitHub API
review_comments=$(echo "$inline_comments" | jq '[.[] | {
  path: .path,
  line: .line,
  side: "RIGHT",
  body: (if .suggested_fix then (.message + "\n\n```suggestion\n" + .suggested_fix + "\n```") else .message end)
}]')

inline_count=$(echo "$review_comments" | jq 'length')
echo "Posting review with $inline_count inline comments"

# Get the list of changed lines in the PR diff
# This creates a JSON object mapping "file:line" to true for all lines in the diff
diff_lines=$(gh api "repos/$REPO/pulls/$PR_NUMBER/files" --jq '
  [.[] | .filename as $file | .patch // "" |
   split("\n") | to_entries | reduce .[] as $entry (
     {line: 0, result: []};
     if ($entry.value | startswith("@@")) then
       # Parse hunk header like "@@ -1,3 +4,5 @@" to get the new file line number
       .line = ($entry.value | capture("@@ -[0-9]+(,[0-9]+)? \\+(?<start>[0-9]+)") | .start | tonumber)
     elif ($entry.value | startswith("-")) then
       .  # Deleted lines do not increment the line counter
     elif ($entry.value | startswith("+")) then
       .result += ["\($file):\(.line)"] | .line += 1
     else
       .line += 1
     end
   ) | .result
  ] | flatten | map({(.): true}) | add // {}
')

# Filter inline comments to only include those on lines in the diff
# Comments on lines not in the diff are converted to general comments
filtered_inline=$(echo "$review_comments" | jq --argjson diff "$diff_lines" '
  [.[] | select($diff["\(.path):\(.line)"] == true)]
')
orphan_comments=$(echo "$review_comments" | jq --argjson diff "$diff_lines" '
  [.[] | select($diff["\(.path):\(.line)"] != true) |
   "**\(.path):\(.line)**: \(.body)"]
')

# Add orphan comments to the body
orphan_body=$(echo "$orphan_comments" | jq -r 'if length > 0 then join("\n\n") else "" end')
if [[ -n "$orphan_body" && "$orphan_body" != "" ]]; then
  if [[ -n "$body" && "$body" != "" ]]; then
    body="$body"$'\n\n'"$orphan_body"
  else
    body="$orphan_body"
  fi
fi

filtered_count=$(echo "$filtered_inline" | jq 'length')
orphan_count=$(echo "$orphan_comments" | jq 'length')
echo "Filtered to $filtered_count inline comments ($orphan_count moved to body)"

# Build the review payload
payload=$(jq -n \
  --arg commit_id "$HEAD_SHA" \
  --arg body "$body" \
  --argjson comments "$filtered_inline" \
  '{
    commit_id: $commit_id,
    event: "COMMENT",
    body: (if $body == "" then null else $body end),
    comments: (if ($comments | length) == 0 then null else $comments end)
  } | with_entries(select(.value != null))')

# Check if payload has any content to post
if [[ $(echo "$payload" | jq 'has("body") or has("comments")') == "false" ]]; then
  echo "No content to post after filtering"
  exit 0
fi

echo "$payload" | gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --method POST --input -
echo "Review posted successfully"
