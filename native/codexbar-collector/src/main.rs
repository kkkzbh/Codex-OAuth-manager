use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use codexbar_collector::accounts::{
    AccountsPaths, AccountsSnapshotOptions, AutoSwitchOptions, activate_account, auto_switch_account,
    load_accounts_snapshot, remove_account, spawn_account_login,
};
use codexbar_collector::{BuildPaths, SnapshotOptions, load_snapshot};

#[derive(Debug, Parser)]
#[command(name = "codexbar-collector")]
#[command(about = "Collects local token totals for the CodexBar Plasma widget.")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Snapshot(SnapshotArgs),
    AccountsSnapshot(AccountsSnapshotArgs),
    Account(AccountArgs),
}

#[derive(Debug, Parser)]
struct SnapshotArgs {
    #[arg(long, default_value = "json")]
    format: String,
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[arg(long)]
    extra_codex_home: Vec<PathBuf>,
    #[arg(long)]
    claude_stats_path: Option<PathBuf>,
    #[arg(long)]
    antigravity_db_path: Option<PathBuf>,
    #[arg(long)]
    cache_path: Option<PathBuf>,
    #[arg(long, default_value_t = 15)]
    ttl_seconds: u64,
    #[arg(long)]
    no_cache: bool,
}

#[derive(Debug, Parser)]
struct AccountsSnapshotArgs {
    #[arg(long, default_value = "json")]
    format: String,
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[arg(long, default_value_t = 90)]
    refresh_interval_seconds: u64,
    #[arg(long, default_value_t = 60)]
    soft_ttl_seconds: u64,
    #[arg(long, default_value_t = 900)]
    hard_ttl_seconds: u64,
    #[arg(long, default_value_t = 8)]
    timeout_seconds: u64,
    #[arg(long, default_value_t = 4)]
    concurrency: usize,
    #[arg(long)]
    force_refresh: bool,
    #[arg(long)]
    active_only: bool,
}

#[derive(Debug, Parser)]
struct AccountArgs {
    #[command(subcommand)]
    command: AccountCommand,
}

#[derive(Debug, Subcommand)]
enum AccountCommand {
    Activate(AccountActivateArgs),
    Remove(AccountRemoveArgs),
    Login(AccountLoginArgs),
    AutoSwitch(AccountAutoSwitchArgs),
}

#[derive(Debug, Parser)]
struct AccountActivateArgs {
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[arg(long)]
    account_key: String,
}

#[derive(Debug, Parser)]
struct AccountRemoveArgs {
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[arg(long)]
    account_key: String,
}

#[derive(Debug, Parser)]
struct AccountLoginArgs {
    #[arg(long)]
    terminal: Option<String>,
}

#[derive(Debug, Parser)]
struct AccountAutoSwitchArgs {
    #[arg(long)]
    codex_home: Option<PathBuf>,
    #[arg(long, default_value_t = 60)]
    soft_ttl_seconds: u64,
    #[arg(long, default_value_t = 900)]
    hard_ttl_seconds: u64,
    #[arg(long, default_value_t = 8)]
    timeout_seconds: u64,
    #[arg(long, default_value_t = 4)]
    concurrency: usize,
    #[arg(long, default_value_t = 10)]
    threshold_5h_percent: u8,
    #[arg(long, default_value_t = 5)]
    threshold_weekly_percent: u8,
    #[arg(long)]
    force_refresh: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("codexbar-collector: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::Snapshot(args) => {
            if args.format != "json" {
                anyhow::bail!("unsupported format: {}", args.format);
            }

            let mut paths = BuildPaths::default();
            if let Some(path) = args.codex_home {
                paths.codex_home = path;
            }
            if !args.extra_codex_home.is_empty() {
                paths.extra_codex_homes.extend(args.extra_codex_home);
            }
            if let Some(path) = args.claude_stats_path {
                paths.claude_stats_path = path;
            }
            if let Some(path) = args.antigravity_db_path {
                paths.antigravity_db_path = path;
            }
            if let Some(path) = args.cache_path {
                paths.cache_path = path;
            }

            let snapshot = load_snapshot(&SnapshotOptions {
                now: chrono::Local::now().fixed_offset(),
                use_cache: !args.no_cache,
                ttl: Duration::from_secs(args.ttl_seconds),
                paths,
            })?;

            println!("{}", serde_json::to_string_pretty(&snapshot)?);
        }
        Command::AccountsSnapshot(args) => {
            if args.format != "json" {
                anyhow::bail!("unsupported format: {}", args.format);
            }

            let mut paths = AccountsPaths::default();
            if let Some(path) = args.codex_home {
                paths = AccountsPaths {
                    registry_path: path.join("accounts").join("registry.json"),
                    accounts_dir: path.join("accounts"),
                    auth_path: path.join("auth.json"),
                    cache_path: paths.cache_path,
                    codex_home: path,
                };
            }

            let snapshot = load_accounts_snapshot(&AccountsSnapshotOptions {
                now: chrono::Local::now().fixed_offset(),
                paths,
                soft_ttl: chrono::Duration::seconds(args.soft_ttl_seconds as i64),
                hard_ttl: chrono::Duration::seconds(args.hard_ttl_seconds as i64),
                timeout: Duration::from_secs(args.timeout_seconds),
                force_refresh: args.force_refresh,
                active_only: args.active_only,
                concurrency: args.concurrency,
            })?;
            println!("{}", serde_json::to_string_pretty(&snapshot)?);
        }
        Command::Account(args) => match args.command {
            AccountCommand::Activate(args) => {
                let paths = account_paths_from_codex_home(args.codex_home);
                let result = activate_account(&paths, &args.account_key, chrono::Local::now().fixed_offset())?;
                println!("{}", serde_json::to_string_pretty(&result)?);
            }
            AccountCommand::Remove(args) => {
                let paths = account_paths_from_codex_home(args.codex_home);
                let result = remove_account(&paths, &args.account_key)?;
                println!("{}", serde_json::to_string_pretty(&result)?);
            }
            AccountCommand::Login(args) => {
                let result = spawn_account_login(args.terminal.as_deref())?;
                println!("{}", serde_json::to_string_pretty(&result)?);
            }
            AccountCommand::AutoSwitch(args) => {
                let result = auto_switch_account(&AutoSwitchOptions {
                    now: chrono::Local::now().fixed_offset(),
                    paths: account_paths_from_codex_home(args.codex_home),
                    soft_ttl: chrono::Duration::seconds(args.soft_ttl_seconds as i64),
                    hard_ttl: chrono::Duration::seconds(args.hard_ttl_seconds as i64),
                    timeout: Duration::from_secs(args.timeout_seconds),
                    concurrency: args.concurrency,
                    threshold_5h_percent: args.threshold_5h_percent,
                    threshold_weekly_percent: args.threshold_weekly_percent,
                    force_refresh: args.force_refresh,
                })?;
                println!("{}", serde_json::to_string_pretty(&result)?);
            }
        },
    }

    Ok(())
}

fn account_paths_from_codex_home(codex_home: Option<PathBuf>) -> AccountsPaths {
    if let Some(path) = codex_home {
        let defaults = AccountsPaths::default();
        AccountsPaths {
            registry_path: path.join("accounts").join("registry.json"),
            accounts_dir: path.join("accounts"),
            auth_path: path.join("auth.json"),
            cache_path: defaults.cache_path,
            codex_home: path,
        }
    } else {
        AccountsPaths::default()
    }
}
