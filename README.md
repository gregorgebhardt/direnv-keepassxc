# direnv-keepassxc

A [direnv](https://direnv.net) extension that loads secrets from a [KeePassXC](https://keepassxc.org) database into your project environments. The database's master password is kept in the macOS Keychain, so you type it once.

```sh
# .envrc
use_keepass 'API Keys/GitHub' GITHUB_TOKEN
use_keepass 'Databases/Staging' DB_USER UserName
use_keepass 'Databases/Staging' DB_PASSWORD
```

## How it works

- **First use:** when no master password is stored yet, `use_keepass` asks for it in the terminal, checks it against the database and stores it in your login keychain.
- **After that:** it reads the master password from the Keychain without asking, once per direnv run, however many `use_keepass` lines there are.
- **Changed master password:** if the stored one no longer opens the database, it asks again and replaces it.
- **No terminal** (IDEs, editors, AI agents): it never prompts. Instead it prints one line asking you to run `direnv reload` in a terminal.

## Requirements

- macOS (the Keychain is accessed with the `security` command)
- direnv
- KeePassXC. `keepassxc-cli` is used from your `PATH`, or from `/Applications/KeePassXC.app` if it isn't there.

## Installation

Clone the repository and link the library into direnv's `lib` folder, which direnv loads automatically:

```sh
git clone https://github.com/gregorgebhardt/direnv-keepassxc.git ~/.local/share/direnv-keepassxc
mkdir -p ~/.config/direnv/lib
ln -s ~/.local/share/direnv-keepassxc/keepass.sh ~/.config/direnv/lib/keepass.sh
```

Tell it where your database is, in `~/.config/direnv/direnvrc`:

```sh
KEEPASS_DATABASE="$HOME/Documents/Passwords.kdbx"
```

Optionally, link `keepass-forget` into a directory on your `PATH`:

```sh
ln -s ~/.local/share/direnv-keepassxc/bin/keepass-forget ~/.local/bin/keepass-forget
```

## Usage

```sh
use_keepass <entry> <variable> [attribute]
```

- `entry` is the entry's path in the database, including its groups, e.g. `'API Keys/GitHub'`.
- `attribute` defaults to `Password`. Others include `UserName`, `URL`, `Notes` and custom attributes.

If an entry can't be read, `use_keepass` reports it and the rest of your `.envrc` still runs (unless you use `strict_env`).

To remove the stored master password, run `keepass-forget`.

## Settings

Set these in `~/.config/direnv/direnvrc`. Plain variables are enough there, and they keep the settings out of your shell environment. `keepass-forget` only sees the Keychain settings if you export them from your shell.

| Setting | Default | Purpose |
|---|---|---|
| `KEEPASS_DATABASE` | (none) | Path to your `.kdbx` file. Required. |
| `KEEPASS_KEY_FILE` | (none) | Key file, if your database uses one. |
| `KEEPASS_KEYCHAIN_SERVICE` | `keepass-master` | Name of the Keychain item. |
| `KEEPASS_KEYCHAIN_ACCOUNT` | `$USER` | Account of the Keychain item. |
| `KEEPASSXC_CLI` | from `PATH`, then KeePassXC.app | The `keepassxc-cli` to run. |

An `.envrc` can change them before its `use_keepass` lines, for example to read from a second database. Give each database its own `KEEPASS_KEYCHAIN_SERVICE`.

## Security notes

- The master password is stored in your login keychain, which is unlocked while you're logged in. The item is created by the `security` command, so any program running as you can read it with that command without a prompt. Consider keeping development secrets in a separate database, so the stored password only unlocks those.
- Loaded secrets are ordinary environment variables: every program started from that shell can read them.
- The master password reaches `security` and `keepassxc-cli` through stdin, never as a command-line argument.
- If your entry names are personal, keep the `use_keepass` lines in a git-ignored file, e.g. `.envrc.local`, loaded with `source_env_if_exists .envrc.local`.

## Tests

```sh
tests/run.sh
DIRENV_BASH=/bin/bash tests/run.sh   # with macOS's bash 3.2
```

The tests run a real direnv, with its own config and state, against throwaway databases. They need `expect` (included with macOS) and create and remove Keychain items named `use-keepass-test*`.

## License

[MIT](LICENSE)
