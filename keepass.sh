# shellcheck shell=bash
#
# use_keepass <entry> <variable> [attribute]
#
# direnv helper that exports one attribute (default: Password) of a KeePassXC entry.
# The database's master password is kept in the macOS login keychain. If it's missing,
# or no longer opens the database, you're asked for it in the terminal; without a
# terminal (IDEs, agents) the call fails with a hint instead. `keepass-forget` removes it.
#
# Settings, as plain variables in ~/.config/direnv/direnvrc or exported from your shell:
#   KEEPASS_DATABASE          the .kdbx file (required)
#   KEEPASS_KEY_FILE          key file, if the database uses one
#   KEEPASS_KEYCHAIN_SERVICE  keychain item name (default: keepass-master)
#   KEEPASS_KEYCHAIN_ACCOUNT  keychain account (default: $USER)
#   KEEPASSXC_CLI             keepassxc-cli to run (default: from PATH, then KeePassXC.app)

_keepass_settings_key=

use_keepass() {
  local entry=${1:-} variable=${2:-} attribute=${3:-Password} value

  if [[ $# -lt 2 || $# -gt 3 || -z $entry || -z $variable ]]; then
    log_error 'usage: use_keepass <KeePass entry> <environment variable> [attribute]'
    return 1
  fi

  _keepass_load_password || return 1

  if value=$(_keepass_show "$attribute" "$entry"); then
    _keepass_verified=1
  elif _keepass_password_works; then
    log_error "use_keepass: could not read '$attribute' of KeePass entry '$entry'"
    return 1
  elif _keepass_prompt "The stored KeePass master password no longer opens ${_keepass_db##*/}."; then
    if ! value=$(_keepass_show "$attribute" "$entry"); then
      log_error "use_keepass: could not read '$attribute' of KeePass entry '$entry'"
      return 1
    fi
  else
    _keepass_fail "the stored master password no longer opens $_keepass_db; run 'direnv reload' in a terminal to enter the new one"
    return 1
  fi

  export "$variable=$value"
}

# Resolves the settings once per direnv run (or when they change) and reports problems once.
_keepass_configure() {
  local service=${KEEPASS_KEYCHAIN_SERVICE:-keepass-master}
  local account=${KEEPASS_KEYCHAIN_ACCOUNT:-${USER:-$(id -un)}}
  local database=${KEEPASS_DATABASE:-}
  local key_file=${KEEPASS_KEY_FILE:-}
  local settings

  database=${database/#\~/$HOME}
  key_file=${key_file/#\~/$HOME}
  settings="$service|$account|$database|$key_file|${KEEPASSXC_CLI:-}"
  if [[ $settings == "$_keepass_settings_key" ]]; then
    [[ -z $_keepass_failed ]]
    return
  fi

  _keepass_settings_key=$settings
  _keepass_service=$service
  _keepass_account=$account
  _keepass_db=$database
  _keepass_key_args=()
  if [[ -n $key_file ]]; then
    _keepass_key_args=(-k "$key_file")
  fi
  _keepass_password=
  _keepass_verified=
  _keepass_failed=

  if [[ -n ${KEEPASSXC_CLI:-} ]]; then
    _keepass_cli=$(command -v "$KEEPASSXC_CLI") || _keepass_cli=
  else
    _keepass_cli=$(command -v keepassxc-cli) || _keepass_cli=/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli
  fi

  if ! command -v security >/dev/null; then
    _keepass_fail 'needs the macOS Keychain (the security command)'
  elif [[ -z $database ]]; then
    _keepass_fail 'set KEEPASS_DATABASE to your .kdbx file, e.g. in ~/.config/direnv/direnvrc'
  elif [[ ! -r $database ]]; then
    _keepass_fail "cannot read KeePass database $database"
  elif [[ -n $key_file && ! -r $key_file ]]; then
    _keepass_fail "cannot read key file $key_file"
  elif [[ ! -x $_keepass_cli ]]; then
    _keepass_fail 'keepassxc-cli not found; install KeePassXC or set KEEPASSXC_CLI'
  fi
  [[ -z $_keepass_failed ]]
}

_keepass_fail() {
  log_error "use_keepass: $1"
  _keepass_failed=1
}

_keepass_load_password() {
  _keepass_configure || return 1
  [[ -z $_keepass_password ]] || return 0

  _keepass_password=$(_keepass_keychain_read) || _keepass_password=
  [[ -z $_keepass_password ]] || return 0

  _keepass_prompt 'No KeePass master password is stored in your Keychain yet.' && return 0
  _keepass_fail "no master password stored for $_keepass_db; run 'direnv reload' in a terminal to enter it"
  return 1
}

# `security -w` prints passwords with non-ASCII characters as hex, so this parses the
# `-g` line instead, which is either password: "text" or password: 0xHEX  "escaped".
_keepass_keychain_read() {
  local line

  line=$(security find-generic-password -s "$_keepass_service" -a "$_keepass_account" -g 2>&1 >/dev/null) || return 1
  line=${line##*$'\n'}
  case $line in
    'password: 0x'*)
      line=${line#password: 0x}
      printf '%s' "${line%% *}" | xxd -r -p
      ;;
    'password: "'*'"')
      line=${line#password: \"}
      printf '%s' "${line%\"}"
      ;;
    *)
      return 1
      ;;
  esac
}

# Goes through `security -i` so the password never shows up in a process list.
_keepass_keychain_store() {
  local hex

  hex=$(printf '%s' "$1" | xxd -p | tr -d '\n')
  printf 'add-generic-password -U -s "%s" -a "%s" -j "%s" -X %s\n' \
    "$_keepass_service" "$_keepass_account" 'KeePass master password for use_keepass (direnv)' "$hex" |
    security -i >/dev/null 2>&1
}

_keepass_show() {
  printf '%s\n' "$_keepass_password" |
    "$_keepass_cli" show -q -a "$1" ${_keepass_key_args[@]+"${_keepass_key_args[@]}"} "$_keepass_db" "$2" 2>/dev/null
}

_keepass_opens() {
  printf '%s\n' "$1" |
    "$_keepass_cli" db-info -q ${_keepass_key_args[@]+"${_keepass_key_args[@]}"} "$_keepass_db" >/dev/null 2>&1
}

_keepass_password_works() {
  [[ -n $_keepass_verified ]] && return 0
  _keepass_opens "$_keepass_password" && _keepass_verified=1
}

# Asks in the terminal until the password opens the database, then stores it.
_keepass_prompt() {
  local password tries=0 name=${_keepass_db##*/}

  [[ -t 0 && -t 2 ]] || return 1
  printf '%s\n' "$1" >&2
  while ((tries++ < 3)); do
    printf 'KeePass master password for %s (empty to skip): ' "$name" >&2
    IFS= read -rs password || password=
    printf '\n' >&2
    [[ -n $password ]] || return 1
    if _keepass_opens "$password"; then
      _keepass_password=$password
      _keepass_verified=1
      _keepass_keychain_store "$password" ||
        log_error 'use_keepass: could not save the password in your Keychain; you will be asked again next time'
      return 0
    fi
    printf 'That password does not open %s.\n' "$name" >&2
  done
  return 1
}
