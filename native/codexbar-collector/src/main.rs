use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
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
}

#[derive(Debug, Parser)]
struct SnapshotArgs {
    #[arg(long, default_value = "json")]
    format: String,
    #[arg(long)]
    codex_home: Option<PathBuf>,
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
    }

    Ok(())
}
