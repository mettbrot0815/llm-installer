#!/usr/bin/env bash
set -euo pipefail

echo "Testing syntax..."

# Simple function test
test_function() {
    local var="test"
    if [[ "$var" == "test" ]]; then
        echo "Function works"
    else
        echo "Function broken"
    fi
}

# Test heredoc
test_heredoc() {
    cat << INNER_EOF
This is a test heredoc
with multiple lines
INNER_EOF
}

test_function
test_heredoc

echo "✅ All syntax tests passed"
