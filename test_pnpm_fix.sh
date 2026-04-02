#!/bin/bash
# Test script to verify pnpm installation fix

echo "=== Testing pnpm installation fix ==="

# Simulate Windows npm in PATH (like the user's environment)
export PATH="/mnt/c/Users/Philipp/.npm-global:$PATH"

echo "Simulated PATH with Windows npm:"
echo "$PATH" | tr ':' '\n' | grep "/mnt" || echo "No /mnt paths"

# Test the cleanup logic from the install script
if [[ -d "/mnt/c/Users/${USER}/.npm-global" ]]; then
    echo "Found Windows npm global installation — removing from PATH to avoid conflicts"
    # Create new PATH without Windows npm-global
    NEW_PATH=""
    IFS=':' read -ra PATH_ARRAY <<< "$PATH"
    for path_entry in "${PATH_ARRAY[@]}"; do
        if [[ "$path_entry" != *"/mnt/c/Users/${USER}/.npm-global"* ]]; then
            if [[ -z "$NEW_PATH" ]]; then
                NEW_PATH="$path_entry"
            else
                NEW_PATH="$NEW_PATH:$path_entry"
            fi
        fi
    done
    export PATH="$NEW_PATH"
    echo "Windows npm-global removed from PATH"
fi

echo "Cleaned PATH:"
echo "$PATH" | tr ':' '\n' | grep "/mnt" || echo "No /mnt paths remaining"

echo "=== Test complete ==="
