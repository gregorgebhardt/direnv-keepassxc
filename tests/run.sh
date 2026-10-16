#!/bin/bash
# Integration tests for use_keepass and keepass-forget (macOS).
#
# Runs a real direnv with its own config and state against throwaway KeePassXC databases.
# Creates and removes login keychain items named use-keepass-test*; your own settings and
# keychain items are not used. Needs direnv, expect and KeePassXC.
#
#   tests/run.sh
#   DIRENV_BASH=/bin/bash tests/run.sh   # evaluate .envrc files with macOS's bash 3.2
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SVC=use-keepass-test
APP_CLI=/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli

for tool in security direnv expect xxd; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
CLI=$(command -v keepassxc-cli) || CLI=$APP_CLI
[[ -x $CLI ]] || { echo "missing: keepassxc-cli (install KeePassXC)" >&2; exit 1; }

# Physical path: direnv doesn't match an .envrc allowed via /var/... when it runs from /private/var/...
T=$(mktemp -d "${TMPDIR:-/tmp}/use-keepass-test.XXXXXX") && T=$(cd "$T" && pwd -P) || exit 1
LOG=$T/calls.log
pass=0
fail=0

clear_items() {
  local suffix
  for suffix in '' -b -u -k; do
    /usr/bin/security delete-generic-password -s "$SVC$suffix" -a "$USER" >/dev/null 2>&1
  done
}
cleanup() {
  clear_items
  rm -rf "$T"
}
trap cleanup EXIT
clear_items

q() { printf '%q' "$1"; }

# --- fixtures ------------------------------------------------------------------

# make_db <file> <master password> [key file]
make_db() {
  local db=$1 password=$2 key_file=${3:-}
  local -a create=() key=()
  if [[ -n $key_file ]]; then
    create=(--set-key-file "$key_file")
    key=(-k "$key_file")
  fi
  {
    printf '%s\n%s\n' "$password" "$password" |
      "$CLI" db-create -q -p -t 100 ${create[@]+"${create[@]}"} "$db" &&
      printf '%s\n' "$password" |
      "$CLI" mkdir -q ${key[@]+"${key[@]}"} "$db" 'API Keys' &&
      printf '%s\n%s\n' "$password" 'entry-secret-1' |
      "$CLI" add -q ${key[@]+"${key[@]}"} -u alice --url https://example.test -p "$db" 'API Keys/Test' &&
      printf '%s\n%s\n' "$password" 'entry-secret-2 with "quotes" and spaces' |
      "$CLI" add -q ${key[@]+"${key[@]}"} -p "$db" Second
  } >/dev/null 2>&1 || { echo "could not create test database $db" >&2; exit 1; }
}

mkdir -p "$T/db" "$T/config/lib" "$T/data" "$T/cache" "$T/proj" "$T/shim-sec" "$T/shim-cli"
make_db "$T/db/a.kdbx" alpha-master
make_db "$T/db/b.kdbx" beta-master
make_db "$T/db/u.kdbx" 'pässwört "q" \b €'
make_db "$T/db/k.kdbx" kilo-master "$T/db/k.keyx"

ln -s "$REPO/keepass.sh" "$T/config/lib/keepass.sh"
printf 'KEEPASS_DATABASE=%q\nKEEPASS_KEYCHAIN_SERVICE=%q\n' "$T/db/a.kdbx" "$SVC" >"$T/config/direnvrc"

# Wrappers that log which commands use_keepass runs.
cat >"$T/shim-sec/security" <<EOF
#!/bin/bash
printf 'security %s\n' "\${1:-}" >>$(q "$LOG")
exec /usr/bin/security "\$@"
EOF
cat >"$T/shim-cli/keepassxc-cli" <<EOF
#!/bin/bash
printf 'keepassxc-cli %s\n' "\${1:-}" >>$(q "$LOG")
exec $(q "$CLI") "\$@"
EOF
chmod +x "$T/shim-sec/security" "$T/shim-cli/keepassxc-cli"

