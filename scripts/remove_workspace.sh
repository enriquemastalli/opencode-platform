#!/bin/bash
set -e

WORKSPACE_NAME=$1
PROJECT_NAME=${2:-"opencode-platform"}

if [ -z "$WORKSPACE_NAME" ]; then
    echo "Usage: $0 <workspace_name> [project_name]"
    exit 1
fi

REPO_DIR="/srv/repos/$PROJECT_NAME"
WORKSPACES_DIR="/srv/workspaces"
TARGET_DIR="$WORKSPACES_DIR/$WORKSPACE_NAME"

if [ ! -d "$REPO_DIR" ]; then
    echo "Error: Base repository $REPO_DIR does not exist."
    exit 1
fi

echo "Removing workspace $WORKSPACE_NAME..."

cd "$REPO_DIR"

# Clean up worktree
if [ -d "$TARGET_DIR" ]; then
    git worktree remove -f "$TARGET_DIR"
else
    echo "Worktree directory not found, cleaning up git database..."
    git worktree prune
fi

# Optionally, delete the branch too
git branch -D "$WORKSPACE_NAME" || true

echo "Workspace $WORKSPACE_NAME removed."
