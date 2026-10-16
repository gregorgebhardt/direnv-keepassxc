#!/bin/bash
# Installs direnv-keepassxc, updates it to the latest release, or removes it.
#
#   curl -fsSL https://raw.githubusercontent.com/gregorgebhardt/direnv-keepassxc/main/install.sh | bash
#   install.sh [--version <tag>|main] [--database <path>]
#   install.sh --uninstall
#
# Clones the repository to DIRENV_KEEPASSXC_DIR (default ~/.local/share/direnv-keepassxc) and
# links keepass.sh into direnv's lib folder and keepass-forget into DIRENV_KEEPASSXC_BIN
# (default ~/.local/bin). It never replaces files it didn't create. DIRENV_KEEPASSXC_REPO
# installs from another repository, such as a fork.

# Everything runs inside main, so a partly downloaded script can't run.
main() {
  set -euo pipefail

  REPO=${DIRENV_KEEPASSXC_REPO:-https://github.com/gregorgebhardt/direnv-keepassxc.git}
  CLONE_DIR=${DIRENV_KEEPASSXC_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/direnv-keepassxc}
  BIN_DIR=${DIRENV_KEEPASSXC_BIN:-$HOME/.local/bin}
  CONFIG_DIR=${DIRENV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/direnv}
  LIB_LINK=$CONFIG_DIR/lib/keepass.sh
  BIN_LINK=$BIN_DIR/keepass-forget

  local uninstall='' version='' database='' first_install=''
  while (($# > 0)); do
    case $1 in
      --uninstall) uninstall=1 ;;
      --version | --database)
        (($# > 1)) || die "$1 needs a value"
        if [[ $1 == --version ]]; then version=$2; else database=$2; fi
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *) die "unknown option $1; see --help" ;;
    esac
    shift
  done

  if [[ -n $uninstall ]]; then
    uninstall
    return 0
  fi

  check_requirements
  can_link "$CLONE_DIR/keepass.sh" "$LIB_LINK"
  can_link "$CLONE_DIR/bin/keepass-forget" "$BIN_LINK"
  [[ -e $CLONE_DIR ]] || first_install=1

  sync_clone "$version"
  link "$CLONE_DIR/keepass.sh" "$LIB_LINK"
  link "$CLONE_DIR/bin/keepass-forget" "$BIN_LINK"
  configure_database "$database"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) note "$(pretty "$BIN_DIR") isn't on your PATH, so neither is keepass-forget" ;;
  esac
  if [[ -n $first_install ]]; then
    say "Next: add lines like  use_keepass 'API Keys/GitHub' GITHUB_TOKEN  to an .envrc."
  fi
}

usage() {
  cat <<'EOF'
Usage: install.sh [--version <tag>|main] [--database <path>]
       install.sh --uninstall

Installs direnv-keepassxc, or updates it to the latest release if it's already installed.

  --version <tag>|main  install this release, or the latest commit on main
  --database <path>     your .kdbx file, saved as KEEPASS_DATABASE in your direnvrc
  --uninstall           remove the links and the clone

DIRENV_KEEPASSXC_DIR and DIRENV_KEEPASSXC_BIN change where the clone
(~/.local/share/direnv-keepassxc) and keepass-forget (~/.local/bin) go.
EOF
}

say() { printf '%s\n' "$*"; }
note() { printf 'Note: %s\n' "$*" >&2; }
die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# Shows paths below your home folder as ~/...
pretty() {
  # shellcheck disable=SC2088 # the tilde is only displayed
  case $1 in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

check_requirements() {
  command -v git >/dev/null || die "git is required"
  [[ $(uname -s) == Darwin ]] ||
    note "use_keepass only works on macOS, because it keeps the master password in the Keychain"
  command -v direnv >/dev/null || note "direnv isn't installed yet: https://direnv.net"
  if ! command -v keepassxc-cli >/dev/null && [[ ! -d /Applications/KeePassXC.app ]]; then
    note "KeePassXC isn't installed yet: https://keepassxc.org"
  fi
}

# Fails unless name is missing or already the link we would create.
can_link() {
  local target=$1 name=$2
  if [[ -L $name && $(readlink "$name") == "$target" ]] || [[ ! -e $name && ! -L $name ]]; then
    return 0
  fi
  die "$(pretty "$name") already exists and wasn't created by this installer; move it away and run the installer again"
}

link() {
  local target=$1 name=$2
  [[ ! -L $name ]] || return 0
  mkdir -p "$(dirname "$name")"
  ln -s "$target" "$name"
  say "Linked $(pretty "$name")."
}

is_our_clone() {
  local url
  [[ -d $CLONE_DIR/.git ]] || return 1
  url=$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null) || return 1
  [[ ${url%.git} == "${REPO%.git}" ]]
}

current_version() {
  git -C "$CLONE_DIR" describe --tags --exact-match HEAD 2>/dev/null ||
    git -C "$CLONE_DIR" rev-parse --short HEAD
}

# Clones or fetches, then checks out the wanted version (default: the latest v* release).
sync_clone() {
  local wanted=$1 before='' after tags ref

  if [[ -e $CLONE_DIR ]]; then
    is_our_clone || die "$(pretty "$CLONE_DIR") exists but isn't a clone of $REPO"
    [[ -z $(git -C "$CLONE_DIR" status --porcelain --untracked-files=no) ]] ||
      die "$(pretty "$CLONE_DIR") has local changes; undo them and run the installer again"
    before=$(current_version)
    git -C "$CLONE_DIR" fetch --quiet --tags --force origin
  else
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone --quiet "$REPO" "$CLONE_DIR"
  fi

  if [[ -z $wanted ]]; then
    tags=$(git -C "$CLONE_DIR" tag --list 'v*' --sort=-v:refname)
    wanted=${tags%%$'\n'*}
    [[ -n $wanted ]] || wanted=main
  fi
  if [[ $wanted == main ]]; then
    ref=origin/main
  else
    ref=refs/tags/$wanted
  fi
  if ! git -C "$CLONE_DIR" rev-parse --quiet --verify "$ref^{commit}" >/dev/null; then
    [[ -n $before ]] || rm -rf "$CLONE_DIR"
    die "there's no version $wanted"
  fi
  git -C "$CLONE_DIR" -c advice.detachedHead=false checkout --quiet "$ref"

  after=$(current_version)
  if [[ -z $before ]]; then
    say "Installed direnv-keepassxc $after in $(pretty "$CLONE_DIR")."
  elif [[ $before == "$after" ]]; then
    say "direnv-keepassxc $after is up to date."
  else
    say "Switched direnv-keepassxc from $before to $after."
  fi
}

# direnv reads the config folder's direnvrc, or ~/.direnvrc if that doesn't exist.
direnvrc_path() {
  if [[ -f $CONFIG_DIR/direnvrc || ! -f $HOME/.direnvrc ]]; then
    printf '%s' "$CONFIG_DIR/direnvrc"
  else
    printf '%s' "$HOME/.direnvrc"
  fi
}

# Double-quotes a path for direnvrc, writing $HOME instead of the home folder.
quote_path() {
  local path=$1 prefix=''
  if [[ $path == "$HOME"/* ]]; then
    # shellcheck disable=SC2016 # $HOME is meant to be written literally
    prefix='$HOME/'
    path=${path#"$HOME"/}
  fi
  path=${path//\\/\\\\}
  path=${path//\"/\\\"}
  path=${path//\$/\\\$}
  path=${path//\`/\\\`}
  printf '"%s%s"' "$prefix" "$path"
}

# Asks only when someone can answer: stderr is a terminal and /dev/tty can be opened.
interactive() {
  [[ -t 2 ]] && (: </dev/tty) 2>/dev/null
}

configure_database() {
  local database=$1 rc separator=''

  rc=$(direnvrc_path)
  if [[ -f $rc ]] && grep -qE '^[[:space:]]*(export[[:space:]]+)?KEEPASS_DATABASE=' "$rc"; then
    [[ -z $database ]] || note "KEEPASS_DATABASE is already set in $(pretty "$rc"); change it there"
    return 0
  fi
  if [[ -z $database ]]; then
    [[ -z ${KEEPASS_DATABASE:-} ]] || return 0
    if interactive; then
      printf 'KeePass database (.kdbx) to use (empty to skip): ' >/dev/tty
      IFS= read -r database </dev/tty || database=''
    fi
    if [[ -z $database ]]; then
      note "set KEEPASS_DATABASE to your .kdbx file in $(pretty "$rc")"
      return 0
    fi
  fi

  case $database in
    "~"/*) database=$HOME/${database#"~"/} ;;
    /*) ;;
    *) database=$PWD/$database ;;
  esac
  [[ -f $database ]] || note "$(pretty "$database") doesn't exist (yet)"
  mkdir -p "$(dirname "$rc")"
  [[ ! -s $rc ]] || separator=$'\n'
  printf '%s# direnv-keepassxc: the KeePass database use_keepass reads\nKEEPASS_DATABASE=%s\n' \
    "$separator" "$(quote_path "$database")" >>"$rc"
  say "Saved KEEPASS_DATABASE in $(pretty "$rc")."
}

uninstall() {
  local removed=''

  if [[ -L $LIB_LINK && $(readlink "$LIB_LINK") == "$CLONE_DIR/keepass.sh" ]]; then
    rm "$LIB_LINK"
    say "Removed $(pretty "$LIB_LINK")."
    removed=1
  fi
  if [[ -L $BIN_LINK && $(readlink "$BIN_LINK") == "$CLONE_DIR/bin/keepass-forget" ]]; then
    rm "$BIN_LINK"
    say "Removed $(pretty "$BIN_LINK")."
    removed=1
  fi
  if is_our_clone && [[ $CLONE_DIR != "$HOME" && $CLONE_DIR != / ]]; then
    rm -rf "$CLONE_DIR"
    say "Removed $(pretty "$CLONE_DIR")."
    removed=1
  fi

  if [[ -z $removed ]]; then
    say "Nothing to remove."
    return 0
  fi
  say "Your direnvrc settings and the master password in your Keychain are still there. To remove the password:"
  say "  security delete-generic-password -s keepass-master -a \"\$USER\""
}

main "$@"; exit
