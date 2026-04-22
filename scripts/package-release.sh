#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Environment variable $name is required" >&2
    exit 1
  fi
}

package_root() {
  require_env PACKAGE_DIR

  if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
    printf '%s\n' "$GITHUB_WORKSPACE/$PACKAGE_DIR"
  else
    printf '%s\n' "$PACKAGE_DIR"
  fi
}

parse_tag_version() {
  local latest_tag="$1"

  if [[ -n "${TAG_PREFIX:-}" && "$latest_tag" == "$TAG_PREFIX"* ]]; then
    printf '%s\n' "${latest_tag#$TAG_PREFIX}"
    return
  fi

  if [[ "$latest_tag" == v* ]]; then
    printf '%s\n' "${latest_tag#v}"
    return
  fi

  printf '%s\n' "$latest_tag"
}

detect_latest() {
  require_env UPSTREAM_REPO

  local pkgbuild_path current_version latest_tag latest_version has_update
  pkgbuild_path="$(package_root)/PKGBUILD"
  current_version="$(sed -n 's/^pkgver=//p' "$pkgbuild_path" | head -n1)"
  latest_tag="$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" | jq -r '.tag_name')"

  if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
    echo "Failed to retrieve the latest upstream tag" >&2
    exit 1
  fi

  latest_version="$(parse_tag_version "$latest_tag")"
  if [[ ! "$latest_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Unexpected upstream tag format: $latest_tag" >&2
    exit 1
  fi

  if [[ "$current_version" == "$latest_version" ]]; then
    has_update=false
  else
    has_update=true
  fi

  printf 'current_version=%s\n' "$current_version"
  printf 'latest_tag=%s\n' "$latest_tag"
  printf 'latest_version=%s\n' "$latest_version"
  printf 'has_update=%s\n' "$has_update"
}

collect_dependency_names() {
  local pkgbuild_path="$1"

  bash -lc '
    set -euo pipefail
    source "$1"

    for array_name in depends makedepends checkdepends; do
      if declare -p "$array_name" >/dev/null 2>&1; then
        eval "for value in \"\${${array_name}[@]}\"; do printf \"%s\\n\" \"\$value\"; done"
      fi
    done
  ' bash "$pkgbuild_path" | awk 'NF && !seen[$0]++'
}

install_build_deps() {
  local pkgbuild_path
  local -a deps

  pkgbuild_path="$(package_root)/PKGBUILD"
  mapfile -t deps < <(collect_dependency_names "$pkgbuild_path")

  if (( ${#deps[@]} == 0 )); then
    echo "No package-specific dependencies to install."
    return
  fi

  pacman -S --noconfirm --needed "${deps[@]}"
}

update_package() {
  require_env LATEST_VERSION

  local pkg_root
  pkg_root="$(package_root)"
  cd "$pkg_root"

  sed -i -E "s/^pkgver=.*/pkgver=${LATEST_VERSION}/" PKGBUILD
  sed -i -E "s/^pkgrel=.*/pkgrel=1/" PKGBUILD

  updpkgsums
  makepkg --printsrcinfo > .SRCINFO
}

build_package() {
  local pkg_root
  pkg_root="$(package_root)"
  cd "$pkg_root"

  makepkg -f --nodeps
}

configure_ssh() {
  require_env SSH_PRIVATE_KEY

  install -d -m 700 "$HOME/.ssh"
  printf '%s\n' "$SSH_PRIVATE_KEY" > "$HOME/.ssh/aur"
  chmod 600 "$HOME/.ssh/aur"

  if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" > "$HOME/.ssh/known_hosts"
  else
    ssh-keyscan aur.archlinux.org > "$HOME/.ssh/known_hosts"
  fi

  printf '%s\n' \
    "Host aur.archlinux.org" \
    "  User aur" \
    "  IdentityFile ~/.ssh/aur" \
    "  IdentitiesOnly yes" \
    "  StrictHostKeyChecking yes" \
    > "$HOME/.ssh/config"

  chmod 600 "$HOME/.ssh/config" "$HOME/.ssh/known_hosts"
}

push_aur() {
  require_env GITHUB_WORKSPACE
  require_env AUR_REMOTE_URL
  require_env AUR_TARGET_BRANCH
  require_env LATEST_VERSION

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT

  git clone "$AUR_REMOTE_URL" "$workdir/aur"
  find "$workdir/aur" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

  while IFS= read -r file; do
    local relative_path
    relative_path="${file#${PACKAGE_DIR}/}"

    mkdir -p "$workdir/aur/$(dirname "$relative_path")"
    cp "$GITHUB_WORKSPACE/$file" "$workdir/aur/$relative_path"
  done < <(git -C "$GITHUB_WORKSPACE" ls-files "$PACKAGE_DIR")

  cd "$workdir/aur"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  git add -A
  if git diff --cached --quiet; then
    echo "No AUR metadata changes to push."
    return
  fi

  git commit -m "Update to ${LATEST_VERSION}"
  GIT_SSH_COMMAND="ssh -F $HOME/.ssh/config" git push origin HEAD:"${AUR_TARGET_BRANCH}"
}

push_github() {
  require_env GITHUB_WORKSPACE
  require_env GITHUB_TARGET_BRANCH
  require_env PACKAGE_NAME
  require_env LATEST_VERSION

  git config --global --add safe.directory "$GITHUB_WORKSPACE"
  cd "$GITHUB_WORKSPACE"

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  git add "$PACKAGE_DIR"
  if git diff --cached --quiet; then
    echo "No GitHub metadata changes to push."
    return
  fi

  git commit -m "${PACKAGE_NAME}: update to ${LATEST_VERSION}"
  git push origin HEAD:"${GITHUB_TARGET_BRANCH}"
}

main() {
  if (( $# != 1 )); then
    echo "Usage: $0 <detect-latest|install-build-deps|update-package|build-package|configure-ssh|push-aur|push-github>" >&2
    exit 1
  fi

  case "$1" in
    detect-latest) detect_latest ;;
    install-build-deps) install_build_deps ;;
    update-package) update_package ;;
    build-package) build_package ;;
    configure-ssh) configure_ssh ;;
    push-aur) push_aur ;;
    push-github) push_github ;;
    *)
      echo "Unknown command: $1" >&2
      exit 1
      ;;
  esac
}

main "$@"
