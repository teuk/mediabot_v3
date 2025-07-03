#!/bin/bash

# commit.sh — Commit helper for mediabot_v3

VERSION_FILE="VERSION"
DEFAULT_COMMIT_MSG="🔮 Commiting changes to mediabot_v3"

# Check git status
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "🧙‍♂️ Git changes detected:"
    git status -s
else
    echo "✨ Nothing to commit. Git is clean."
    exit 0
fi

# Extract version string
if [[ -f "$VERSION_FILE" ]]; then
    VERSION=$(cat "$VERSION_FILE")
else
    echo "⚠️ VERSION file not found!"
    VERSION="unknown"
fi

# Ask for commit message
read -rp "📜 Enter commit message (leave empty for default): " COMMIT_MSG

if [[ -z "$COMMIT_MSG" ]]; then
    COMMIT_MSG="$DEFAULT_COMMIT_MSG"
fi

FULL_MSG="🧙‍♀️ $COMMIT_MSG (version: $VERSION)"

# Stage all changes + VERSION
git add -A
git add "$VERSION_FILE"

# Do the commit
git commit -m "$FULL_MSG"

# Optional: display the last commit
echo -e "\n✅ Commit done! Here's what was committed:"
git --no-pager log -1
