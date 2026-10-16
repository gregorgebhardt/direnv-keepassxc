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
- git, for the installer or a manual install

## Installation

There are three ways to install it. Pick one: neither the installer nor Homebrew's setup command replaces a link that another method created.

### Installer

```sh
curl -fsSL https://raw.githubusercontent.com/gregorgebhardt/direnv-keepassxc/main/install.sh | bash
```

The installer:

- clones the latest release to `~/.local/share/direnv-keepassxc`;
- links `keepass.sh` into direnv's `lib` folder, which direnv loads automatically, and `keepass-forget` into `~/.local/bin`;
- asks for your database path, unless your `direnvrc` already sets `KEEPASS_DATABASE`.

It never replaces files it didn't create. To read it before running it, clone the repository and run `./install.sh` instead.

| Option | Effect |
|---|---|
| `--version <tag>` | Install a specific release, e.g. `v1.0.0`. `--version main` installs the latest commit. |
| `--database <path>` | Set the database path without being asked. |
| `--uninstall` | Remove the links and the clone. |

When piping into `bash`, put options after `bash -s --`, e.g. `curl … | bash -s -- --version v1.0.0`. `DIRENV_KEEPASSXC_DIR` and `DIRENV_KEEPASSXC_BIN` change where the clone and `keepass-forget` go.

### Homebrew

```sh
brew install gregorgebhardt/tap/direnv-keepassxc
direnv-keepassxc-setup
```

`direnv-keepassxc-setup` links Homebrew's copy of `keepass.sh` into direnv's `lib` folder and asks for your database path, like the installer. Homebrew can't create that link itself, because it only writes inside its own folders. Homebrew also puts `keepass-forget` on your `PATH`.

### Manual

```sh
git clone https://github.com/gregorgebhardt/direnv-keepassxc.git ~/.local/share/direnv-keepassxc
mkdir -p ~/.config/direnv/lib
ln -s ~/.local/share/direnv-keepassxc/keepass.sh ~/.config/direnv/lib/keepass.sh
ln -s ~/.local/share/direnv-keepassxc/bin/keepass-forget ~/.local/bin/keepass-forget   # optional
```

Then set your database, as described below.

### Setting the database

Unless the installer or `direnv-keepassxc-setup` did it for you, tell `use_keepass` where your database is, in `~/.config/direnv/direnvrc`:

```sh
KEEPASS_DATABASE="$HOME/Documents/Passwords.kdbx"
```

## Updating and uninstalling

Updates are never automatic. The installer and Homebrew only install tagged releases, and only when you run them.

| Installed with | Update | Uninstall |
|---|---|---|
| Installer | `~/.local/share/direnv-keepassxc/install.sh` | `~/.local/share/direnv-keepassxc/install.sh --uninstall` |
| Homebrew | `brew upgrade direnv-keepassxc` | `direnv-keepassxc-setup --uninstall`, then `brew uninstall direnv-keepassxc` |
| Manual | `git -C ~/.local/share/direnv-keepassxc pull` (follows `main`) | Delete the links and the clone |

The Homebrew link survives upgrades, because it points to Homebrew's stable `opt` folder. To also remove the stored master password, run `keepass-forget` before uninstalling.

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
tests/run.sh                                            # use_keepass and keepass-forget
DIRENV_BASH=/bin/bash tests/run.sh                      # the same with macOS's bash 3.2
tests/installer.sh                                      # install.sh, with macOS's bash 3.2
INSTALL_BASH=/opt/homebrew/bin/bash tests/installer.sh  # install.sh, with another bash
```

`tests/run.sh` runs a real direnv, with its own config and state, against throwaway databases. It creates and removes Keychain items named `use-keepass-test*`. `tests/installer.sh` installs from a local copy with test releases into throwaway home folders. Both need `expect`, which comes with macOS.

## Releasing

1. Create the release, which also creates the tag: `gh release create vX.Y.Z --target main --generate-notes`.
2. In [gregorgebhardt/homebrew-tap](https://github.com/gregorgebhardt/homebrew-tap), update `url` and `sha256` in `Formula/direnv-keepassxc.rb`. The checksum comes from `curl -fsSL https://github.com/gregorgebhardt/direnv-keepassxc/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`.

The installer picks up the new release the next time it runs.

## License

[MIT](LICENSE)
