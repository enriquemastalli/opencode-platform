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

if [ -d "$TARGET_DIR" ]; then
    echo "Error: Workspace $WORKSPACE_NAME already exists."
    exit 1
fi

echo "Creating workspace $WORKSPACE_NAME..."

cd "$REPO_DIR"

# Ensure origin/main is up to date
git fetch origin

# Create a worktree with a new branch tracking origin/main (or just a new branch based on main)
git worktree add -b "$WORKSPACE_NAME" "$TARGET_DIR" origin/main

echo "Workspace created at $TARGET_DIR"
