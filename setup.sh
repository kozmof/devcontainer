#!/usr/bin/env bash
# Usage: setup.sh [TARGET_DIR]
#
#   Clone this repository, then run this script to place .devcontainer
#   at the root of your project.
#
#   TARGET_DIR  Directory to install .devcontainer into (default: current directory)
#
# Example:
#   git clone <this-repo> /tmp/devcontainer-with-claude
#   /tmp/devcontainer-with-claude/setup.sh /path/to/your/project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: target directory '$TARGET_DIR' does not exist." >&2
  exit 1
fi

if [ -e "$TARGET_DIR/.devcontainer" ]; then
  echo "Error: '$TARGET_DIR/.devcontainer' already exists." >&2
  exit 1
fi

cp -r "$SCRIPT_DIR/.devcontainer" "$TARGET_DIR/.devcontainer"
echo "Placed .devcontainer at $TARGET_DIR/.devcontainer"
