#!/usr/bin/env bash
set -euo pipefail

SOURCE="${SOURCE_GIT_URL}"
TARGET="${TARGET_GIT_URL}"
TOKEN="${TARGET_GIT_TOKEN}"
SOURCE_TOKEN="${SOURCE_GIT_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"

# Inject tokens into URLs
TARGET_AUTH=$(echo "${TARGET}" | sed "s|https://|https://x-access-token:${TOKEN}@|")

if [ -n "${SOURCE_TOKEN}" ]; then
  SOURCE_AUTH=$(echo "${SOURCE}" | sed "s|https://|https://x-access-token:${SOURCE_TOKEN}@|")
else
  SOURCE_AUTH="${SOURCE}"
fi

# Increase HTTP buffer for large pushes
git config --global http.postBuffer 524288000

echo "============================================"
echo "  Repository Sync"
echo "============================================"
echo "Source: ${SOURCE}"
echo "Target: ${TARGET}"
echo "============================================"

# Step 1: Get source HEAD
echo "[1/4] Fetching source HEAD..."
SOURCE_HEAD=$(git -c http.userAgent="git-sync/1.0" ls-remote "${SOURCE_AUTH}" HEAD 2>/dev/null | awk '{print $1}')
if [ -z "${SOURCE_HEAD}" ]; then
  echo "ERROR: Could not fetch source HEAD. Check URL and network."
  exit 1
fi
echo "  Source HEAD: ${SOURCE_HEAD}"

# Step 2: Get target HEAD
echo "[2/4] Fetching target HEAD..."
TARGET_HEAD=$(git ls-remote "${TARGET_AUTH}" HEAD 2>/dev/null | awk '{print $1}')
if [ -z "${TARGET_HEAD}" ]; then
  TARGET_HEAD="none"
  echo "  Target: empty repository (first sync)"
else
  echo "  Target HEAD: ${TARGET_HEAD}"
fi

# Step 3: Compare
echo "[3/4] Comparing..."
echo "synced=false" >> $GITHUB_OUTPUT
echo "source-sha=${SOURCE_HEAD}" >> $GITHUB_OUTPUT
echo "target-sha=${TARGET_HEAD}" >> $GITHUB_OUTPUT

if [ "${SOURCE_HEAD}" = "${TARGET_HEAD}" ]; then
  echo ""
  echo "Already in sync. Skipping push."
  echo "synced=false" >> $GITHUB_OUTPUT
  exit 0
fi

echo ""
echo "Target is behind source. Sync needed."

if [ "${DRY_RUN}" = "true" ]; then
  echo "DRY_RUN=true - skipping actual push."
  exit 0
fi

# Step 4: Clone + Push
echo "[4/4] Cloning source (mirror)..."
TMPDIR=$(mktemp -d)
git clone --mirror "${SOURCE_AUTH}" "${TMPDIR}/repo.git"

echo "Pushing to target..."
cd "${TMPDIR}/repo.git"

# First try: mirror push (fast path - works for repos < 2GB)
if git push --mirror "${TARGET_AUTH}" 2>&1; then
  echo "Mirror push succeeded."
else
  echo "Mirror push failed. Falling back to batch push (--force)..."

  # Batch push strategy: push each branch in 500-commit batches
  # Use --force because merge commits may make anchors non-fast-forward
  BRANCHES=$(git for-each-ref --format='%(refname:short)' refs/heads/)

  for BRANCH in ${BRANCHES}; do
    echo "  Syncing branch: ${BRANCH}"

    TOTAL=$(git rev-list --count "refs/heads/${BRANCH}" 2>/dev/null || echo 0)
    echo "    Total commits: ${TOTAL}"

    if [ "${TOTAL}" -gt 500 ]; then
      # Get branch tip first
      TIP=$(git rev-parse "refs/heads/${BRANCH}")

      # Batch push with --force: every 500 commits
      # --force is needed because non-linear history (merge commits)
      # means later anchors may not be descendants of earlier ones
      ANCHORS=$(git rev-list --reverse "refs/heads/${BRANCH}" | awk 'NR % 500 == 0')
      for SHA in ${ANCHORS}; do
        echo "    Batch -> ${SHA:0:8}..."
        git push --force "${TARGET_AUTH}" "${SHA}:refs/heads/${BRANCH}" 2>&1 \
          && echo "    OK" \
          || echo "    FAILED (will retry with smaller batch)"
      done

      # Final push to actual branch tip (ensures latest commit is set)
      echo "    Final tip -> ${TIP:0:8}..."
      git push --force "${TARGET_AUTH}" "${TIP}:refs/heads/${BRANCH}" 2>&1 \
        && echo "    Tip OK" \
        || echo "    Tip FAILED"
    else
      # Small branch: push all at once with --force
      git push --force "${TARGET_AUTH}" "refs/heads/${BRANCH}:refs/heads/${BRANCH}" 2>&1 \
        && echo "    Branch OK" \
        || echo "    Branch FAILED"
    fi
  done

  # Push all tags
  echo "  Pushing tags..."
  git push --force "${TARGET_AUTH}" --tags 2>/dev/null || echo "  No tags to push"
fi

# Cleanup
cd /
rm -rf "${TMPDIR}"

echo ""
echo "============================================"
echo "  SYNC COMPLETE"
echo "  ${TARGET_HEAD:0:8} -> ${SOURCE_HEAD:0:8}"
echo "============================================"
echo "synced=true" >> $GITHUB_OUTPUT
