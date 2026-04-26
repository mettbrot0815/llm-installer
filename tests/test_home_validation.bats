@test "HOME validation - valid HOME" {
  HOME=$HOME timeout 5 bash install.sh 2>&1 | grep -q "Sudo access is required"
}

@test "HOME validation - invalid HOME" {
  touch fakehome
  HOME=./fakehome timeout 5 bash install.sh 2>&1 | grep -q "cannot create directory"
}