#!/usr/bin/env bats

load 'test_helper.bash' 2>/dev/null || true

# Helper: run git check-ignore against repo root .gitignore
check_ignored() {
  local path="$1"
  git check-ignore -n -- "$path" >/dev/null 2>&1
}

# Helper: assert that a path is ignored
assert_ignored() {
  local path="$1"
  if ! git check-ignore -n -- "$path" >/dev/null 2>&1; then
    echo "Expected '$path' to be ignored by .gitignore"
    echo "git check-ignore -n -- $path output:"
    git check-ignore -n -- "$path" || true
    return 1
  fi
}

# Helper: assert that a path is NOT ignored
assert_not_ignored() {
  local path="$1"
  if git check-ignore -n -- "$path" >/dev/null 2>&1; then
    echo "Expected '$path' to NOT be ignored by .gitignore"
    echo "git check-ignore -n -- $path output:"
    git check-ignore -n -- "$path" || true
    return 1
  fi
}

setup() {
  # Each test creates its own temp area to avoid polluting repo
  TMPDIR="$(mktemp -d -t gitignore-bats.XXXXXX)"
  export TMPDIR
  # Create representative files/dirs relative to repo root
  # We will create them in-place under repo to ensure .gitignore at root applies.
  touch ./.terraform.lock.hcl 2>/dev/null || :
}

teardown() {
  # Clean up files created by tests if they exist
  # Use rm -rf guarded by patterns we created
  rm -rf .terraform .terraform/dir 2>/dev/null || true
  rm -rf terraform.tfstate terraform.tfstate.backup terraform.tfvars 2>/dev/null || true
  rm -rf crash.log 2>/dev/null || true
  rm -rf override.tf override.tf.json 2>/dev/null || true
  rm -rf backend.hcl 2>/dev/null || true
  rm -rf .aws 2>/dev/null || true
  rm -rf .DS_Store Thumbs.db ehthumbs.db 2>/dev/null || true
  rm -rf file.log file.tmp 2>/dev/null || true
  rm -rf secret.pem 2>/dev/null || true
  rm -rf .vscode 2>/dev/null || true
  rm -rf test.csv report.csv 2>/dev/null || true
  rm -rf foo.auto.tfvars 2>/dev/null || true
}

# ----------------------------
# Terraform-related ignores
# ----------------------------

@test "[Terraform] .terraform/ directory is ignored" {
  mkdir -p .terraform/dir
  run git check-ignore -n -- ".terraform/dir/file.txt"
  [ "$status" -eq 0 ]
}

@test "[Terraform] *.tfstate files are ignored" {
  touch terraform.tfstate
  run git check-ignore -n -- "terraform.tfstate"
  [ "$status" -eq 0 ]

  touch "state.tfstate"
  run git check-ignore -n -- "state.tfstate"
  [ "$status" -eq 0 ]
}

@test "[Terraform] *.tfstate.* files are ignored (e.g., backups)" {
  touch "terraform.tfstate.backup"
  run git check-ignore -n -- "terraform.tfstate.backup"
  [ "$status" -eq 0 ]

  touch "env.tfstate.12345"
  run git check-ignore -n -- "env.tfstate.12345"
  [ "$status" -eq 0 ]
}

@test "[Terraform] *.tfvars and terraform.tfvars are ignored" {
  touch "terraform.tfvars"
  run git check-ignore -n -- "terraform.tfvars"
  [ "$status" -eq 0 ]

  touch "production.tfvars"
  run git check-ignore -n -- "production.tfvars"
  [ "$status" -eq 0 ]
}

@test "[Terraform] *.auto.tfvars are ignored" {
  touch "foo.auto.tfvars"
  run git check-ignore -n -- "foo.auto.tfvars"
  [ "$status" -eq 0 ]
}

@test "[Terraform] .terraform (no trailing slash) pattern also covers directory" {
  mkdir -p ".terraform"
  run git check-ignore -n -- ".terraform"
  [ "$status" -eq 0 ]
}

@test "[Terraform] crash.log is ignored" {
  touch "crash.log"
  run git check-ignore -n -- "crash.log"
  [ "$status" -eq 0 ]
}

@test "[Terraform] override.tf and override.tf.json are ignored" {
  touch "override.tf" "override.tf.json"
  run git check-ignore -n -- "override.tf"
  [ "$status" -eq 0 ]
  run git check-ignore -n -- "override.tf.json"
  [ "$status" -eq 0 ]
}

@test "[Terraform] CSV exports (*.csv) are ignored" {
  touch "report.csv" "test.csv"
  run git check-ignore -n -- "report.csv"
  [ "$status" -eq 0 ]
  run git check-ignore -n -- "test.csv"
  [ "$status" -eq 0 ]
}

# ----------------------------
# AWS CLI credentials
# ----------------------------

@test "[AWS] .aws/ directory is ignored" {
  mkdir -p ".aws"
  run git check-ignore -n -- ".aws/config"
  [ "$status" -eq 0 ]
}

@test "[AWS] literal '~/.aws/' path should not match repo files (negative test)" {
  # The pattern '~/.aws/' in .gitignore would normally not ignore a file inside repo.
  # Ensure a file named '~/.aws/creds' in repo is not mistakenly ignored.
  mkdir -p "./~/.aws"
  touch "./~/.aws/creds"
  run git check-ignore -n -- "./~/.aws/creds"
  [ "$status" -ne 0 ]
}

# ----------------------------
# OS-generated files
# ----------------------------

@test "[OS] macOS .DS_Store is ignored" {
  touch ".DS_Store"
  run git check-ignore -n -- ".DS_Store"
  [ "$status" -eq 0 ]
}

@test "[OS] Windows Thumbs.db and ehthumbs.db are ignored" {
  touch "Thumbs.db" "ehthumbs.db"
  run git check-ignore -n -- "Thumbs.db"
  [ "$status" -eq 0 ]
  run git check-ignore -n -- "ehthumbs.db"
  [ "$status" -eq 0 ]
}

@test "[OS] *.log and *.tmp files are ignored" {
  touch "file.log" "file.tmp"
  run git check-ignore -n -- "file.log"
  [ "$status" -eq 0 ]
  run git check-ignore -n -- "file.tmp"
  [ "$status" -eq 0 ]
}

# ----------------------------
# SSH keys and backend config
# ----------------------------

@test "[Security] *.pem private keys are ignored" {
  touch "secret.pem"
  run git check-ignore -n -- "secret.pem"
  [ "$status" -eq 0 ]
}

@test "[Terraform] backend.hcl is ignored" {
  touch "backend.hcl"
  run git check-ignore -n -- "backend.hcl"
  [ "$status" -eq 0 ]
}

# ----------------------------
# VSCode
# ----------------------------

@test "[Tooling] .vscode/ directory is ignored" {
  mkdir -p ".vscode"
  run git check-ignore -n -- ".vscode/settings.json"
  [ "$status" -eq 0 ]
}

# ----------------------------
# Negative/edge cases to avoid over-matching
# ----------------------------

@test "[Negative] A file named terraform.tf (not listed) is NOT ignored" {
  touch "terraform.tf"
  run git check-ignore -n -- "terraform.tf"
  [ "$status" -ne 0 ]
}

@test "[Negative] A file named notes.tmp.md should NOT be ignored (only *.tmp exact extension)" {
  touch "notes.tmp.md"
  run git check-ignore -n -- "notes.tmp.md"
  [ "$status" -ne 0 ]
}

@test "[Negative] A file named mytfstate.txt is NOT ignored" {
  touch "mytfstate.txt"
  run git check-ignore -n -- "mytfstate.txt"
  [ "$status" -ne 0 ]
}
