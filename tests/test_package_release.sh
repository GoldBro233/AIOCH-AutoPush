#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

configure_git_identity() {
  local repo="$1"

  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config commit.gpgsign false
}

create_git_workspace() {
  local workspace="$1"

  mkdir -p "$workspace/packages/aio-coding-hub-bin"
  cp packages/aio-coding-hub-bin/PKGBUILD "$workspace/packages/aio-coding-hub-bin/PKGBUILD"
  cp packages/aio-coding-hub-bin/.SRCINFO "$workspace/packages/aio-coding-hub-bin/.SRCINFO"

  git -C "$workspace" init -q
  configure_git_identity "$workspace"
  git -C "$workspace" add .
  git -C "$workspace" commit -q -m "Initial package metadata"
}

create_aur_remote_with_matching_metadata() {
  local workspace="$1"
  local aur_worktree="$2"
  local aur_remote="$3"

  git init --bare -q "$aur_remote"
  git -C "$aur_worktree" init -q
  configure_git_identity "$aur_worktree"

  cp "$workspace/packages/aio-coding-hub-bin/PKGBUILD" "$aur_worktree/PKGBUILD"
  cp "$workspace/packages/aio-coding-hub-bin/.SRCINFO" "$aur_worktree/.SRCINFO"

  git -C "$aur_worktree" add .
  git -C "$aur_worktree" commit -q -m "Initial AUR metadata"
  git -C "$aur_worktree" remote add origin "$aur_remote"
  git -C "$aur_worktree" push -q origin HEAD:master
  git --git-dir="$aur_remote" symbolic-ref HEAD refs/heads/master
}

assert_contains() {
  local path="$1"
  local pattern="$2"

  grep -Fq "$pattern" "$path" || {
    echo "Expected '$pattern' in $path" >&2
    exit 1
  }
}

test_push_aur_no_diff_exits_successfully() {
  local workspace="$tmpdir/workspace"
  local aur_worktree="$tmpdir/aur-worktree"
  local aur_remote="$tmpdir/aur.git"
  local output="$tmpdir/push-aur.out"

  mkdir -p "$workspace" "$aur_worktree"
  create_git_workspace "$workspace"
  create_aur_remote_with_matching_metadata "$workspace" "$aur_worktree" "$aur_remote"

  if ! GIT_CONFIG_GLOBAL="/dev/null" \
    GIT_CONFIG_NOSYSTEM="1" \
    GITHUB_WORKSPACE="$workspace" \
    PACKAGE_DIR="packages/aio-coding-hub-bin" \
    AUR_REMOTE_URL="$aur_remote" \
    AUR_TARGET_BRANCH="master" \
    LATEST_VERSION="0.40.8" \
    scripts/package-release.sh push-aur >"$output" 2>&1; then
    cat "$output" >&2
    exit 1
  fi

  assert_contains "$output" "No AUR metadata changes to push."
}

test_push_aur_no_diff_exits_successfully
