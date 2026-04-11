pub mod accounts;

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Duration, FixedOffset, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};

const CACHE_TTL_SECONDS: u64 = 15;

#[derive(Debug, Clone)]
pub struct SnapshotOptions {
    pub now: DateTime<FixedOffset>,
    pub use_cache: bool,
    pub ttl: StdDuration,
    pub paths: BuildPaths,
}

#[derive(Debug, Clone)]
pub struct BuildPaths {
    pub codex_home: PathBuf,
    pub extra_codex_homes: Vec<PathBuf>,
    pub claude_stats_path: PathBuf,
    pub claude_projects_path: PathBuf,
    pub cache_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PanelSnapshotV1 {
    pub generated_at: String,
    pub total_tokens: u64,
    pub formatted_total_tokens: String,
    pub tokens_today: u64,
    pub tokens_7d: u64,
    pub tokens_30d: u64,
    pub sources: Vec<PanelSourceSnapshot>,
    pub available_source_count: u32,
    pub unavailable_source_count: u32,
    pub status: SnapshotStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PanelSourceSnapshot {
    pub id: SourceId,
    pub label: String,
    pub total_tokens: u64,
    pub formatted_total_tokens: String,
    pub available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_data_at: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotStatus {
    Ok,
    Partial,
    Error,
    Stale,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum SourceId {
    Codex,
    ClaudeCode,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
struct SourceSignatures {
    codex_db_mtime_ms: Option<u128>,
    #[serde(default)]
    extra_codex_db_signatures: Vec<CodexDbSignature>,
    claude_stats_mtime_ms: Option<u128>,
    #[serde(default)]
    claude_projects: ClaudeProjectsSignature,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct CodexDbSignature {
    path: String,
    mtime_ms: Option<u128>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
struct ClaudeProjectsSignature {
    latest_jsonl_mtime_ms: Option<u128>,
    jsonl_file_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CacheEnvelope {
    saved_at: String,
    source_signatures: SourceSignatures,
    snapshot: PanelSnapshotV1,
}

#[derive(Debug, Clone)]
struct SourceSnapshot {
    id: SourceId,
    label: &'static str,
    available: bool,
    total_tokens: u64,
    tokens_today: u64,
    tokens_7d: u64,
    tokens_30d: u64,
    latest_data_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeStatsFile {
    #[serde(default)]
    last_computed_date: Option<String>,
    #[serde(default)]
    daily_model_tokens: Vec<ClaudeDailyRow>,
    #[serde(default)]
    model_usage: HashMap<String, ClaudeModelUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeDailyRow {
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    tokens_by_model: HashMap<String, u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeModelUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeProjectEvent {
    #[serde(default)]
    message: Option<ClaudeProjectMessage>,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    uuid: Option<String>,
    #[serde(default)]
    timestamp: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeProjectMessage {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    usage: Option<ClaudeProjectUsage>,
}

#[derive(Debug, Deserialize)]
struct ClaudeProjectUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

#[derive(Debug, Clone, Default)]
struct ClaudeAggregate {
    total_tokens: u64,
    tokens_today: u64,
    tokens_7d: u64,
    tokens_30d: u64,
    latest_data_at: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct ClaudeBaseline {
    aggregate: ClaudeAggregate,
    last_computed_date: Option<NaiveDate>,
}

#[derive(Debug, Clone, Default)]
struct ClaudeProjectScan {
    aggregate: ClaudeAggregate,
    latest_data_at: Option<String>,
}

#[derive(Debug, Clone)]
struct ClaudeProjectUsageEntry {
    usage_tokens: u64,
    timestamp: String,
    day: NaiveDate,
}

impl SnapshotOptions {
    pub fn from_paths(paths: BuildPaths) -> Self {
        Self {
            now: Local::now().fixed_offset(),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        }
    }
}

impl Default for SnapshotOptions {
    fn default() -> Self {
        Self::from_paths(BuildPaths::default())
    }
}

impl Default for BuildPaths {
    fn default() -> Self {
        let home_dir = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        let cache_root = dirs::cache_dir().unwrap_or_else(|| home_dir.join(".cache"));

        Self {
            codex_home: std::env::var_os("CODEX_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home_dir.join(".codex")),
            extra_codex_homes: default_extra_codex_homes(),
            claude_stats_path: home_dir.join(".claude").join("stats-cache.json"),
            claude_projects_path: home_dir.join(".claude").join("projects"),
            cache_path: cache_root.join("codexbar").join("panel-snapshot-v1.json"),
        }
    }
}

pub fn load_snapshot(options: &SnapshotOptions) -> Result<PanelSnapshotV1> {
    let signatures = collect_source_signatures(&options.paths)?;
    let cached = read_cache(&options.paths.cache_path).ok();

    if options.use_cache
        && let Some(envelope) = cached.as_ref()
        && is_cache_valid(envelope, &signatures, options.now, options.ttl)
    {
        return Ok(envelope.snapshot.clone());
    }

    match build_fresh_snapshot(options) {
        Ok(snapshot) => {
            if options.use_cache
                && let Err(error) = write_cache(
                    &options.paths.cache_path,
                    &signatures,
                    &snapshot,
                    options.now,
                )
            {
                eprintln!("codexbar-collector: failed to write cache: {error}");
            }

            Ok(snapshot)
        }
        Err(error) => {
            if let Some(mut envelope) = cached {
                envelope.snapshot.status = SnapshotStatus::Stale;
                envelope.snapshot.error = Some(error.to_string());
                return Ok(envelope.snapshot);
            }

            Err(error)
        }
    }
}

pub fn build_fresh_snapshot(options: &SnapshotOptions) -> Result<PanelSnapshotV1> {
    let mut sources = Vec::new();

    sources.push(read_source_safely(SourceId::Codex, || {
        read_codex_source(
            &options.paths.codex_home,
            &options.paths.extra_codex_homes,
            options.now,
        )
    }));
    sources.push(read_source_safely(SourceId::ClaudeCode, || {
        read_claude_source(
            &options.paths.claude_stats_path,
            &options.paths.claude_projects_path,
            options.now,
        )
    }));

    if sources.iter().all(|source| !source.available) {
        bail!("No panel sources are available");
    }

    let total_tokens = sources.iter().map(|source| source.total_tokens).sum();
    let tokens_today = sources.iter().map(|source| source.tokens_today).sum();
    let tokens_7d = sources.iter().map(|source| source.tokens_7d).sum();
    let tokens_30d = sources.iter().map(|source| source.tokens_30d).sum();
    let unavailable_source_count = sources.iter().filter(|source| !source.available).count() as u32;
    let available_source_count = sources.len() as u32 - unavailable_source_count;

    Ok(PanelSnapshotV1 {
        generated_at: options.now.to_rfc3339(),
        total_tokens,
        formatted_total_tokens: format_token_count(total_tokens),
        tokens_today,
        tokens_7d,
        tokens_30d,
        sources: sources
            .into_iter()
            .map(|source| PanelSourceSnapshot {
                id: source.id,
                label: source.label.to_string(),
                total_tokens: source.total_tokens,
                formatted_total_tokens: format_token_count(source.total_tokens),
                available: source.available,
                latest_data_at: source.latest_data_at,
            })
            .collect(),
        available_source_count,
        unavailable_source_count,
        status: if unavailable_source_count == 0 {
            SnapshotStatus::Ok
        } else {
            SnapshotStatus::Partial
        },
        error: None,
    })
}

fn read_source_safely(
    source_id: SourceId,
    reader: impl FnOnce() -> Result<SourceSnapshot>,
) -> SourceSnapshot {
    match reader() {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!(
                "codexbar-collector: {} unavailable: {error}",
                source_id.label()
            );
            SourceSnapshot {
                id: source_id,
                label: source_id.label(),
                available: false,
                total_tokens: 0,
                tokens_today: 0,
                tokens_7d: 0,
                tokens_30d: 0,
                latest_data_at: None,
            }
        }
    }
}

fn read_codex_source(
    codex_home: &Path,
    extra_codex_homes: &[PathBuf],
    now: DateTime<FixedOffset>,
) -> Result<SourceSnapshot> {
    let mut codex_homes = Vec::with_capacity(1 + extra_codex_homes.len());
    codex_homes.push(codex_home.to_path_buf());
    codex_homes.extend(extra_codex_homes.iter().cloned());
    codex_homes = dedupe_paths(codex_homes);

    let mut total_tokens = 0_u64;
    let mut tokens_today = 0_u64;
    let mut tokens_7d = 0_u64;
    let mut tokens_30d = 0_u64;
    let mut latest_timestamp: Option<i64> = None;
    let mut loaded_count = 0_u32;
    let mut attempted_count = 0_u32;

    for home in &codex_homes {
        if !home.exists() {
            continue;
        }

        attempted_count += 1;
        match read_single_codex_home(home, now) {
            Ok(snapshot) => {
                loaded_count += 1;
                total_tokens += snapshot.total_tokens;
                tokens_today += snapshot.tokens_today;
                tokens_7d += snapshot.tokens_7d;
                tokens_30d += snapshot.tokens_30d;
                if latest_timestamp.is_none_or(|current| snapshot.latest_timestamp > current) {
                    latest_timestamp = Some(snapshot.latest_timestamp);
                }
            }
            Err(error) => {
                eprintln!(
                    "codexbar-collector: skipped Codex home {}: {error:#}",
                    home.display()
                );
            }
        }
    }

    if loaded_count == 0 {
        if attempted_count == 0 {
            bail!(
                "No Codex homes found. Checked: {}",
                codex_homes
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        bail!("No usable Codex databases found");
    }

    Ok(SourceSnapshot {
        id: SourceId::Codex,
        label: SourceId::Codex.label(),
        available: true,
        total_tokens,
        tokens_today,
        tokens_7d,
        tokens_30d,
        latest_data_at: latest_timestamp.map(|timestamp| iso_from_unix(timestamp, now.offset())),
    })
}

struct CodexHomeSnapshot {
    total_tokens: u64,
    tokens_today: u64,
    tokens_7d: u64,
    tokens_30d: u64,
    latest_timestamp: i64,
}

fn read_single_codex_home(
    codex_home: &Path,
    now: DateTime<FixedOffset>,
) -> Result<CodexHomeSnapshot> {
    if !codex_home.exists() {
        bail!("Codex home not found: {}", codex_home.display());
    }

    let db_path = find_latest_state_db(codex_home)?;
    let db = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("Failed to open Codex database {}", db_path.display()))?;
    let window = day_window(now);

    let total_tokens: u64 = db
        .query_row(
            "SELECT COALESCE(SUM(tokens_used), 0) FROM threads",
            [],
            |row| row.get::<_, i64>(0),
        )
        .context("Failed to query Codex total tokens")?
        .max(0) as u64;

    let (tokens_today, tokens_7d, tokens_30d): (u64, u64, u64) = db
        .query_row(
            "
            SELECT
              COALESCE(SUM(CASE WHEN updated_at >= ?1 THEN tokens_used ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN updated_at >= ?2 THEN tokens_used ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN updated_at >= ?3 THEN tokens_used ELSE 0 END), 0)
            FROM threads
            ",
            (
                window.today_start.timestamp(),
                window.day7_start.timestamp(),
                window.day30_start.timestamp(),
            ),
            |row| {
                Ok((
                    row.get::<_, i64>(0)?.max(0) as u64,
                    row.get::<_, i64>(1)?.max(0) as u64,
                    row.get::<_, i64>(2)?.max(0) as u64,
                ))
            },
        )
        .context("Failed to query Codex time windows")?;

    let latest_timestamp = db
        .query_row("SELECT MAX(updated_at) FROM threads", [], |row| {
            row.get::<_, Option<i64>>(0)
        })
        .context("Failed to query Codex latest timestamp")?
        .ok_or_else(|| anyhow!("Codex threads table is empty in {}", db_path.display()))?;

    Ok(CodexHomeSnapshot {
        total_tokens,
        tokens_today,
        tokens_7d,
        tokens_30d,
        latest_timestamp,
    })
}

fn read_claude_source(
    stats_path: &Path,
    projects_path: &Path,
    now: DateTime<FixedOffset>,
) -> Result<SourceSnapshot> {
    let baseline = read_claude_stats_baseline(stats_path, now);
    let project_cutoff = baseline
        .as_ref()
        .ok()
        .and_then(|snapshot| snapshot.last_computed_date);
    let project_scan = read_claude_project_usage(projects_path, now, project_cutoff);

    let mut available_inputs = 0_u32;
    let mut errors = Vec::new();
    let mut aggregate = ClaudeAggregate::default();

    match baseline {
        Ok(snapshot) => {
            available_inputs += 1;
            merge_claude_aggregate(&mut aggregate, &snapshot.aggregate);
        }
        Err(error) => errors.push(error.to_string()),
    }

    match project_scan {
        Ok(scan) => {
            available_inputs += 1;
            merge_claude_aggregate(&mut aggregate, &scan.aggregate);
            update_latest_iso(&mut aggregate.latest_data_at, scan.latest_data_at);
        }
        Err(error) => errors.push(error.to_string()),
    }

    if available_inputs == 0 {
        bail!("{}", errors.join("; "));
    }

    Ok(SourceSnapshot {
        id: SourceId::ClaudeCode,
        label: SourceId::ClaudeCode.label(),
        available: true,
        total_tokens: aggregate.total_tokens,
        tokens_today: aggregate.tokens_today,
        tokens_7d: aggregate.tokens_7d,
        tokens_30d: aggregate.tokens_30d,
        latest_data_at: aggregate.latest_data_at,
    })
}

fn read_claude_stats_baseline(
    stats_path: &Path,
    now: DateTime<FixedOffset>,
) -> Result<ClaudeBaseline> {
    if !stats_path.exists() {
        bail!("Claude stats file not found: {}", stats_path.display());
    }

    let raw = fs::read_to_string(stats_path)
        .with_context(|| format!("Failed to read Claude stats {}", stats_path.display()))?;
    if raw.trim().is_empty() {
        bail!("Claude stats file is empty: {}", stats_path.display());
    }

    let parsed: ClaudeStatsFile =
        serde_json::from_str(&raw).context("Failed to parse Claude stats JSON")?;
    let window = day_window(now);
    let mut baseline = ClaudeBaseline {
        last_computed_date: parsed
            .last_computed_date
            .as_deref()
            .and_then(|value| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()),
        ..ClaudeBaseline::default()
    };

    update_latest_iso(
        &mut baseline.aggregate.latest_data_at,
        parsed
            .last_computed_date
            .as_deref()
            .and_then(|day| iso_from_day(day, now.offset())),
    );

    for row in &parsed.daily_model_tokens {
        let Some(day) = row.date.as_deref() else {
            continue;
        };
        let Ok(day_value) = NaiveDate::parse_from_str(day, "%Y-%m-%d") else {
            continue;
        };

        accumulate_claude_usage(
            &mut baseline.aggregate,
            row.tokens_by_model.values().copied().sum::<u64>(),
            day_value,
            &window,
        );
        update_latest_iso(
            &mut baseline.aggregate.latest_data_at,
            iso_from_day(day, now.offset()),
        );
    }

    baseline.aggregate.total_tokens = parsed
        .model_usage
        .values()
        .map(claude_stats_usage_tokens)
        .sum();

    Ok(baseline)
}

fn read_claude_project_usage(
    projects_path: &Path,
    now: DateTime<FixedOffset>,
    cutoff_date: Option<NaiveDate>,
) -> Result<ClaudeProjectScan> {
    if !projects_path.exists() {
        bail!("Claude project logs not found: {}", projects_path.display());
    }

    let files = collect_jsonl_files(projects_path)?;
    if files.is_empty() {
        bail!("Claude project logs are empty: {}", projects_path.display());
    }

    let mut entries = HashMap::<String, ClaudeProjectUsageEntry>::new();
    let mut latest_data_at = None;

    for path in files {
        let file = fs::File::open(&path)
            .with_context(|| format!("Failed to open Claude project log {}", path.display()))?;
        let reader = BufReader::new(file);

        for line in reader.lines() {
            let line = line
                .with_context(|| format!("Failed to read Claude project log {}", path.display()))?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let Ok(event) = serde_json::from_str::<ClaudeProjectEvent>(trimmed) else {
                continue;
            };
            let Some(message) = event.message.as_ref() else {
                continue;
            };
            if message.role.as_deref() != Some("assistant") {
                continue;
            }
            let Some(usage) = message.usage.as_ref() else {
                continue;
            };
            let Some(timestamp) = event.timestamp.as_deref() else {
                continue;
            };
            let Ok(parsed_timestamp) = DateTime::parse_from_rfc3339(timestamp) else {
                continue;
            };

            let local_timestamp = parsed_timestamp.with_timezone(now.offset());
            let local_iso = local_timestamp.to_rfc3339();
            let local_day = local_timestamp.date_naive();
            let usage_tokens = claude_project_usage_tokens(usage);
            let key = message
                .id
                .as_deref()
                .or(event.request_id.as_deref())
                .or(event.uuid.as_deref())
                .unwrap_or(timestamp)
                .to_string();

            update_latest_iso(&mut latest_data_at, Some(local_iso.clone()));

            let should_replace = match entries.get(&key) {
                Some(existing) => {
                    usage_tokens > existing.usage_tokens
                        || (usage_tokens == existing.usage_tokens && local_iso > existing.timestamp)
                }
                None => true,
            };

            if should_replace {
                entries.insert(
                    key,
                    ClaudeProjectUsageEntry {
                        usage_tokens,
                        timestamp: local_iso,
                        day: local_day,
                    },
                );
            }
        }
    }

    let window = day_window(now);
    let mut aggregate = ClaudeAggregate::default();

    for entry in entries.values() {
        if cutoff_date.is_some_and(|cutoff| entry.day <= cutoff) {
            continue;
        }

        aggregate.total_tokens += entry.usage_tokens;
        accumulate_claude_usage(&mut aggregate, entry.usage_tokens, entry.day, &window);
    }

    Ok(ClaudeProjectScan {
        aggregate,
        latest_data_at,
    })
}

fn collect_claude_projects_signature(projects_path: &Path) -> Result<ClaudeProjectsSignature> {
    let files = collect_jsonl_files(projects_path)?;
    let mut latest_jsonl_mtime_ms = None;

    for path in &files {
        let mtime = file_modified_ms(Some(path.as_path()))?;
        if latest_jsonl_mtime_ms.is_none_or(|current| mtime > Some(current)) {
            latest_jsonl_mtime_ms = mtime;
        }
    }

    Ok(ClaudeProjectsSignature {
        latest_jsonl_mtime_ms,
        jsonl_file_count: files.len() as u64,
    })
}

fn collect_jsonl_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    if !root.exists() {
        return Ok(files);
    }

    collect_jsonl_files_recursive(root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_jsonl_files_recursive(root: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root).with_context(|| format!("Failed to read {}", root.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files_recursive(&path, files)?;
            continue;
        }

        if path.extension() == Some(OsStr::new("jsonl")) {
            files.push(path);
        }
    }

    Ok(())
}

fn merge_claude_aggregate(target: &mut ClaudeAggregate, extra: &ClaudeAggregate) {
    target.total_tokens += extra.total_tokens;
    target.tokens_today += extra.tokens_today;
    target.tokens_7d += extra.tokens_7d;
    target.tokens_30d += extra.tokens_30d;
    update_latest_iso(&mut target.latest_data_at, extra.latest_data_at.clone());
}

fn update_latest_iso(latest: &mut Option<String>, candidate: Option<String>) {
    if let Some(candidate) = candidate
        && latest.as_ref().is_none_or(|current| candidate > *current)
    {
        *latest = Some(candidate);
    }
}

fn accumulate_claude_usage(
    aggregate: &mut ClaudeAggregate,
    usage_tokens: u64,
    day: NaiveDate,
    window: &DayWindow,
) {
    if day == window.today_start.date_naive() {
        aggregate.tokens_today += usage_tokens;
    }
    if day >= window.day7_start.date_naive() {
        aggregate.tokens_7d += usage_tokens;
    }
    if day >= window.day30_start.date_naive() {
        aggregate.tokens_30d += usage_tokens;
    }
}

fn claude_stats_usage_tokens(usage: &ClaudeModelUsage) -> u64 {
    usage.input_tokens
        + usage.output_tokens
        + usage.cache_read_input_tokens
        + usage.cache_creation_input_tokens
}

fn claude_project_usage_tokens(usage: &ClaudeProjectUsage) -> u64 {
    usage.input_tokens
        + usage.output_tokens
        + usage.cache_read_input_tokens
        + usage.cache_creation_input_tokens
}

fn collect_source_signatures(paths: &BuildPaths) -> Result<SourceSignatures> {
    Ok(SourceSignatures {
        codex_db_mtime_ms: file_modified_ms(
            find_latest_state_db(&paths.codex_home).ok().as_deref(),
        )?,
        extra_codex_db_signatures: collect_extra_codex_signatures(&paths.extra_codex_homes)?,
        claude_stats_mtime_ms: file_modified_ms(Some(paths.claude_stats_path.as_path()))?,
        claude_projects: collect_claude_projects_signature(&paths.claude_projects_path)?,
    })
}

fn collect_extra_codex_signatures(extra_codex_homes: &[PathBuf]) -> Result<Vec<CodexDbSignature>> {
    let mut signatures = Vec::new();

    for home in dedupe_paths(extra_codex_homes.to_vec()) {
        let db_path = find_latest_state_db(&home).ok();
        signatures.push(CodexDbSignature {
            path: home.display().to_string(),
            mtime_ms: file_modified_ms(db_path.as_deref())?,
        });
    }

    Ok(signatures)
}

fn file_modified_ms(path: Option<&Path>) -> Result<Option<u128>> {
    let Some(path) = path else {
        return Ok(None);
    };

    if !path.exists() {
        return Ok(None);
    }

    let modified = fs::metadata(path)
        .with_context(|| format!("Failed to stat {}", path.display()))?
        .modified()
        .with_context(|| format!("Failed to read mtime for {}", path.display()))?;

    Ok(Some(
        modified
            .duration_since(UNIX_EPOCH)
            .unwrap_or_else(|_| StdDuration::from_secs(0))
            .as_millis(),
    ))
}

fn write_cache(
    cache_path: &Path,
    signatures: &SourceSignatures,
    snapshot: &PanelSnapshotV1,
    now: DateTime<FixedOffset>,
) -> Result<()> {
    if let Some(parent) = cache_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create cache directory {}", parent.display()))?;
    }

    let payload = CacheEnvelope {
        saved_at: now.to_rfc3339(),
        source_signatures: signatures.clone(),
        snapshot: snapshot.clone(),
    };

    let serialized =
        serde_json::to_string_pretty(&payload).context("Failed to encode cache JSON")?;
    let temp_path = cache_path.with_extension("tmp");
    fs::write(&temp_path, serialized)
        .with_context(|| format!("Failed to write {}", temp_path.display()))?;
    fs::rename(&temp_path, cache_path)
        .with_context(|| format!("Failed to move cache into {}", cache_path.display()))?;

    Ok(())
}

fn read_cache(cache_path: &Path) -> Result<CacheEnvelope> {
    let raw = fs::read_to_string(cache_path)
        .with_context(|| format!("Failed to read {}", cache_path.display()))?;
    serde_json::from_str(&raw).context("Failed to parse cache JSON")
}

fn is_cache_valid(
    envelope: &CacheEnvelope,
    signatures: &SourceSignatures,
    now: DateTime<FixedOffset>,
    ttl: StdDuration,
) -> bool {
    if envelope.source_signatures != *signatures {
        return false;
    }

    let Ok(saved_at) = DateTime::parse_from_rfc3339(&envelope.saved_at) else {
        return false;
    };

    let Ok(max_age) = Duration::from_std(ttl) else {
        return false;
    };

    now.signed_duration_since(saved_at) < max_age
}

fn format_token_count(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);

    for (index, ch) in digits.chars().rev().enumerate() {
        if index > 0 && index % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }

    out.chars().rev().collect()
}

fn default_extra_codex_homes() -> Vec<PathBuf> {
    let mut paths = std::env::var_os("CODEXBAR_EXTRA_CODEX_HOMES")
        .map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
        .unwrap_or_default();

    paths.extend(discover_windows_codex_homes());
    dedupe_paths(paths)
}

fn discover_windows_codex_homes() -> Vec<PathBuf> {
    let users_dir = Path::new("/mnt/c/Users");
    let Ok(entries) = fs::read_dir(users_dir) else {
        return Vec::new();
    };

    let mut homes = Vec::new();
    for entry in entries.flatten() {
        let candidate = entry.path().join(".codex");
        if find_latest_state_db(&candidate).is_ok() {
            homes.push(candidate);
        }
    }

    homes
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();

    for path in paths {
        if !unique.iter().any(|existing| existing == &path) {
            unique.push(path);
        }
    }

    unique
}

fn find_latest_state_db(codex_home: &Path) -> Result<PathBuf> {
    let entries = fs::read_dir(codex_home)
        .with_context(|| format!("Failed to read {}", codex_home.display()))?;
    let mut matches: Vec<(u64, PathBuf)> = Vec::new();

    for entry in entries {
        let entry = entry?;
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();

        if let Some(number) = file_name
            .strip_prefix("state_")
            .and_then(|suffix| suffix.strip_suffix(".sqlite"))
            .and_then(|suffix| suffix.parse::<u64>().ok())
        {
            matches.push((number, entry.path()));
        }
    }

    matches.sort_by(|left, right| right.0.cmp(&left.0));
    matches
        .into_iter()
        .next()
        .map(|(_, path)| path)
        .ok_or_else(|| {
            anyhow!(
                "No state_*.sqlite database found in {}",
                codex_home.display()
            )
        })
}

fn iso_from_unix(timestamp: i64, offset: &FixedOffset) -> String {
    offset
        .timestamp_opt(timestamp, 0)
        .single()
        .unwrap_or_else(|| {
            offset
                .timestamp_millis_opt(0)
                .single()
                .expect("epoch timestamp")
        })
        .to_rfc3339()
}

fn iso_from_day(day: &str, offset: &FixedOffset) -> Option<String> {
    let day = NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()?;
    let end_of_day = day.and_hms_opt(23, 59, 59)?;
    Some(
        offset
            .from_local_datetime(&end_of_day)
            .single()?
            .to_rfc3339(),
    )
}

struct DayWindow {
    today_start: DateTime<FixedOffset>,
    day7_start: DateTime<FixedOffset>,
    day30_start: DateTime<FixedOffset>,
}

fn day_window(now: DateTime<FixedOffset>) -> DayWindow {
    let start_naive = now
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .expect("valid midnight timestamp");
    let today_start = now
        .offset()
        .from_local_datetime(&start_naive)
        .single()
        .expect("fixed offset midnight");

    DayWindow {
        today_start,
        day7_start: today_start - Duration::days(6),
        day30_start: today_start - Duration::days(29),
    }
}

impl SourceId {
    fn label(self) -> &'static str {
        match self {
            SourceId::Codex => "Codex",
            SourceId::ClaudeCode => "Claude Code",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs::File;
    use std::io::Write;

    use rusqlite::params;
    use tempfile::TempDir;

    fn test_now() -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339("2026-03-22T12:00:00+08:00").expect("valid timestamp")
    }

    fn build_test_paths(root: &TempDir) -> BuildPaths {
        BuildPaths {
            codex_home: root.path().join(".codex"),
            extra_codex_homes: Vec::new(),
            claude_stats_path: root.path().join(".claude").join("stats-cache.json"),
            claude_projects_path: root.path().join(".claude").join("projects"),
            cache_path: root.path().join(".cache").join("panel-snapshot-v1.json"),
        }
    }

    fn unix(value: &str) -> i64 {
        DateTime::parse_from_rfc3339(value)
            .expect("valid timestamp")
            .timestamp()
    }

    fn create_codex_fixture(root: &TempDir) -> Result<()> {
        create_codex_fixture_at(&root.path().join(".codex"), 200, 100)
    }

    fn create_codex_fixture_at(
        codex_home: &Path,
        active_tokens: i64,
        archived_tokens: i64,
    ) -> Result<()> {
        fs::create_dir_all(codex_home)?;

        let db = Connection::open(codex_home.join("state_1.sqlite"))?;
        db.execute_batch(
            "
            CREATE TABLE threads (
              id TEXT PRIMARY KEY,
              rollout_path TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              source TEXT NOT NULL,
              model_provider TEXT NOT NULL,
              cwd TEXT NOT NULL,
              title TEXT NOT NULL,
              sandbox_policy TEXT NOT NULL,
              approval_mode TEXT NOT NULL,
              tokens_used INTEGER NOT NULL DEFAULT 0,
              has_user_event INTEGER NOT NULL DEFAULT 0,
              archived INTEGER NOT NULL DEFAULT 0,
              archived_at INTEGER,
              git_sha TEXT,
              git_branch TEXT,
              git_origin_url TEXT,
              cli_version TEXT NOT NULL DEFAULT '',
              first_user_message TEXT NOT NULL DEFAULT '',
              agent_nickname TEXT,
              agent_role TEXT,
              memory_mode TEXT NOT NULL DEFAULT 'enabled'
            );
            ",
        )?;

        db.execute(
            "
            INSERT INTO threads (
              id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
              sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
              git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
              agent_role, memory_mode
            ) VALUES (?1, ?2, ?3, ?4, 'local', 'openai', '/workspace/alpha', 'Active thread',
              'workspace-write', 'never', ?5, 1, 0, NULL, NULL, NULL, NULL, '1.0.0', 'hello',
              NULL, NULL, 'enabled')
            ",
            params![
                "thread-1",
                codex_home.join("session.jsonl").display().to_string(),
                unix("2026-03-22T09:50:00+08:00"),
                unix("2026-03-22T10:00:00+08:00"),
                active_tokens,
            ],
        )?;
        db.execute(
            "
            INSERT INTO threads (
              id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
              sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
              git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
              agent_role, memory_mode
            ) VALUES (?1, ?2, ?3, ?4, 'local', 'openai', '/workspace/beta', 'Archived thread',
              'workspace-write', 'never', ?5, 1, 1, ?6, NULL, NULL, NULL, '1.0.0', 'hi',
              NULL, NULL, 'enabled')
            ",
            params![
                "thread-2",
                codex_home.join("session.jsonl").display().to_string(),
                unix("2026-03-20T09:00:00+08:00"),
                unix("2026-03-20T09:00:00+08:00"),
                archived_tokens,
                unix("2026-03-21T09:00:00+08:00"),
            ],
        )?;

        Ok(())
    }

    fn create_claude_fixture(root: &TempDir) -> Result<()> {
        let claude_dir = root.path().join(".claude");
        fs::create_dir_all(&claude_dir)?;
        fs::write(
            claude_dir.join("stats-cache.json"),
            serde_json::json!({
                "version": 1,
                "lastComputedDate": "2026-03-22",
                "dailyModelTokens": [
                    {
                        "date": "2026-03-22",
                        "tokensByModel": { "opus": 50 }
                    },
                    {
                        "date": "2026-03-21",
                        "tokensByModel": { "opus": 40 }
                    },
                    {
                        "date": "2026-03-01",
                        "tokensByModel": { "opus": 10 }
                    }
                ],
                "modelUsage": {
                    "opus": {
                        "inputTokens": 100,
                        "outputTokens": 20,
                        "cacheReadInputTokens": 30,
                        "cacheCreationInputTokens": 10
                    }
                }
            })
            .to_string(),
        )?;

        Ok(())
    }

    fn write_claude_project_log(
        root: &TempDir,
        relative_path: &str,
        events: &[serde_json::Value],
    ) -> Result<()> {
        let path = root
            .path()
            .join(".claude")
            .join("projects")
            .join(relative_path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let mut file = File::create(path)?;
        for event in events {
            writeln!(file, "{}", serde_json::to_string(event)?)?;
        }

        Ok(())
    }

    fn claude_project_event(
        message_id: Option<&str>,
        request_id: Option<&str>,
        uuid: &str,
        timestamp: &str,
        usage: (u64, u64, u64, u64),
    ) -> serde_json::Value {
        let (input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens) =
            usage;
        serde_json::json!({
            "message": {
                "role": "assistant",
                "id": message_id,
                "usage": {
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                    "cache_read_input_tokens": cache_read_input_tokens,
                    "cache_creation_input_tokens": cache_creation_input_tokens
                }
            },
            "requestId": request_id,
            "uuid": uuid,
            "timestamp": timestamp
        })
    }

    #[test]
    fn build_fresh_snapshot_merges_sources_and_formats_counts() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        create_claude_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(snapshot.total_tokens, 460);
        assert_eq!(snapshot.formatted_total_tokens, "460");
        assert_eq!(snapshot.tokens_today, 250);
        assert_eq!(snapshot.tokens_7d, 390);
        assert_eq!(snapshot.tokens_30d, 400);
        assert_eq!(snapshot.available_source_count, 2);
        assert_eq!(snapshot.unavailable_source_count, 0);
        assert_eq!(snapshot.status, SnapshotStatus::Ok);
        assert_eq!(
            snapshot
                .sources
                .iter()
                .map(|source| source.total_tokens)
                .collect::<Vec<_>>(),
            vec![300, 160]
        );

        Ok(())
    }

    #[test]
    fn build_fresh_snapshot_aggregates_multiple_codex_homes() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let windows_codex_home = root
            .path()
            .join("mnt")
            .join("c")
            .join("Users")
            .join("k")
            .join(".codex");
        create_codex_fixture_at(&windows_codex_home, 40, 20)?;
        create_claude_fixture(&root)?;

        let mut paths = build_test_paths(&root);
        paths.extra_codex_homes.push(windows_codex_home);

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(snapshot.total_tokens, 520);
        assert_eq!(snapshot.tokens_today, 290);
        assert_eq!(snapshot.tokens_7d, 450);
        assert_eq!(snapshot.tokens_30d, 460);
        assert_eq!(snapshot.sources[0].total_tokens, 360);

        Ok(())
    }

    #[test]
    fn build_fresh_snapshot_marks_missing_sources_as_partial() -> Result<()> {
        let root = TempDir::new()?;
        create_claude_fixture(&root)?;

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: build_test_paths(&root),
        })?;

        assert_eq!(snapshot.total_tokens, 160);
        assert_eq!(snapshot.tokens_today, 50);
        assert_eq!(snapshot.available_source_count, 1);
        assert_eq!(snapshot.unavailable_source_count, 1);
        assert_eq!(snapshot.status, SnapshotStatus::Partial);
        assert_eq!(snapshot.sources[0].available, false);
        assert_eq!(snapshot.sources[1].available, true);

        Ok(())
    }

    #[test]
    fn read_claude_source_merges_stats_with_project_increment() -> Result<()> {
        let root = TempDir::new()?;
        create_claude_fixture(&root)?;
        write_claude_project_log(
            &root,
            "workspace/session-main.jsonl",
            &[claude_project_event(
                Some("msg-1"),
                Some("req-1"),
                "uuid-1",
                "2026-03-23T01:00:00Z",
                (10, 2, 3, 5),
            )],
        )?;
        write_claude_project_log(
            &root,
            "workspace/subagents/agent-1.jsonl",
            &[claude_project_event(
                Some("msg-2"),
                Some("req-2"),
                "uuid-2",
                "2026-03-24T01:00:00Z",
                (10, 10, 5, 5),
            )],
        )?;

        let now = DateTime::parse_from_rfc3339("2026-03-24T12:00:00+08:00")?;
        let paths = build_test_paths(&root);
        let snapshot =
            read_claude_source(&paths.claude_stats_path, &paths.claude_projects_path, now)?;

        assert_eq!(snapshot.total_tokens, 210);
        assert_eq!(snapshot.tokens_today, 30);
        assert_eq!(snapshot.tokens_7d, 140);
        assert_eq!(snapshot.tokens_30d, 150);
        assert_eq!(
            snapshot.latest_data_at.as_deref(),
            Some("2026-03-24T09:00:00+08:00")
        );

        Ok(())
    }

    #[test]
    fn read_claude_project_usage_dedupes_repeated_message_ids() -> Result<()> {
        let root = TempDir::new()?;
        write_claude_project_log(
            &root,
            "workspace/session.jsonl",
            &[
                claude_project_event(
                    Some("dup"),
                    Some("req-1"),
                    "uuid-1",
                    "2026-03-24T00:10:00Z",
                    (1, 1, 1, 2),
                ),
                claude_project_event(
                    Some("dup"),
                    Some("req-1"),
                    "uuid-2",
                    "2026-03-24T00:11:00Z",
                    (3, 3, 3, 3),
                ),
                claude_project_event(
                    Some("dup"),
                    Some("req-1"),
                    "uuid-3",
                    "2026-03-24T00:12:00Z",
                    (2, 2, 2, 2),
                ),
                claude_project_event(
                    Some("unique"),
                    Some("req-2"),
                    "uuid-4",
                    "2026-03-24T00:13:00Z",
                    (1, 1, 0, 1),
                ),
            ],
        )?;

        let paths = build_test_paths(&root);
        let now = DateTime::parse_from_rfc3339("2026-03-24T12:00:00+08:00")?;
        let scan = read_claude_project_usage(&paths.claude_projects_path, now, None)?;

        assert_eq!(scan.aggregate.total_tokens, 15);
        assert_eq!(scan.aggregate.tokens_today, 15);
        assert_eq!(
            scan.latest_data_at.as_deref(),
            Some("2026-03-24T08:13:00+08:00")
        );

        Ok(())
    }

    #[test]
    fn read_claude_source_falls_back_to_projects_when_stats_missing() -> Result<()> {
        let root = TempDir::new()?;
        write_claude_project_log(
            &root,
            "workspace/session.jsonl",
            &[
                claude_project_event(
                    Some("msg-a"),
                    Some("req-a"),
                    "uuid-a",
                    "2026-03-21T01:00:00Z",
                    (5, 5, 3, 2),
                ),
                claude_project_event(
                    Some("msg-b"),
                    Some("req-b"),
                    "uuid-b",
                    "2026-03-22T01:00:00Z",
                    (10, 10, 3, 2),
                ),
            ],
        )?;

        let paths = build_test_paths(&root);
        let snapshot = read_claude_source(
            &paths.claude_stats_path,
            &paths.claude_projects_path,
            test_now(),
        )?;

        assert_eq!(snapshot.total_tokens, 40);
        assert_eq!(snapshot.tokens_today, 25);
        assert_eq!(snapshot.tokens_7d, 40);
        assert_eq!(snapshot.tokens_30d, 40);
        assert_eq!(
            snapshot.latest_data_at.as_deref(),
            Some("2026-03-22T09:00:00+08:00")
        );

        Ok(())
    }

    #[test]
    fn cache_validation_and_stale_fallback_work() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        create_claude_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = load_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: paths.clone(),
        })?;
        assert_eq!(snapshot.total_tokens, 460);

        let cache = read_cache(&paths.cache_path)?;
        let signatures = collect_source_signatures(&paths)?;
        assert!(is_cache_valid(
            &cache,
            &signatures,
            test_now() + Duration::seconds(5),
            StdDuration::from_secs(CACHE_TTL_SECONDS)
        ));

        fs::remove_file(&paths.codex_home.join("state_1.sqlite"))?;
        fs::remove_file(&paths.claude_stats_path)?;

        let stale_snapshot = load_snapshot(&SnapshotOptions {
            now: test_now() + Duration::seconds(20),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(stale_snapshot.status, SnapshotStatus::Stale);
        assert_eq!(stale_snapshot.total_tokens, 460);
        assert!(
            stale_snapshot
                .error
                .as_deref()
                .is_some_and(|message| message.contains("No panel sources are available"))
        );

        Ok(())
    }

    #[test]
    fn format_token_count_inserts_grouping_separators() {
        assert_eq!(format_token_count(5_335_479_211), "5,335,479,211");
    }

    #[test]
    fn signatures_change_when_source_mtime_changes() -> Result<()> {
        let root = TempDir::new()?;
        create_claude_fixture(&root)?;
        let paths = build_test_paths(&root);
        let before = collect_source_signatures(&paths)?;

        std::thread::sleep(StdDuration::from_secs(1));
        let mut file = File::options()
            .append(true)
            .open(&paths.claude_stats_path)?;
        writeln!(file, " ")?;
        file.sync_all()?;

        let after = collect_source_signatures(&paths)?;
        assert_ne!(before.claude_stats_mtime_ms, after.claude_stats_mtime_ms);

        Ok(())
    }

    #[test]
    fn project_log_signatures_change_when_logs_change() -> Result<()> {
        let root = TempDir::new()?;
        write_claude_project_log(
            &root,
            "workspace/session.jsonl",
            &[claude_project_event(
                Some("msg-1"),
                Some("req-1"),
                "uuid-1",
                "2026-03-22T01:00:00Z",
                (1, 1, 1, 1),
            )],
        )?;
        let paths = build_test_paths(&root);
        let before = collect_source_signatures(&paths)?;

        std::thread::sleep(StdDuration::from_secs(1));
        write_claude_project_log(
            &root,
            "workspace/second-session.jsonl",
            &[claude_project_event(
                Some("msg-2"),
                Some("req-2"),
                "uuid-2",
                "2026-03-23T01:00:00Z",
                (2, 2, 2, 2),
            )],
        )?;

        let after = collect_source_signatures(&paths)?;
        assert_ne!(before.claude_projects, after.claude_projects);

        Ok(())
    }

    #[test]
    fn signatures_include_extra_codex_homes() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let extra_home = root.path().join("windows").join(".codex");
        create_codex_fixture_at(&extra_home, 10, 5)?;

        let mut paths = build_test_paths(&root);
        paths.extra_codex_homes.push(extra_home.clone());

        let signatures = collect_source_signatures(&paths)?;
        assert_eq!(signatures.extra_codex_db_signatures.len(), 1);
        assert_eq!(
            signatures.extra_codex_db_signatures[0].path,
            extra_home.display().to_string()
        );
        assert!(signatures.extra_codex_db_signatures[0].mtime_ms.is_some());

        Ok(())
    }
}
