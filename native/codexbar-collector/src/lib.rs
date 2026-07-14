pub mod accounts;
mod token_ledger;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Datelike, Duration, FixedOffset, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};

use crate::token_ledger::{UsageWindow, sync_and_query};

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
    pub cache_path: PathBuf,
    pub token_ledger_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PanelSnapshotV2 {
    pub generated_at: String,
    pub total_tokens: u64,
    pub formatted_total_tokens: String,
    pub tokens_today: u64,
    pub tokens_week: u64,
    pub tokens_month: u64,
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
struct SourceSignatures {
    codex_db_path: Option<String>,
    codex_db_mtime_ms: Option<u128>,
    #[serde(default)]
    extra_codex_db_signatures: Vec<CodexDbSignature>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct CodexDbSignature {
    path: String,
    mtime_ms: Option<u128>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CacheEnvelope {
    saved_at: String,
    source_signatures: SourceSignatures,
    snapshot: PanelSnapshotV2,
}

#[derive(Debug, Clone)]
struct SourceSnapshot {
    id: SourceId,
    label: &'static str,
    available: bool,
    total_tokens: u64,
    tokens_today: u64,
    tokens_week: u64,
    tokens_month: u64,
    latest_data_at: Option<String>,
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
            cache_path: cache_root.join("codexbar").join("panel-snapshot-v2.json"),
            token_ledger_path: cache_root.join("codexbar").join("token-ledger-v1.sqlite"),
        }
    }
}

pub fn load_snapshot(options: &SnapshotOptions) -> Result<PanelSnapshotV2> {
    let signatures = collect_source_signatures(&options.paths)?;
    let cached = if options.use_cache {
        read_cache(&options.paths.cache_path).ok()
    } else {
        None
    };

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

pub fn build_fresh_snapshot(options: &SnapshotOptions) -> Result<PanelSnapshotV2> {
    let mut sources = Vec::new();

    sources.push(read_source_safely(SourceId::Codex, || {
        read_codex_source(
            &options.paths.codex_home,
            &options.paths.extra_codex_homes,
            options.now,
            &options.paths.token_ledger_path,
        )
    }));

    if sources.iter().all(|source| !source.available) {
        bail!("No panel sources are available");
    }

    let total_tokens = sources.iter().map(|source| source.total_tokens).sum();
    let tokens_today = sources.iter().map(|source| source.tokens_today).sum();
    let tokens_week = sources.iter().map(|source| source.tokens_week).sum();
    let tokens_month = sources.iter().map(|source| source.tokens_month).sum();
    let unavailable_source_count = sources.iter().filter(|source| !source.available).count() as u32;
    let available_source_count = sources.len() as u32 - unavailable_source_count;

    Ok(PanelSnapshotV2 {
        generated_at: options.now.to_rfc3339(),
        total_tokens,
        formatted_total_tokens: format_token_count(total_tokens),
        tokens_today,
        tokens_week,
        tokens_month,
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
                tokens_week: 0,
                tokens_month: 0,
                latest_data_at: None,
            }
        }
    }
}

fn read_codex_source(
    codex_home: &Path,
    extra_codex_homes: &[PathBuf],
    now: DateTime<FixedOffset>,
    token_ledger_path: &Path,
) -> Result<SourceSnapshot> {
    let mut codex_homes = Vec::with_capacity(1 + extra_codex_homes.len());
    codex_homes.push(codex_home.to_path_buf());
    codex_homes.extend(extra_codex_homes.iter().cloned());
    codex_homes = dedupe_paths(codex_homes);

    let mut total_tokens = 0_u64;
    let mut tokens_today = 0_u64;
    let mut tokens_week = 0_u64;
    let mut tokens_month = 0_u64;
    let mut latest_timestamp: Option<i64> = None;
    let mut loaded_count = 0_u32;
    let mut attempted_count = 0_u32;

    for home in &codex_homes {
        if !home.exists() {
            continue;
        }

        attempted_count += 1;
        let home = fs::canonicalize(&home)
            .with_context(|| format!("Failed to canonicalize Codex home {}", home.display()))?;
        match read_single_codex_home(&home, now, token_ledger_path) {
            Ok(snapshot) => {
                loaded_count += 1;
                total_tokens += snapshot.total_tokens;
                tokens_today += snapshot.tokens_today;
                tokens_week += snapshot.tokens_week;
                tokens_month += snapshot.tokens_month;
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
        tokens_week,
        tokens_month,
        latest_data_at: latest_timestamp.map(|timestamp| iso_from_unix(timestamp, now.offset())),
    })
}

struct CodexHomeSnapshot {
    total_tokens: u64,
    tokens_today: u64,
    tokens_week: u64,
    tokens_month: u64,
    latest_timestamp: i64,
}

fn read_single_codex_home(
    codex_home: &Path,
    now: DateTime<FixedOffset>,
    token_ledger_path: &Path,
) -> Result<CodexHomeSnapshot> {
    if !codex_home.exists() {
        bail!("Codex home not found: {}", codex_home.display());
    }

    let db_path = find_latest_state_db(codex_home)?;
    let db = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("Failed to open Codex database {}", db_path.display()))?;
    let window = calendar_window(now);
    let totals = sync_and_query(
        codex_home,
        &db,
        token_ledger_path,
        UsageWindow {
            today_start_ms: window.today_start.timestamp_millis(),
            week_start_ms: window.week_start.timestamp_millis(),
            month_start_ms: window.month_start.timestamp_millis(),
        },
    )?;

    let latest_timestamp = db
        .query_row("SELECT MAX(updated_at) FROM threads", [], |row| {
            row.get::<_, Option<i64>>(0)
        })
        .context("Failed to query Codex latest timestamp")?
        .ok_or_else(|| anyhow!("Codex threads table is empty in {}", db_path.display()))?;

    Ok(CodexHomeSnapshot {
        total_tokens: totals.total_tokens,
        tokens_today: totals.tokens_today,
        tokens_week: totals.tokens_week,
        tokens_month: totals.tokens_month,
        latest_timestamp,
    })
}

fn collect_source_signatures(paths: &BuildPaths) -> Result<SourceSignatures> {
    let codex_db_path = find_latest_state_db(&paths.codex_home).ok();
    Ok(SourceSignatures {
        codex_db_path: codex_db_path
            .as_ref()
            .map(|path| path.display().to_string()),
        codex_db_mtime_ms: database_modified_ms(codex_db_path.as_deref())?,
        extra_codex_db_signatures: collect_extra_codex_signatures(&paths.extra_codex_homes)?,
    })
}

fn collect_extra_codex_signatures(extra_codex_homes: &[PathBuf]) -> Result<Vec<CodexDbSignature>> {
    let mut signatures = Vec::new();

    for home in dedupe_paths(extra_codex_homes.to_vec()) {
        let db_path = find_latest_state_db(&home).ok();
        signatures.push(CodexDbSignature {
            path: home.display().to_string(),
            mtime_ms: database_modified_ms(db_path.as_deref())?,
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

fn database_modified_ms(path: Option<&Path>) -> Result<Option<u128>> {
    let Some(path) = path else {
        return Ok(None);
    };
    let mut wal_path = path.as_os_str().to_os_string();
    wal_path.push("-wal");
    let wal_path = PathBuf::from(wal_path);
    Ok([
        file_modified_ms(Some(path))?,
        file_modified_ms(Some(&wal_path))?,
    ]
    .into_iter()
    .flatten()
    .max())
}

fn write_cache(
    cache_path: &Path,
    signatures: &SourceSignatures,
    snapshot: &PanelSnapshotV2,
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

#[derive(Debug)]
struct StateDbMatch {
    priority: usize,
    number: u64,
    path: PathBuf,
}

#[derive(Debug)]
struct StateDbCandidate {
    priority: usize,
    latest_timestamp: Option<i64>,
    modified_ms: u128,
    path: PathBuf,
}

fn find_latest_state_db(codex_home: &Path) -> Result<PathBuf> {
    let mut matches: Vec<StateDbMatch> = Vec::new();

    for (priority, dir) in state_db_search_dirs(codex_home).into_iter().enumerate() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };

        for entry in entries {
            let entry = entry?;
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();

            if let Some(number) = file_name
                .strip_prefix("state_")
                .and_then(|suffix| suffix.strip_suffix(".sqlite"))
                .and_then(|suffix| suffix.parse::<u64>().ok())
            {
                matches.push(StateDbMatch {
                    priority,
                    number,
                    path: entry.path(),
                });
            }
        }
    }

    let latest_number = matches
        .iter()
        .map(|candidate| candidate.number)
        .max()
        .ok_or_else(|| {
            anyhow!(
                "No state_*.sqlite database found in {} or its sqlite directory",
                codex_home.display()
            )
        })?;

    let mut candidates = Vec::new();
    for db_match in matches
        .into_iter()
        .filter(|db_match| db_match.number == latest_number)
    {
        candidates.push(StateDbCandidate {
            priority: db_match.priority,
            latest_timestamp: state_db_latest_timestamp(&db_match.path)?,
            modified_ms: file_modified_ms(Some(&db_match.path))?.unwrap_or(0),
            path: db_match.path,
        });
    }

    candidates.sort_by(|left, right| {
        right
            .latest_timestamp
            .cmp(&left.latest_timestamp)
            .then_with(|| right.modified_ms.cmp(&left.modified_ms))
            .then_with(|| left.priority.cmp(&right.priority))
    });

    candidates
        .into_iter()
        .next()
        .map(|candidate| candidate.path)
        .ok_or_else(|| {
            anyhow!(
                "No state_{}.sqlite database candidates found",
                latest_number
            )
        })
}

fn state_db_latest_timestamp(db_path: &Path) -> Result<Option<i64>> {
    let db = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("Failed to open Codex database {}", db_path.display()))?;
    db.query_row("SELECT MAX(updated_at) FROM threads", [], |row| {
        row.get::<_, Option<i64>>(0)
    })
    .with_context(|| {
        format!(
            "Failed to query Codex latest timestamp in {}",
            db_path.display()
        )
    })
}

fn state_db_search_dirs(codex_home: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    if let Some(path) = std::env::var_os("CODEX_SQLITE_HOME").map(PathBuf::from)
        && is_same_or_descendant(&path, codex_home)
    {
        dirs.push(path);
    }

    dirs.push(codex_home.join("sqlite"));
    dirs.push(codex_home.to_path_buf());
    dedupe_paths(dirs)
}

fn is_same_or_descendant(path: &Path, parent: &Path) -> bool {
    path == parent || path.starts_with(parent)
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

struct CalendarWindow {
    today_start: DateTime<FixedOffset>,
    week_start: DateTime<FixedOffset>,
    month_start: DateTime<FixedOffset>,
}

fn start_of_day(day: NaiveDate, offset: &FixedOffset) -> DateTime<FixedOffset> {
    let start_naive = day.and_hms_opt(0, 0, 0).expect("valid midnight timestamp");

    offset
        .from_local_datetime(&start_naive)
        .single()
        .expect("fixed offset midnight")
}

fn calendar_window(now: DateTime<FixedOffset>) -> CalendarWindow {
    let today = now.date_naive();
    let week_start_day = today - Duration::days(i64::from(today.weekday().num_days_from_monday()));
    let month_start_day =
        NaiveDate::from_ymd_opt(today.year(), today.month(), 1).expect("valid month start");

    CalendarWindow {
        today_start: start_of_day(today, now.offset()),
        week_start: start_of_day(week_start_day, now.offset()),
        month_start: start_of_day(month_start_day, now.offset()),
    }
}

impl SourceId {
    fn label(self) -> &'static str {
        match self {
            SourceId::Codex => "Codex",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use rusqlite::params;
    use tempfile::TempDir;

    fn test_now() -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339("2026-03-22T12:00:00+08:00").expect("valid timestamp")
    }

    #[test]
    fn calendar_window_uses_midnight_monday_and_month_start() {
        let now =
            DateTime::parse_from_rfc3339("2026-06-20T18:30:00+08:00").expect("valid timestamp");
        let window = calendar_window(now);

        assert_eq!(window.today_start.to_rfc3339(), "2026-06-20T00:00:00+08:00");
        assert_eq!(window.week_start.to_rfc3339(), "2026-06-15T00:00:00+08:00");
        assert_eq!(window.month_start.to_rfc3339(), "2026-06-01T00:00:00+08:00");
    }

    fn build_test_paths(root: &TempDir) -> BuildPaths {
        BuildPaths {
            codex_home: root.path().join(".codex"),
            extra_codex_homes: Vec::new(),
            cache_path: root.path().join(".cache").join("panel-snapshot-v2.json"),
            token_ledger_path: root.path().join(".cache").join("token-ledger-v1.sqlite"),
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
        write_rollout_events(
            &codex_home.join("active-session.jsonl"),
            &[("2026-03-22T10:00:00+08:00", active_tokens)],
        )?;
        write_rollout_events(
            &codex_home.join("archived-session.jsonl"),
            &[("2026-03-20T09:00:00+08:00", archived_tokens)],
        )?;

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
                codex_home
                    .join("active-session.jsonl")
                    .display()
                    .to_string(),
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
                codex_home
                    .join("archived-session.jsonl")
                    .display()
                    .to_string(),
                unix("2026-03-20T09:00:00+08:00"),
                unix("2026-03-20T09:00:00+08:00"),
                archived_tokens,
                unix("2026-03-21T09:00:00+08:00"),
            ],
        )?;

        Ok(())
    }

    fn write_rollout_events(path: &Path, events: &[(&str, i64)]) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let mut lines = String::new();
        for (timestamp, tokens) in events {
            let line = serde_json::json!({
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "total_tokens": tokens
                        },
                        "last_token_usage": {
                            "total_tokens": tokens
                        }
                    }
                }
            });
            lines.push_str(&line.to_string());
            lines.push('\n');
        }
        fs::write(path, lines)?;

        Ok(())
    }

    #[test]
    fn build_fresh_snapshot_reads_codex_source_and_formats_counts() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(snapshot.total_tokens, 300);
        assert_eq!(snapshot.formatted_total_tokens, "300");
        assert_eq!(snapshot.tokens_today, 200);
        assert_eq!(snapshot.tokens_week, 300);
        assert_eq!(snapshot.tokens_month, 300);
        assert_eq!(snapshot.available_source_count, 1);
        assert_eq!(snapshot.unavailable_source_count, 0);
        assert_eq!(snapshot.status, SnapshotStatus::Ok);
        assert_eq!(
            snapshot
                .sources
                .iter()
                .map(|source| source.total_tokens)
                .collect::<Vec<_>>(),
            vec![300]
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

        let mut paths = build_test_paths(&root);
        paths.extra_codex_homes.push(windows_codex_home);

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(snapshot.total_tokens, 360);
        assert_eq!(snapshot.tokens_today, 240);
        assert_eq!(snapshot.tokens_week, 360);
        assert_eq!(snapshot.tokens_month, 360);
        assert_eq!(snapshot.sources[0].total_tokens, 360);

        Ok(())
    }

    #[test]
    fn read_codex_source_selects_freshest_state_db_for_same_generation() -> Result<()> {
        let root = TempDir::new()?;
        let codex_home = root.path().join(".codex");
        create_codex_fixture_at(&codex_home, 200, 100)?;
        create_codex_fixture_at(&codex_home.join("sqlite"), 900, 100)?;
        let db = Connection::open(codex_home.join("state_1.sqlite"))?;
        db.execute(
            "UPDATE threads SET updated_at = ?1 WHERE id = ?2",
            params![unix("2026-03-22T11:00:00+08:00"), "thread-1"],
        )?;

        let snapshot = read_codex_source(
            &codex_home,
            &[],
            test_now(),
            &root.path().join(".cache").join("token-ledger-v1.sqlite"),
        )?;

        assert_eq!(snapshot.total_tokens, 300);
        assert_eq!(snapshot.tokens_today, 200);
        assert_eq!(snapshot.tokens_week, 300);

        Ok(())
    }

    #[test]
    fn token_ledger_uses_token_event_timestamps() -> Result<()> {
        let root = TempDir::new()?;
        let codex_home = root.path().join(".codex");
        create_codex_fixture_at(&codex_home, 10_000, 0)?;
        write_rollout_events(
            &codex_home.join("active-session.jsonl"),
            &[("2026-02-28T10:00:00+08:00", 10_000)],
        )?;

        let snapshot = read_codex_source(
            &codex_home,
            &[],
            test_now(),
            &root.path().join(".cache").join("token-ledger-v1.sqlite"),
        )?;

        assert_eq!(snapshot.total_tokens, 10_000);
        assert_eq!(snapshot.tokens_today, 0);
        assert_eq!(snapshot.tokens_week, 0);
        assert_eq!(snapshot.tokens_month, 0);

        Ok(())
    }

    #[test]
    fn token_ledger_reads_archived_rollout_files() -> Result<()> {
        let root = TempDir::new()?;
        let codex_home = root.path().join(".codex");
        create_codex_fixture_at(&codex_home, 200, 100)?;
        fs::create_dir_all(codex_home.join("archived_sessions"))?;
        fs::rename(
            codex_home.join("active-session.jsonl"),
            codex_home
                .join("archived_sessions")
                .join("active-session.jsonl"),
        )?;

        let snapshot = read_codex_source(
            &codex_home,
            &[],
            test_now(),
            &root.path().join(".cache").join("token-ledger-v1.sqlite"),
        )?;

        assert_eq!(snapshot.total_tokens, 300);
        assert_eq!(snapshot.tokens_today, 200);
        assert_eq!(snapshot.tokens_week, 300);
        assert_eq!(snapshot.tokens_month, 300);

        Ok(())
    }

    #[test]
    fn build_fresh_snapshot_requires_codex_source() -> Result<()> {
        let root = TempDir::new()?;

        let error = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: build_test_paths(&root),
        })
        .expect_err("missing Codex data should fail the token snapshot");

        assert!(error.to_string().contains("No panel sources are available"));

        Ok(())
    }

    #[test]
    fn cache_validation_and_stale_fallback_work() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = load_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: paths.clone(),
        })?;
        assert_eq!(snapshot.total_tokens, 300);

        let cache = read_cache(&paths.cache_path)?;
        let signatures = collect_source_signatures(&paths)?;
        assert!(is_cache_valid(
            &cache,
            &signatures,
            test_now() + Duration::seconds(5),
            StdDuration::from_secs(CACHE_TTL_SECONDS)
        ));

        fs::remove_file(&paths.codex_home.join("state_1.sqlite"))?;

        let stale_snapshot = load_snapshot(&SnapshotOptions {
            now: test_now() + Duration::seconds(20),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })?;

        assert_eq!(stale_snapshot.status, SnapshotStatus::Stale);
        assert_eq!(stale_snapshot.total_tokens, 300);
        assert!(
            stale_snapshot
                .error
                .as_deref()
                .is_some_and(|message| message.contains("No panel sources are available"))
        );

        Ok(())
    }

    #[test]
    fn no_cache_does_not_return_stale_snapshot() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = load_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: true,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: paths.clone(),
        })?;
        assert_eq!(snapshot.total_tokens, 300);

        fs::remove_file(&paths.codex_home.join("state_1.sqlite"))?;

        let error = load_snapshot(&SnapshotOptions {
            now: test_now() + Duration::seconds(20),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths,
        })
        .expect_err("no-cache should not return stale cache data");

        assert!(error.to_string().contains("No panel sources are available"));

        Ok(())
    }

    #[test]
    fn no_cache_still_updates_the_incremental_token_ledger() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let paths = build_test_paths(&root);

        let snapshot = build_fresh_snapshot(&SnapshotOptions {
            now: test_now(),
            use_cache: false,
            ttl: StdDuration::from_secs(CACHE_TTL_SECONDS),
            paths: paths.clone(),
        })?;

        assert_eq!(snapshot.total_tokens, 300);
        assert!(paths.token_ledger_path.exists());

        Ok(())
    }

    #[test]
    fn format_token_count_inserts_grouping_separators() {
        assert_eq!(format_token_count(5_335_479_211), "5,335,479,211");
    }

    #[test]
    fn signatures_change_when_codex_db_mtime_changes() -> Result<()> {
        let root = TempDir::new()?;
        create_codex_fixture(&root)?;
        let paths = build_test_paths(&root);
        let before = collect_source_signatures(&paths)?;

        std::thread::sleep(StdDuration::from_secs(1));
        let db = Connection::open(paths.codex_home.join("state_1.sqlite"))?;
        db.execute(
            "UPDATE threads SET tokens_used = tokens_used + 1 WHERE id = ?1",
            params!["thread-1"],
        )?;

        let after = collect_source_signatures(&paths)?;
        assert_ne!(before.codex_db_mtime_ms, after.codex_db_mtime_ms);
        assert_eq!(
            before.codex_db_path,
            Some(
                paths
                    .codex_home
                    .join("state_1.sqlite")
                    .display()
                    .to_string()
            )
        );

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
