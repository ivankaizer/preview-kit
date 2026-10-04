#!/usr/bin/env bash
# Records the tour for one commit, compares it with the PR's previously published demo and
# publishes both to the orphan branch demos/pr-<n> (one force-pushed commit, deleted on PR close).
#
# Env: PREVIEW_URL, PR_NUMBER, SHA, REPO (owner/name), GH_TOKEN (contents: write),
#      TOUR (default .preview/tour.json), WORK (scratch dir), MARKDOWN (output file)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${PREVIEW_URL:?}" "${PR_NUMBER:?}" "${SHA:?}" "${REPO:?}" "${GH_TOKEN:?}"
TOUR=$(realpath "${TOUR:-.preview/tour.json}")
WORK="${WORK:-$(mktemp -d)}"
MARKDOWN="${MARKDOWN:-$WORK/demo.md}"
branch="demos/pr-${PR_NUMBER}"
short=${SHA:0:7}

# 1. Previously published demos for this PR, if any.
pub="$WORK/published"
mkdir -p "$pub"
git -C "$pub" init -q
git -C "$pub" remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
if git -C "$pub" fetch -q --depth 1 origin "refs/heads/${branch}" 2>/dev/null; then
  git -C "$pub" checkout -q FETCH_HEAD
fi
prev=$(cat "$pub/latest" 2>/dev/null || true)
[[ $prev == "$SHA" ]] && prev=$(cat "$pub/previous" 2>/dev/null || true) # re-run of the same commit
clock=""
[[ -n $prev && -f $pub/$prev/manifest.json ]] && clock=$(jq -r '.clock' "$pub/$prev/manifest.json")

# 2. Record this commit.
out="$WORK/out"
(cd "$here" && PREVIEW_URL="$PREVIEW_URL" TOUR="$TOUR" OUT_DIR="$out" DEMO_SHA="$SHA" DEMO_CLOCK="$clock" node tour.mjs)

# 3. Compare with the previous commit.
if [[ -n $prev && -f $pub/$prev/manifest.json ]]; then
  (cd "$here" && BEFORE_DIR="$pub/$prev" AFTER_DIR="$out" node compare.mjs)
fi
rm -f "$out"/changes/*-plain.png "$out"/changes/diff-*.png

# 4. Publish: keep every commit's folder, rewrite history to one commit so the branch stays small.
rm -rf "${pub:?}/${SHA}"
cp -R "$out" "$pub/$SHA"
[[ -n $prev && $prev != "$SHA" ]] && echo "$prev" > "$pub/previous"
echo "$SHA" > "$pub/latest"
git -C "$pub" checkout -q --orphan publish
git -C "$pub" add -A
git -C "$pub" -c user.name="preview-kit" -c user.email="preview-kit@users.noreply.github.com" \
  commit -q -m "Demos for PR #${PR_NUMBER} (latest ${short})"
git -C "$pub" push -q -f origin "HEAD:refs/heads/${branch}"

# 5. Markdown for the PR comment. Same-repo raw links render for anyone with repo access.
raw="https://github.com/${REPO}/raw/${branch}/${SHA}"
blob="https://github.com/${REPO}/blob/${branch}/${SHA}"
tree="https://github.com/${REPO}/tree/${branch}/${SHA}"
manifest="$out/manifest.json"
{
  echo "### 🎬 Demo · \`${short}\`"
  echo
  echo "<details><summary>Full tour ($(jq '.steps | length' "$manifest") steps) · <a href=\"${blob}/tour.mp4\">MP4</a> · <a href=\"${tree}/steps\">screenshots</a></summary>"
  echo
  echo "![Full tour](${raw}/tour.gif)"
  echo
  echo "</details>"
  echo
  jq -r '.failures[] | "> ⚠️ Step **\(.step)** failed: `\(.error)`"' "$manifest"
  if [[ -f $out/changes.json ]]; then
    changes="$out/changes.json"
    count=$(jq '.changed | length' "$changes")
    echo "#### Changes since \`${prev:0:7}\`"
    echo
    if ((count > 0)); then
      echo "[▶ Changes video (MP4)](${blob}/changes.mp4)"
      echo
      jq -r --arg raw "$raw" '.changed[] |
        "**\(.name)** · \((.ratio * 1000 | round) / 10)% changed\n\n![\(.name)](\($raw)/\(.image))\n"' "$changes"
    else
      echo "No visual changes in any step."
      echo
    fi
    jq -r 'if (.added | length) > 0 then "New steps: \(.added | join(", "))\n" else empty end,
           if (.removed | length) > 0 then "Removed steps: \(.removed | join(", "))\n" else empty end' "$changes"
    jq -r '"<sub>Unchanged: \(.unchanged | join(", ") | if . == "" then "none" else . end)</sub>"' "$changes"
  else
    echo "<sub>First demo for this PR; the next commit will show what changed.</sub>"
  fi
} > "$MARKDOWN"
echo "Published demos to ${branch}; comment body in ${MARKDOWN}"
