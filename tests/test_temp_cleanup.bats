@test "temp cleanup on exit" {
  # Define the functions
  TMPFILES=()
  register_tmp() { TMPFILES+=("$1"); }
  cleanup() {
    local f
    for f in "${TMPFILES[@]}"; do
      [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
  }

  # Create a temp file
  local tmpfile
  tmpfile=$(mktemp /tmp/test_cleanup.XXXXXX)
  register_tmp "$tmpfile"
  echo "test" > "$tmpfile"

  # Simulate exit
  cleanup

  # Check if file is removed
  [ ! -f "$tmpfile" ]
}