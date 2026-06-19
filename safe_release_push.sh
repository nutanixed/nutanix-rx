#!/usr/bin/env bash
set -euo pipefail

# End-to-end safe release push helper.
# - Never rewrites local history.
# - Never force-pushes.
# - Refuses to push if local branch is behind remote.
# - Creates a new unique tag on every push.
#
# Usage:
#   ./safe_release_push.sh -m "Your commit message"
#   ./safe_release_push.sh -m "Your commit message" -r origin -b main -p v
#
# Notes:
# - Run from inside the target git repository.
# - This script stages all non-ignored changes before committing.

REMOTE="origin"
BRANCH="main"
TAG_PREFIX="v"
COMMIT_MESSAGE=""
DEFAULT_GIT_NAME="Ed Keiper"
DEFAULT_GIT_EMAIL="edward.keiper@nutanix.com"

usage() {
  cat <<'EOF'
Usage:
  ./safe_release_push.sh -m "Commit message" [-r remote] [-b branch] [-p tag_prefix]

Options:
  -m  Commit message (required)
  -r  Git remote name (default: origin)
  -b  Remote branch to push to (default: main)
  -p  Tag prefix (default: v)

Behavior:
  1) Validates repository and remote/branch state
  2) Refuses to proceed if local is behind remote
  3) Stages and commits all local non-ignored changes (if present)
  4) If no local changes, reuses current HEAD
  5) Creates a unique timestamped tag
  6) Pushes branch + tag (no force)
EOF
}

while getopts ":m:r:b:p:h" opt; do
  case "$opt" in
    m) COMMIT_MESSAGE="$OPTARG" ;;
    r) REMOTE="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    p) TAG_PREFIX="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$COMMIT_MESSAGE" ]]; then
  echo "Error: commit message is required (-m)." >&2
  usage
  exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Error: not inside a git repository." >&2
  exit 1
}

git remote get-url "$REMOTE" >/dev/null 2>&1 || {
  echo "Error: remote '$REMOTE' not found." >&2
  exit 1
}

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "Error: detached HEAD. Checkout a branch first." >&2
  exit 1
fi

echo "Fetching latest from $REMOTE/$BRANCH ..."
git fetch "$REMOTE" "$BRANCH"

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse "$REMOTE/$BRANCH")"
BASE="$(git merge-base HEAD "$REMOTE/$BRANCH")"

if [[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]]; then
  :
elif [[ "$BASE" == "$REMOTE_HEAD" ]]; then
  :
elif [[ "$BASE" == "$LOCAL_HEAD" ]]; then
  echo "Error: local branch is behind $REMOTE/$BRANCH. Pull/rebase first." >&2
  exit 1
else
  echo "Error: local and remote have diverged. Reconcile before pushing." >&2
  exit 1
fi

HAS_LOCAL_CHANGES="false"
if [[ -n "$(git status --porcelain)" ]]; then
  HAS_LOCAL_CHANGES="true"
fi

# Resolve git identity for commit + annotated tag.
# Priority:
# 1) SAFE_RELEASE_GIT_NAME / SAFE_RELEASE_GIT_EMAIL env vars
# 2) Existing git config user.name / user.email
# 3) Script defaults
#
# If user.name/email are missing in git config, set them locally for this repo.
GIT_NAME="${SAFE_RELEASE_GIT_NAME:-$(git config user.name || true)}"
GIT_EMAIL="${SAFE_RELEASE_GIT_EMAIL:-$(git config user.email || true)}"

if [[ -z "$GIT_NAME" ]]; then
  GIT_NAME="$DEFAULT_GIT_NAME"
  git config user.name "$GIT_NAME"
  echo "Configured local git user.name to '$GIT_NAME'"
fi
if [[ -z "$GIT_EMAIL" ]]; then
  GIT_EMAIL="$DEFAULT_GIT_EMAIL"
  git config user.email "$GIT_EMAIL"
  echo "Configured local git user.email to '$GIT_EMAIL'"
fi

echo "Using git identity: $GIT_NAME <$GIT_EMAIL>"
export GIT_AUTHOR_NAME="$GIT_NAME"
export GIT_AUTHOR_EMAIL="$GIT_EMAIL"
export GIT_COMMITTER_NAME="$GIT_NAME"
export GIT_COMMITTER_EMAIL="$GIT_EMAIL"

if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
  echo "Staging changes ..."
  git add -A

  if [[ -z "$(git diff --cached --name-only)" ]]; then
    echo "Nothing staged after git add -A. Aborting."
    exit 1
  fi

  echo "Creating commit ..."
  git commit -m "$COMMIT_MESSAGE"
else
  echo "No local changes detected; using current HEAD for release tag/push."
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TAG_NAME="${TAG_PREFIX}${TIMESTAMP}"

while git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; do
  sleep 1
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  TAG_NAME="${TAG_PREFIX}${TIMESTAMP}"
done

echo "Creating tag $TAG_NAME ..."
git tag -a "$TAG_NAME" -m "Release $TAG_NAME"

echo "Pushing branch $CURRENT_BRANCH -> $REMOTE/$BRANCH ..."
git push "$REMOTE" "$CURRENT_BRANCH:$BRANCH"

echo "Pushing tag $TAG_NAME ..."
git push "$REMOTE" "$TAG_NAME"

echo "Done."
echo "Remote: $REMOTE"
echo "Branch: $BRANCH"
echo "Tag:    $TAG_NAME"
