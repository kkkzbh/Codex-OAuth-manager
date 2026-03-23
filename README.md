# CodexBar

Native KDE Plasma 6 token widget for local Codex usage tracking.

This repository now only maintains:

- the Plasma widget at [`plasma/local.codexbar.tokens`](/home/kkkzbh/code/codex-usage/plasma/local.codexbar.tokens)
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
- install or upgrade the `local.codexbar.tokens` plasmoid

After that, add `CodexBar Tokens` from Plasma widgets to your panel.

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

## Development

Run collector tests with:

```bash
cargo test --manifest-path /home/kkkzbh/code/codex-usage/native/codexbar-collector/Cargo.toml
```
