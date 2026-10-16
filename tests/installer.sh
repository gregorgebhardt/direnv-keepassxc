#!/bin/bash
# shellcheck disable=SC2016,SC2088 # expected output contains a literal $HOME and ~/
#
# Tests for install.sh. Builds a local origin with test releases from the working tree and
# installs into throwaway home folders; nothing outside them is touched. Needs git, direnv
# and expect.
#
#   tests/installer.sh
#   INSTALL_BASH=/opt/homebrew/bin/bash tests/installer.sh   # run install.sh with another bash
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_BASH=${INSTALL_BASH:-/bin/bash}

for tool in git direnv expect; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

# Physical path: direnv doesn't match an .envrc allowed via /var/... when it runs from /private/var/...
T=$(mktemp -d "${TMPDIR:-/tmp}/direnv-keepassxc-installer.XXXXXX") && T=$(cd "$T" && pwd -P) || exit 1
trap 'rm -rf "$T"' EXIT
pass=0
fail=0

# --- a local origin: v0.1.0, v0.2.0, then one unreleased commit on main --------------

ORIGIN=$T/origin.git
work=$T/work
g() { git -C "$work" -c user.name=tests -c user.email=tests@localhost -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
mkdir -p "$work"
cp -R "$REPO/." "$work/"
rm -rf "$work/.git"
git init -q -b main "$work"
g add -A && g commit -qm one && g tag v0.1.0
echo 2 >"$work/RELEASE" && g add -A && g commit -qm two && g tag v0.2.0
echo 3 >"$work/RELEASE" && g add -A && g commit -qm three
git clone -q --bare "$work" "$ORIGIN"
MAIN_SHA=$(git -C "$ORIGIN" rev-parse --short main)

# --- helpers -------------------------------------------------------------------------

install_in() { # home [args...] -> output, without a terminal
  local home=$1
  shift
  env -i HOME="$home" PATH="$PATH" DIRENV_KEEPASSXC_REPO="$ORIGIN" \
    "$INSTALL_BASH" "$REPO/install.sh" "$@" </dev/null 2>&1
}
exists() { [[ -e $1 || -L $1 ]] && echo yes || echo no; }

check() { # description command...
  if "${@:2}"; then
    printf '  PASS %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$1"
    fail=$((fail + 1))
  fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
equals() { [[ $1 == "$2" ]]; }

echo "install.sh runs with: $("$INSTALL_BASH" -c 'echo "$BASH_VERSION"')"

# --- tests ---------------------------------------------------------------------------

H1=$T/home1
CLONE1=$H1/.local/share/direnv-keepassxc

echo "I01 fresh install with --database"
out=$(install_in "$H1" --database "$H1/Documents/Pass words (x) \$y.kdbx")
check "installs the latest release" has "$out" "Installed direnv-keepassxc v0.2.0 in ~/.local/share/direnv-keepassxc."
check "clone is at v0.2.0" equals "$(git -C "$CLONE1" describe --tags --exact-match)" v0.2.0
check "links the library" equals "$(readlink "$H1/.config/direnv/lib/keepass.sh")" "$CLONE1/keepass.sh"
check "links keepass-forget" equals "$(readlink "$H1/.local/bin/keepass-forget")" "$CLONE1/bin/keepass-forget"
check "writes the setting with \$HOME" has "$(cat "$H1/.config/direnv/direnvrc")" 'KEEPASS_DATABASE="$HOME/Documents/Pass words (x) \$y.kdbx"'
check "the setting yields the exact path" equals \
  "$(HOME=$H1 bash -c 'source "$HOME/.config/direnv/direnvrc"; printf %s "$KEEPASS_DATABASE"')" \
  "$H1/Documents/Pass words (x) \$y.kdbx"
check "notes the missing database file" has "$out" "doesn't exist (yet)"
check "notes that ~/.local/bin isn't on PATH" has "$out" "~/.local/bin isn't on your PATH"
check "suggests a next step" has "$out" "Next: add lines like"

echo "I02 running it again"
out=$(install_in "$H1")
check "up to date" has "$out" "direnv-keepassxc v0.2.0 is up to date."
check "setting not duplicated" equals "$(grep -c 'KEEPASS_DATABASE=' "$H1/.config/direnv/direnvrc")" 1
check "no next-step hint" lacks "$out" "Next:"

echo "I03 switching versions"
out=$(install_in "$H1" --version v0.1.0)
check "to an older release" has "$out" "Switched direnv-keepassxc from v0.2.0 to v0.1.0."
out=$(install_in "$H1")
check "back to the latest release" has "$out" "Switched direnv-keepassxc from v0.1.0 to v0.2.0."
out=$(install_in "$H1" --version main)
check "to main" has "$out" "Switched direnv-keepassxc from v0.2.0 to $MAIN_SHA."
out=$(install_in "$H1" --version v9.9.9)
status=$?
check "unknown version fails" equals "$status" 1
check "says so" has "$out" "there's no version v9.9.9"
check "stays where it was" equals "$(git -C "$CLONE1" rev-parse --short HEAD)" "$MAIN_SHA"
install_in "$H1" >/dev/null

echo "I04 local changes block updates"
echo "# local edit" >>"$CLONE1/keepass.sh"
out=$(install_in "$H1")
status=$?
check "refuses" equals "$status" 1
check "says why" has "$out" "~/.local/share/direnv-keepassxc has local changes"
git -C "$CLONE1" checkout -q -- keepass.sh

echo "I05 direnv loads it"
mkdir -p "$H1/project"
printf '%s\n' \
  'declare -F use_keepass >/dev/null && echo "check: use_keepass is loaded" >&2' \
  '[[ -n ${KEEPASS_DATABASE:-} ]] && echo "check: KEEPASS_DATABASE is set" >&2' >"$H1/project/.envrc"
env -i HOME="$H1" PATH="$PATH" direnv allow "$H1/project" >/dev/null 2>&1
out=$(env -i HOME="$H1" PATH="$PATH" direnv exec "$H1/project" true 2>&1)
check "use_keepass is available" has "$out" "check: use_keepass is loaded"
check "KEEPASS_DATABASE comes from direnvrc" has "$out" "check: KEEPASS_DATABASE is set"

echo "I06 existing files are never replaced"
H2=$T/home2
mkdir -p "$H2/.config/direnv/lib"
echo "# my own" >"$H2/.config/direnv/lib/keepass.sh"
out=$(install_in "$H2" --database "$H2/db.kdbx")
status=$?
check "refuses" equals "$status" 1
check "says why" has "$out" "~/.config/direnv/lib/keepass.sh already exists and wasn't created by this installer"
check "leaves the file alone" equals "$(cat "$H2/.config/direnv/lib/keepass.sh")" "# my own"
check "clones nothing" equals "$(exists "$H2/.local/share/direnv-keepassxc")" no

echo "I07 a foreign folder where the clone goes"
H3=$T/home3
mkdir -p "$H3/.local/share/direnv-keepassxc"
out=$(install_in "$H3")
status=$?
check "refuses" equals "$status" 1
check "says why" has "$out" "~/.local/share/direnv-keepassxc exists but isn't a clone of $ORIGIN"

echo "I08 ~/.direnvrc is used when there's no direnvrc in the config folder"
H4=$T/home4
mkdir -p "$H4"
echo "# existing" >"$H4/.direnvrc"
install_in "$H4" --database "$H4/db.kdbx" >/dev/null
check "appends to ~/.direnvrc" has "$(cat "$H4/.direnvrc")" 'KEEPASS_DATABASE="$HOME/db.kdbx"'
check "keeps what was there" has "$(cat "$H4/.direnvrc")" "# existing"
check "creates no second direnvrc" equals "$(exists "$H4/.config/direnv/direnvrc")" no

echo "I09 without a terminal and without --database"
H5=$T/home5
out=$(install_in "$H5")
check "asks to set it" has "$out" "set KEEPASS_DATABASE to your .kdbx file in ~/.config/direnv/direnvrc"
check "writes no direnvrc" equals "$(exists "$H5/.config/direnv/direnvrc")" no

echo "I10 asks in a terminal"
H6=$T/home6
mkdir -p "$H6"
out=$(LC_ALL=en_US.UTF-8 ANSWERS='~/Documents/passwords.kdbx' expect "$REPO/tests/answer.exp" \
  env -i HOME="$H6" PATH="$PATH" DIRENV_KEEPASSXC_REPO="$ORIGIN" "$INSTALL_BASH" "$REPO/install.sh" 2>&1 | tr -d '\r')
check "prompts" has "$out" "KeePass database (.kdbx) to use (empty to skip): "
check "saves the answer" has "$(cat "$H6/.config/direnv/direnvrc" 2>/dev/null)" 'KEEPASS_DATABASE="$HOME/Documents/passwords.kdbx"'

echo "I11 piped into bash, like curl | bash"
H7=$T/home7
out=$(env -i HOME="$H7" PATH="$PATH" DIRENV_KEEPASSXC_REPO="$ORIGIN" \
  "$INSTALL_BASH" -s -- --database "$H7/db.kdbx" <"$REPO/install.sh" 2>&1)
check "installs" has "$out" "Installed direnv-keepassxc v0.2.0"
check "links the library" equals "$(readlink "$H7/.config/direnv/lib/keepass.sh")" "$H7/.local/share/direnv-keepassxc/keepass.sh"
check "saves the setting" has "$(cat "$H7/.config/direnv/direnvrc")" 'KEEPASS_DATABASE="$HOME/db.kdbx"'

echo "I12 options"
out=$(env -i HOME="$H7" PATH="$H7/.local/bin:$PATH" DIRENV_KEEPASSXC_REPO="$ORIGIN" \
  "$INSTALL_BASH" "$REPO/install.sh" </dev/null 2>&1)
check "no PATH note when ~/.local/bin is on PATH" lacks "$out" "isn't on your PATH"
out=$(install_in "$H5" --help)
status=$?
check "--help" equals "$status:$(grep -c '^Usage: install.sh' <<<"$out")" "0:1"
out=$(install_in "$H5" --frobnicate)
status=$?
check "unknown option fails" equals "$status:$(grep -c 'unknown option --frobnicate' <<<"$out")" "1:1"

echo "I13 uninstall"
echo "# keep me" >"$H1/.config/direnv/lib/other.sh"
out=$(install_in "$H1" --uninstall)
check "removes the library link" equals "$(exists "$H1/.config/direnv/lib/keepass.sh")" no
check "removes the keepass-forget link" equals "$(exists "$H1/.local/bin/keepass-forget")" no
check "removes the clone" equals "$(exists "$CLONE1")" no
check "keeps other files" equals "$(cat "$H1/.config/direnv/lib/other.sh")" "# keep me"
check "keeps direnvrc" has "$(cat "$H1/.config/direnv/direnvrc")" "KEEPASS_DATABASE="
check "explains how to remove the password" has "$out" "security delete-generic-password -s keepass-master"
out=$(install_in "$H1" --uninstall)
status=$?
check "running it again is harmless" equals "$status:$out" "0:Nothing to remove."
out=$(install_in "$H2" --uninstall)
check "leaves files it didn't create" equals "$(cat "$H2/.config/direnv/lib/keepass.sh")" "# my own"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
