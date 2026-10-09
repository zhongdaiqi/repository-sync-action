#!/usr/bin/env bash
set -euo pipefail

SOURCE="${SOURCE_GIT_URL}"
TARGET="${TARGET_GIT_URL}"
TOKEN="${TARGET_GIT_TOKEN}"
SOURCE_TOKEN="${SOURCE_GIT_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"

# Inject tokens into URLs
# Target: https://github.com/user/repo.git -> https://x-access-token:TOKEN@github.com/user/repo.git
TARGET_AUTH=$(echo "${TARGET}" | sed "s|https://|https://x-access-token:${TOKEN}@|")

if [ -n "${SOURCE_TOKEN}" ]; then
  SOURCE_AUTH=$(echo "${SOURCE}" | sed "s|https://|https://x-access-token:${SOURCE_TOKEN}@|")
else
  SOURCE_AUTH="${SOURCE}"
fi

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

echo "Pushing to target (mirror)..."
cd "${TMPDIR}/repo.git"

# First try: mirror push (fast path)
if git push --mirror "${TARGET_AUTH}" 2>&1; then
  echo "Mirror push succeeded."
else
  echo "Mirror push failed (may exceed 2GB limit). Falling back to batch push..."

  # Get all branches from source
  BRANCHES=$(git for-each-ref --format='%(refname:short)' refs/heads/)

  for BRANCH in ${BRANCHES}; do
    echo "  Syncing branch: ${BRANCH}"

    # Get total commits count
    TOTAL=$(git rev-list --count "refs/heads/${BRANCH}" 2>/dev/null || echo 0)
    echo "    Total commits: ${TOTAL}"

    if [ "${TOTAL}" -gt 500 ]; then
      # Batch push: every 500 commits
      ANCHORS=$(git rev-list --reverse "refs/heads/${BRANCH}" | awk 'NR % 500 == 0 || NR == 1')
      for SHA in ${ANCHORS}; do
        echo "    Pushing batch up to ${SHA:0:8}..."
        git push "${TARGET_AUTH}" "${SHA}:refs/heads/${BRANCH}" || {
          echo "    Batch failed, trying smaller batches..."
          # Fallback: push 100 at a time
          SMALLER=$(git rev-list --reverse "${SHA}~50..${SHA}" 2>/dev/null | awk 'NR % 50 == 0 || NR == 1')
          for SSHA in ${SMALLER}; do
            git push "${TARGET_AUTH}" "${SSHA}:refs/heads/${BRANCH}" && echo "    Small batch OK" || echo "    Small batch FAILED"
          done
        }
      done
    else
      # Small branch: push all at once
      git push "${TARGET_AUTH}" "refs/heads/${BRANCH}:refs/heads/${BRANCH}"
    fi
  done

  # Push all tags
  echo "  Pushing tags..."
  git push "${TARGET_AUTH}" --tags 2>/dev/null || echo "  No tags to push"
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
