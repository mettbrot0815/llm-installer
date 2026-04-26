@test "piped install security" {
  echo "" | timeout 10 bash install.sh 2>&1 | grep -q "Sudo access is required"
}