PATH_DEFAULT="$T/shim-sec:$T/shim-cli:$PATH"
PATH_NO_CLI=$T/shim-sec
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in ${path_dirs[@]+"${path_dirs[@]}"}; do
  if [[ -n $dir && ! -x $dir/keepassxc-cli ]]; then
    PATH_NO_CLI+=":$dir"
  fi
done
TEST_PATH=$PATH_DEFAULT

# --- helpers -------------------------------------------------------------------

isolated() { # sets ISOLATED: an env -i command line for the isolated direnv
  ISOLATED=(env -i HOME="$HOME" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH="$TEST_PATH" TERM=xterm
    DIRENV_CONFIG="$T/config" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache")
  if [[ -n ${DIRENV_BASH:-} ]]; then
    ISOLATED+=(DIRENV_BASH="$DIRENV_BASH")
  fi
}
store_item() { # service password
  local hex
  hex=$(printf '%s' "$2" | xxd -p | tr -d '\n')
  printf 'add-generic-password -U -s "%s" -a "%s" -X %s\n' "$1" "$USER" "$hex" | /usr/bin/security -i >/dev/null 2>&1
}
read_item() { # service -> stored password
  local line
  line=$(/usr/bin/security find-generic-password -s "$1" -a "$USER" -g 2>&1 >/dev/null) || return 1
  line=${line##*$'\n'}
  case $line in
    'password: 0x'*) line=${line#password: 0x}; printf '%s' "${line%% *}" | xxd -r -p ;;
    'password: "'*'"') line=${line#password: \"}; printf '%s' "${line%\"}" ;;
    *) return 1 ;;
  esac
}
new_project() { # name envrc-content -> path of the allowed project
  local dir=$T/proj/$1
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/.envrc"
  isolated
  "${ISOLATED[@]}" direnv allow "$dir" >/dev/null 2>&1
  printf '%s' "$dir"
}
SHOW='printenv | grep -E "^TEST_|KEEPASS|_keepass" | sort; true'
run_plain() { # dir -> output, without a terminal
  : >"$LOG"
  isolated
  "${ISOLATED[@]}" direnv exec "$1" bash -c "$SHOW" </dev/null 2>&1
}
run_tty() { # dir answers -> output, in a pseudo-terminal that answers the prompts
  : >"$LOG"
  isolated
  LC_ALL=en_US.UTF-8 ANSWERS=$2 expect "$REPO/tests/answer.exp" \
    "${ISOLATED[@]}" direnv exec "$1" bash -c "$SHOW" 2>&1 | tr -d '\r'
}
calls() { grep -cxF "$1" "$LOG"; }

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
times() { [[ $(grep -cF -- "$2" <<<"$1") -eq $3 ]]; }
equals() { [[ $1 == "$2" ]]; }

VARS="use_keepass 'API Keys/Test' TEST_A
use_keepass 'API Keys/Test' TEST_USER UserName
use_keepass 'API Keys/Test' TEST_URL URL
use_keepass Second TEST_B"

isolated
echo "direnv evaluates .envrc files with: $("${ISOLATED[@]}" direnv status 2>/dev/null | sed -n 's/^bash_path //p')"

# --- tests ---------------------------------------------------------------------

echo "T01 usage error"
d=$(new_project t01 "use_keepass 'API Keys/Test'")
out=$(run_plain "$d")
check "prints usage" has "$out" "usage: use_keepass <KeePass entry> <environment variable> [attribute]"

echo "T02 KEEPASS_DATABASE missing, reported once"
d=$(new_project t02 "KEEPASS_DATABASE=
$VARS")
out=$(run_plain "$d")
check "one hint" times "$out" "set KEEPASS_DATABASE" 1
check "nothing exported" lacks "$out" "TEST_"

echo "T03 unreadable database"
d=$(new_project t03 "KEEPASS_DATABASE=$(q "$T/db/missing.kdbx")
$VARS")
out=$(run_plain "$d")
check "one hint" times "$out" "cannot read KeePass database $T/db/missing.kdbx" 1

echo "T04 keepassxc-cli missing"
d=$(new_project t04 "KEEPASSXC_CLI=$(q "$T/nope/keepassxc-cli")
$VARS")
out=$(run_plain "$d")
check "one hint" times "$out" "keepassxc-cli not found" 1

echo "T05 nothing stored, no terminal"
clear_items
d=$(new_project t05 "$VARS")
out=$(run_plain "$d")
check "one hint" times "$out" "no master password stored for $T/db/a.kdbx; run 'direnv reload' in a terminal" 1
check "no prompt" lacks "$out" "KeePass master password for"
check "one keychain read" equals "$(calls 'security find-generic-password')" 1
check "no keepassxc-cli runs" equals "$(grep -c keepassxc-cli "$LOG")" 0
check "nothing stored" equals "$(read_item "$SVC" || echo none)" none

echo "T06 nothing stored, terminal: wrong password, then the right one"
clear_items
d=$(new_project t06 "$VARS")
out=$(run_tty "$d" "wrong-pass|alpha-master")
check "explains why it asks" has "$out" "No KeePass master password is stored in your Keychain yet."
check "rejects the wrong password once" times "$out" "That password does not open a.kdbx." 1
check "asks twice" times "$out" "KeePass master password for a.kdbx (empty to skip): " 2
check "TEST_A" has "$out" "TEST_A=entry-secret-1"
check "TEST_USER" has "$out" "TEST_USER=alice"
check "TEST_URL" has "$out" "TEST_URL=https://example.test"
check "TEST_B" has "$out" 'TEST_B=entry-secret-2 with "quotes" and spaces'
check "stored in the keychain" equals "$(read_item "$SVC")" alpha-master
check "typed password not echoed" lacks "$out" "alpha-master"
check "wrong password not echoed" lacks "$out" "wrong-pass"
check "one keychain read" equals "$(calls 'security find-generic-password')" 1
check "one keychain write" equals "$(calls 'security -i')" 1

echo "T07 stored password, no terminal, across source_up and source_env"
clear_items
store_item "$SVC" alpha-master
new_project t07 "use_keepass 'API Keys/Test' TEST_A
use_keepass 'API Keys/Test' TEST_USER UserName" >/dev/null
d=$(new_project t07/child "source_up
source_env_if_exists .envrc.local")
printf '%s\n' "use_keepass 'API Keys/Test' TEST_URL URL" "use_keepass Second TEST_B" >"$d/.envrc.local"
out=$(run_plain "$d")
check "TEST_A from the parent" has "$out" "TEST_A=entry-secret-1"
check "TEST_USER from the parent" has "$out" "TEST_USER=alice"
check "TEST_URL from .envrc.local" has "$out" "TEST_URL=https://example.test"
check "TEST_B from .envrc.local" has "$out" 'TEST_B=entry-secret-2 with "quotes" and spaces'
check "one keychain read for four lookups" equals "$(calls 'security find-generic-password')" 1
check "four show runs, no extra checks" equals "$(calls 'keepassxc-cli show'),$(calls 'keepassxc-cli db-info')" "4,0"
check "settings stay out of the environment" lacks "$out" "KEEPASS"
check "internal variables stay out of the environment" lacks "$out" "_keepass"

echo "T08 missing entries next to a good one"
d=$(new_project t08 "use_keepass 'Nope/Missing' TEST_X
use_keepass 'API Keys/Test' TEST_A
use_keepass 'Nope/Other' TEST_Y Password")
out=$(run_plain "$d")
check "error for the first missing entry" has "$out" "could not read 'Password' of KeePass entry 'Nope/Missing'"
check "error for the second missing entry" has "$out" "could not read 'Password' of KeePass entry 'Nope/Other'"
check "good entry still exported" has "$out" "TEST_A=entry-secret-1"
check "password checked once" equals "$(calls 'keepassxc-cli db-info')" 1
check "no prompt" lacks "$out" "KeePass master password for"

echo "T09 stored password no longer opens the database, no terminal"
d=$(new_project t09 "KEEPASS_DATABASE=$(q "$T/db/b.kdbx")
$VARS")
out=$(run_plain "$d")
check "one hint" times "$out" "the stored master password no longer opens $T/db/b.kdbx" 1
check "nothing exported" lacks "$out" "TEST_"
check "stored password untouched" equals "$(read_item "$SVC")" alpha-master

echo "T10 stored password no longer opens the database, terminal"
out=$(run_tty "$d" "beta-master")
check "explains why it asks" has "$out" "The stored KeePass master password no longer opens b.kdbx."
check "TEST_A" has "$out" "TEST_A=entry-secret-1"
check "TEST_B" has "$out" 'TEST_B=entry-secret-2 with "quotes" and spaces'
check "stored password replaced" equals "$(read_item "$SVC")" beta-master
check "not echoed" lacks "$out" "beta-master"

echo "T11 master password with umlauts, quotes, a backslash and a euro sign"
umlaut='pässwört "q" \b €'
d=$(new_project t11 "KEEPASS_DATABASE=$(q "$T/db/u.kdbx")
KEEPASS_KEYCHAIN_SERVICE=$SVC-u
$VARS")
out=$(run_tty "$d" "$umlaut")
check "TEST_A after the prompt" has "$out" "TEST_A=entry-secret-1"
check "stored byte for byte" equals "$(read_item "$SVC-u")" "$umlaut"
out=$(run_plain "$d")
check "read back from the keychain without a prompt" has "$out" "TEST_A=entry-secret-1"
check "no hint" lacks "$out" "use_keepass:"

echo "T12 key file"
store_item "$SVC-k" kilo-master
d=$(new_project t12 "KEEPASS_DATABASE=$(q "$T/db/k.kdbx")
KEEPASS_KEY_FILE=$(q "$T/db/k.keyx")
KEEPASS_KEYCHAIN_SERVICE=$SVC-k
$VARS")
out=$(run_plain "$d")
check "TEST_A" has "$out" "TEST_A=entry-secret-1"
check "TEST_B" has "$out" 'TEST_B=entry-secret-2 with "quotes" and spaces'

echo "T13 strict_env (set -euo pipefail)"
store_item "$SVC" alpha-master
d=$(new_project t13 "strict_env
$VARS")
out=$(run_plain "$d")
check "all four exported" equals "$(grep -c '^TEST_' <<<"$out")" 4
check "no shell errors" lacks "$out" "unbound variable"

echo "T14 keepassxc-cli not on PATH: falls back to KeePassXC.app"
if [[ -x $APP_CLI ]]; then
  TEST_PATH=$PATH_NO_CLI
  d=$(new_project t14 "$VARS")
  out=$(run_plain "$d")
  TEST_PATH=$PATH_DEFAULT
  check "TEST_A" has "$out" "TEST_A=entry-secret-1"
else
  echo "  SKIP KeePassXC.app is not in /Applications"
fi

echo "T15 two databases in one run"
store_item "$SVC" alpha-master
store_item "$SVC-b" beta-master
d=$(new_project t15 "use_keepass 'API Keys/Test' TEST_A
KEEPASS_DATABASE=$(q "$T/db/b.kdbx")
KEEPASS_KEYCHAIN_SERVICE=$SVC-b
use_keepass Second TEST_B")
out=$(run_plain "$d")
check "TEST_A from a.kdbx" has "$out" "TEST_A=entry-secret-1"
check "TEST_B from b.kdbx" has "$out" 'TEST_B=entry-secret-2 with "quotes" and spaces'
check "one keychain read per database" equals "$(calls 'security find-generic-password')" 2

echo "T16 keepass-forget"
out=$(KEEPASS_KEYCHAIN_SERVICE=$SVC "$REPO/bin/keepass-forget" 2>&1)
check "removes it" equals "$?:$out" "0:Removed the KeePass master password ($SVC) from your Keychain."
check "really gone" equals "$(read_item "$SVC" || echo none)" none
out=$(KEEPASS_KEYCHAIN_SERVICE=$SVC "$REPO/bin/keepass-forget" 2>&1)
check "second run says so" equals "$?:$out" "1:No KeePass master password ($SVC) found in your Keychain."

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
