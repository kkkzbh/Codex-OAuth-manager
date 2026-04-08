# CodexBar

Native KDE Plasma 6 widgets for local Codex usage tracking and multi-account live limit monitoring.

This repository now maintains:

- the Plasma widget at [`plasma/local.codexbar.tokens`](/home/kkkzbh/code/codex-usage/plasma/local.codexbar.tokens)
- the Plasma widget at [`plasma/local.codexbar.accounts`](/home/kkkzbh/code/codex-usage/plasma/local.codexbar.accounts)
- the Rust collector at [`native/codexbar-collector`](/home/kkkzbh/code/codex-usage/native/codexbar-collector)
- the install and bridge scripts in [`scripts`](/home/kkkzbh/code/codex-usage/scripts)

There is no web dashboard and no `systemd --user` service in this repo anymore.

## Install

```bash
/home/kkkzbh/code/codex-usage/scripts/install-codexbar.sh
```

The install script will:

- build `native/codexbar-collector`
- install `codexbar-collector` to `~/.local/bin/codexbar-collector`
- install `codexbar-plasmoid-bridge` to `~/.local/bin/codexbar-plasmoid-bridge`
- install `codexbar-accounts-plasmoid-bridge` to `~/.local/bin/codexbar-accounts-plasmoid-bridge`
- install or upgrade the `local.codexbar.tokens` plasmoid
- install or upgrade the `local.codexbar.accounts` plasmoid

After that, add `CodexBar Tokens` and/or `CodexBar Accounts` from Plasma widgets to your panel.

## Collector

```bash
~/.local/bin/codexbar-collector snapshot --format json
```

The collector outputs a `PanelSnapshotV1` JSON payload with:

- `generatedAt`
- `totalTokens`
- `formattedTotalTokens`
- `tokensToday`
- `tokens7d`
- `tokens30d`
- `sources`
- `availableSourceCount`
- `unavailableSourceCount`
- `status`
- `error`

For the `Codex` source, the collector now aggregates:

- the current Linux Codex home from `CODEX_HOME` or `~/.codex`
- any extra homes passed with repeated `--extra-codex-home`
- any Windows Codex homes auto-discovered under `/mnt/c/Users/*/.codex`

You can also append explicit extra Codex homes with `CODEXBAR_EXTRA_CODEX_HOMES`.

## Live account limits

The collector also exposes live multi-account limit snapshots backed by the local
Codex account registry and per-account auth files:

```bash
~/.local/bin/codexbar-collector accounts-snapshot --format json --force-refresh
```

This reads:

- `~/.codex/accounts/registry.json`
- `~/.codex/accounts/*.auth.json`
- `~/.codex/auth.json`

For each account it attempts a live fetch against the Codex usage endpoint and
falls back to cached / registry usage when the token is expired or the account
cannot be queried.

## Development

Run collector tests with:

```bash
cargo test --manifest-path /home/kkkzbh/code/codex-usage/native/codexbar-collector/Cargo.toml
```
