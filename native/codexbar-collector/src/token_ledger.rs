use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use chrono::DateTime;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};

const TOKEN_COUNT_PATTERN: &[u8] = br#""type":"token_count""#;
const MAX_TOKEN_COUNT_LINE_BYTES: usize = 64 * 1024;
const READ_CHUNK_BYTES: usize = 64 * 1024;
const LEDGER_SCHEMA_VERSION: i64 = 1;

#[derive(Debug, Clone, Copy)]
pub(crate) struct UsageWindow {
    pub(crate) today_start_ms: i64,
    pub(crate) week_start_ms: i64,
    pub(crate) month_start_ms: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct LedgerTotals {
    pub(crate) total_tokens: u64,
    pub(crate) tokens_today: u64,
    pub(crate) tokens_week: u64,
    pub(crate) tokens_month: u64,
}

#[derive(Debug, Clone)]
struct StateThread {
    id: String,
    rollout_path: String,
    created_at_ms: i64,
    parent_thread_id: Option<String>,
    forked_at_ms: Option<i64>,
}

#[derive(Debug, Clone)]
struct Checkpoint {
    parent_thread_id: Option<String>,
    forked_at_ms: Option<i64>,
    rollout_path: String,
    device: u64,
    inode: u64,
    committed_offset: u64,
    baseline: TokenUsageInfo,
    raw_info: TokenUsageInfo,
}

#[derive(Debug, Clone)]
struct ParsedAppend {
    committed_offset: u64,
    raw_info: TokenUsageInfo,
    events: Vec<UsageEvent>,
    snapshots: Vec<RawSnapshot>,
}

#[derive(Debug, Clone)]
struct UsageEvent {
    source_end_offset: u64,
    occurred_at_ms: i64,
    usage: TokenUsage,
}

#[derive(Debug, Clone)]
struct RawSnapshot {
    source_end_offset: u64,
    info: TokenUsageInfo,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq, Hash)]
struct TokenUsage {
    #[serde(default)]
    input_tokens: i64,
    #[serde(default)]
    cached_input_tokens: i64,
    #[serde(default)]
    output_tokens: i64,
    #[serde(default)]
    reasoning_output_tokens: i64,
    #[serde(default)]
    total_tokens: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
struct TokenUsageInfo {
    #[serde(default)]
    total_token_usage: TokenUsage,
    #[serde(default)]
    last_token_usage: TokenUsage,
    #[serde(default)]
    model_context_window: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct RolloutRecord {
    timestamp: Option<String>,
    #[serde(rename = "type")]
    record_type: String,
    payload: Option<RolloutPayload>,
}

#[derive(Debug, Deserialize)]
struct RolloutPayload {
    #[serde(rename = "type")]
    payload_type: String,
    info: Option<TokenUsageInfo>,
}

#[derive(Debug, Deserialize)]
struct SessionMetaRecord {
    #[serde(rename = "type")]
    record_type: String,
    payload: SessionMetaPayload,
}

#[derive(Debug, Deserialize)]
struct SessionMetaPayload {
    timestamp: Option<String>,
    forked_from_id: Option<String>,
    parent_thread_id: Option<String>,
}

pub(crate) fn sync_and_query(
    codex_home: &Path,
    state_db: &Connection,
    ledger_path: &Path,
    window: UsageWindow,
) -> Result<LedgerTotals> {
    if let Some(parent) = ledger_path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "Failed to create token ledger directory {}",
                parent.display()
            )
        })?;
    }

    let home_id = codex_home.display().to_string();
    let mut ledger = Connection::open(ledger_path)
        .with_context(|| format!("Failed to open token ledger {}", ledger_path.display()))?;
    initialize_ledger(&ledger)?;

    let checkpoints = load_checkpoint_metadata(&ledger, &home_id)?;
    let mut threads = load_state_threads(state_db)?;
    for thread in &mut threads {
        if let Some(checkpoint) = checkpoints.get(&thread.id) {
            thread.parent_thread_id = checkpoint.parent_thread_id.clone();
            thread.forked_at_ms = checkpoint.forked_at_ms;
            continue;
        }

        let rollout_path = resolve_rollout_path(codex_home, Path::new(&thread.rollout_path))?;
        if let Some(meta) = read_session_meta(&rollout_path)? {
            thread.parent_thread_id = thread
                .parent_thread_id
                .clone()
                .or(meta.parent_thread_id)
                .or(meta.forked_from_id);
            thread.forked_at_ms = meta
                .timestamp
                .as_deref()
                .map(parse_timestamp_ms)
                .transpose()?;
        }
        if thread.parent_thread_id.is_some() && thread.forked_at_ms.is_none() {
            thread.forked_at_ms = Some(thread.created_at_ms);
        }
    }

    sync_threads_in_lineage_order(codex_home, &home_id, &mut ledger, &threads)?;
    remove_deleted_threads(&mut ledger, &home_id, &threads)?;

    query_totals(&ledger, &home_id, window)
}

fn initialize_ledger(db: &Connection) -> Result<()> {
    db.execute_batch(
        "
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS ledger_meta (
            key TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS thread_checkpoints (
            home_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            parent_thread_id TEXT,
            forked_at_ms INTEGER,
            rollout_path TEXT NOT NULL,
            device INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            committed_offset INTEGER NOT NULL,
            baseline_json TEXT NOT NULL,
            raw_info_json TEXT NOT NULL,
            PRIMARY KEY (home_id, thread_id)
        );

        CREATE TABLE IF NOT EXISTS usage_events (
            home_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            source_end_offset INTEGER NOT NULL,
            occurred_at_ms INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            PRIMARY KEY (home_id, thread_id, source_end_offset)
        );

        CREATE INDEX IF NOT EXISTS idx_usage_events_home_time
            ON usage_events(home_id, occurred_at_ms, total_tokens);

        CREATE TABLE IF NOT EXISTS raw_snapshots (
            home_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            source_end_offset INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            PRIMARY KEY (home_id, thread_id, source_end_offset)
        );
        ",
    )
    .context("Failed to initialize token ledger schema")?;

    let version = db
        .query_row(
            "SELECT value FROM ledger_meta WHERE key = 'schema_version'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .context("Failed to read token ledger schema version")?;
    match version {
        Some(version) if version != LEDGER_SCHEMA_VERSION => {
            bail!(
                "Unsupported token ledger schema version {version}; expected {LEDGER_SCHEMA_VERSION}"
            );
        }
        Some(_) => {}
        None => {
            db.execute(
                "INSERT INTO ledger_meta(key, value) VALUES ('schema_version', ?1)",
                [LEDGER_SCHEMA_VERSION],
            )
            .context("Failed to persist token ledger schema version")?;
        }
    }
    Ok(())
}

fn load_checkpoint_metadata(db: &Connection, home_id: &str) -> Result<HashMap<String, Checkpoint>> {
    let mut statement = db.prepare(
        "
        SELECT thread_id, parent_thread_id, forked_at_ms, rollout_path, device, inode,
               committed_offset, baseline_json, raw_info_json
        FROM thread_checkpoints
        WHERE home_id = ?1
        ",
    )?;
    let rows = statement.query_map([home_id], |row| {
        let baseline_json: String = row.get(7)?;
        let raw_info_json: String = row.get(8)?;
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, u64>(4)?,
            row.get::<_, u64>(5)?,
            row.get::<_, u64>(6)?,
            baseline_json,
            raw_info_json,
        ))
    })?;

    let mut checkpoints = HashMap::new();
    for row in rows {
        let (
            thread_id,
            parent_thread_id,
            forked_at_ms,
            rollout_path,
            device,
            inode,
            committed_offset,
            baseline_json,
            raw_info_json,
        ) = row?;
        checkpoints.insert(
            thread_id,
            Checkpoint {
                parent_thread_id,
                forked_at_ms,
                rollout_path,
                device,
                inode,
                committed_offset,
                baseline: serde_json::from_str(&baseline_json)
                    .context("Failed to decode token ledger baseline")?,
                raw_info: serde_json::from_str(&raw_info_json)
                    .context("Failed to decode token ledger raw state")?,
            },
        );
    }
    Ok(checkpoints)
}

fn load_state_threads(state_db: &Connection) -> Result<Vec<StateThread>> {
    let has_created_at_ms = state_db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('threads') WHERE name='created_at_ms')",
            [],
            |row| row.get::<_, bool>(0),
        )
        .context("Failed to inspect Codex thread timestamp schema")?;

    let created_at_expression = if has_created_at_ms {
        "COALESCE(t.created_at_ms, t.created_at * 1000)"
    } else {
        "t.created_at * 1000"
    };
    let sql = format!(
        "
        SELECT t.id, t.rollout_path, {created_at_expression}, NULL
        FROM threads t
        ORDER BY t.created_at, t.id
        "
    );

    let mut statement = state_db
        .prepare(&sql)
        .context("Failed to prepare Codex thread query")?;
    let rows = statement.query_map([], |row| {
        Ok(StateThread {
            id: row.get(0)?,
            rollout_path: row.get(1)?,
            created_at_ms: row.get(2)?,
            parent_thread_id: row.get(3)?,
            forked_at_ms: None,
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .context("Failed to read Codex threads")
}

fn sync_threads_in_lineage_order(
    codex_home: &Path,
    home_id: &str,
    ledger: &mut Connection,
    threads: &[StateThread],
) -> Result<()> {
    let known_ids = threads
        .iter()
        .map(|thread| thread.id.as_str())
        .collect::<HashSet<_>>();
    for thread in threads {
        if let Some(parent) = thread.parent_thread_id.as_deref()
            && !known_ids.contains(parent)
        {
            bail!(
                "Codex thread {} references missing parent thread {parent}",
                thread.id
            );
        }
    }

    let mut completed = HashSet::new();
    let mut pending = threads.iter().collect::<Vec<_>>();
    while !pending.is_empty() {
        let before = pending.len();
        let mut next = Vec::new();
        for thread in pending {
            if thread
                .parent_thread_id
                .as_ref()
                .is_none_or(|parent| completed.contains(parent))
            {
                sync_thread(codex_home, home_id, ledger, thread)?;
                completed.insert(thread.id.clone());
            } else {
                next.push(thread);
            }
        }
        if next.len() == before {
            bail!("Codex thread lineage contains a cycle");
        }
        pending = next;
    }
    Ok(())
}

fn sync_thread(
    codex_home: &Path,
    home_id: &str,
    ledger: &mut Connection,
    thread: &StateThread,
) -> Result<()> {
    let resolved_path = resolve_rollout_path(codex_home, Path::new(&thread.rollout_path))?;
    let metadata = fs::metadata(&resolved_path)
        .with_context(|| format!("Failed to stat rollout {}", resolved_path.display()))?;
    let device = metadata.dev();
    let inode = metadata.ino();
    let file_size = metadata.len();
    let checkpoint = load_checkpoint(ledger, home_id, &thread.id)?;

    let requires_rebuild = checkpoint.as_ref().is_some_and(|checkpoint| {
        checkpoint.device != device
            || checkpoint.inode != inode
            || checkpoint.committed_offset > file_size
    });
    let (baseline, scan_start, raw_info, inherited_snapshots) = if let Some(checkpoint) =
        checkpoint.as_ref()
        && !requires_rebuild
    {
        (
            checkpoint.baseline.clone(),
            checkpoint.committed_offset,
            checkpoint.raw_info.clone(),
            Vec::new(),
        )
    } else {
        determine_initial_state(ledger, home_id, thread, &resolved_path, file_size)?
    };

    if checkpoint.is_some() && !requires_rebuild && scan_start == file_size {
        if let Some(checkpoint) = checkpoint
            && (checkpoint.rollout_path != resolved_path.display().to_string()
                || checkpoint.parent_thread_id != thread.parent_thread_id
                || checkpoint.forked_at_ms != thread.forked_at_ms)
        {
            let transaction = ledger.transaction()?;
            upsert_checkpoint(
                &transaction,
                home_id,
                thread,
                &resolved_path,
                device,
                inode,
                scan_start,
                &baseline,
                &raw_info,
            )?;
            transaction.commit()?;
        }
        return Ok(());
    }

    let mut seen_totals = if requires_rebuild {
        HashSet::from([baseline.total_token_usage.clone()])
    } else {
        load_seen_totals(ledger, home_id, &thread.id, &baseline)?
    };
    seen_totals.extend(
        inherited_snapshots
            .iter()
            .map(|snapshot| snapshot.info.total_token_usage.clone()),
    );
    let mut parsed =
        parse_appended_token_records(&resolved_path, scan_start, file_size, raw_info, seen_totals)
            .with_context(|| {
                format!(
                    "Failed to update token ledger for thread {} from {}",
                    thread.id,
                    resolved_path.display()
                )
            })?;
    if !inherited_snapshots.is_empty() {
        let mut snapshots = inherited_snapshots;
        snapshots.append(&mut parsed.snapshots);
        parsed.snapshots = snapshots;
    }
    let transaction = ledger.transaction()?;
    if requires_rebuild {
        delete_thread_rows(&transaction, home_id, &thread.id)?;
    }
    persist_parsed_append(&transaction, home_id, &thread.id, &parsed)?;
    upsert_checkpoint(
        &transaction,
        home_id,
        thread,
        &resolved_path,
        device,
        inode,
        parsed.committed_offset,
        &baseline,
        &parsed.raw_info,
    )?;
    transaction.commit()?;
    Ok(())
}

fn load_checkpoint(db: &Connection, home_id: &str, thread_id: &str) -> Result<Option<Checkpoint>> {
    let row = db
        .query_row(
            "
        SELECT parent_thread_id, forked_at_ms, rollout_path, device, inode, committed_offset,
               baseline_json, raw_info_json
        FROM thread_checkpoints
        WHERE home_id = ?1 AND thread_id = ?2
        ",
            params![home_id, thread_id],
            |row| {
                let baseline_json: String = row.get(6)?;
                let raw_info_json: String = row.get(7)?;
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, u64>(3)?,
                    row.get::<_, u64>(4)?,
                    row.get::<_, u64>(5)?,
                    baseline_json,
                    raw_info_json,
                ))
            },
        )
        .optional()?;
    let Some((
        parent_thread_id,
        forked_at_ms,
        rollout_path,
        device,
        inode,
        committed_offset,
        baseline_json,
        raw_info_json,
    )) = row
    else {
        return Ok(None);
    };
    Ok(Some(Checkpoint {
        parent_thread_id,
        forked_at_ms,
        rollout_path,
        device,
        inode,
        committed_offset,
        baseline: serde_json::from_str(&baseline_json)
            .context("Failed to decode token ledger baseline")?,
        raw_info: serde_json::from_str(&raw_info_json)
            .context("Failed to decode token ledger raw state")?,
    }))
}

fn determine_initial_state(
    ledger: &Connection,
    home_id: &str,
    thread: &StateThread,
    rollout_path: &Path,
    file_size: u64,
) -> Result<(TokenUsageInfo, u64, TokenUsageInfo, Vec<RawSnapshot>)> {
    let Some(parent_thread_id) = thread.parent_thread_id.as_deref() else {
        let zero = TokenUsageInfo::default();
        return Ok((zero.clone(), 0, zero, Vec::new()));
    };
    if let Some((baseline, boundary, inherited_snapshots)) = find_inherited_token_history(
        ledger,
        home_id,
        parent_thread_id,
        rollout_path,
        file_size,
    )
    .with_context(|| {
        format!(
            "Failed to locate inherited history for Codex thread {} from parent {parent_thread_id}",
            thread.id
        )
    })? {
        return Ok((baseline.clone(), boundary, baseline, inherited_snapshots));
    }

    let first_info = first_token_info(rollout_path, file_size)?;
    if first_info
        .as_ref()
        .is_none_or(|info| info.total_token_usage == info.last_token_usage)
    {
        let zero = TokenUsageInfo::default();
        return Ok((zero.clone(), 0, zero, Vec::new()));
    }

    bail!(
        "Unable to locate inherited token baseline for Codex thread {} from parent {parent_thread_id}",
        thread.id
    )
}

fn load_seen_totals(
    db: &Connection,
    home_id: &str,
    thread_id: &str,
    baseline: &TokenUsageInfo,
) -> Result<HashSet<TokenUsage>> {
    let mut totals = HashSet::from([baseline.total_token_usage.clone()]);
    let mut statement = db.prepare(
        "
        SELECT input_tokens, cached_input_tokens, output_tokens,
               reasoning_output_tokens, total_tokens
        FROM raw_snapshots
        WHERE home_id = ?1 AND thread_id = ?2
        ",
    )?;
    let rows = statement.query_map(params![home_id, thread_id], token_usage_from_row)?;
    for usage in rows {
        totals.insert(usage?);
    }
    Ok(totals)
}

fn parse_appended_token_records(
    rollout_path: &Path,
    start: u64,
    end: u64,
    mut raw_info: TokenUsageInfo,
    mut seen_totals: HashSet<TokenUsage>,
) -> Result<ParsedAppend> {
    let mut events = Vec::new();
    let mut snapshots = Vec::new();
    let committed_offset =
        scan_token_lines_forward(rollout_path, start, end, |source_end_offset, line| {
            let Some((occurred_at_ms, info)) = parse_token_record(line, rollout_path)? else {
                return Ok(true);
            };
            validate_info(&info)?;
            let transition = classify_transition(&raw_info, &info, &seen_totals)?;
            if transition == TokenTransition::Actual {
                events.push(UsageEvent {
                    source_end_offset,
                    occurred_at_ms,
                    usage: info.last_token_usage.clone(),
                });
            }
            if transition != TokenTransition::Replay {
                raw_info = info.clone();
                seen_totals.insert(info.total_token_usage.clone());
            }
            snapshots.push(RawSnapshot {
                source_end_offset,
                info,
            });
            Ok(true)
        })?;
    Ok(ParsedAppend {
        committed_offset,
        raw_info,
        events,
        snapshots,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TokenTransition {
    Replay,
    Actual,
    SyntheticContextFill,
}

fn classify_transition(
    previous: &TokenUsageInfo,
    current: &TokenUsageInfo,
    seen_totals: &HashSet<TokenUsage>,
) -> Result<TokenTransition> {
    if seen_totals.contains(&current.total_token_usage) {
        return Ok(TokenTransition::Replay);
    }
    if is_synthetic_context_fill(previous, current) {
        return Ok(TokenTransition::SyntheticContextFill);
    }
    let base = current
        .total_token_usage
        .checked_sub(&current.last_token_usage)?;
    if base == TokenUsage::default() || seen_totals.contains(&base) {
        return Ok(TokenTransition::Actual);
    }
    bail!(
        "Invalid Codex token transition: previous total {}, current total {}, last usage {}",
        previous.total_token_usage.total_tokens,
        current.total_token_usage.total_tokens,
        current.last_token_usage.total_tokens
    )
}

fn is_synthetic_context_fill(previous: &TokenUsageInfo, current: &TokenUsageInfo) -> bool {
    let Some(context_window) = current.model_context_window else {
        return false;
    };
    current.total_token_usage.total_tokens == context_window
        && current.total_token_usage.has_zero_breakdown()
        && current.last_token_usage.has_zero_breakdown()
        && current.last_token_usage.total_tokens
            == (context_window - previous.total_token_usage.total_tokens).max(0)
}

impl TokenUsage {
    fn validate(&self) -> Result<()> {
        if self.input_tokens < 0
            || self.cached_input_tokens < 0
            || self.output_tokens < 0
            || self.reasoning_output_tokens < 0
            || self.total_tokens < 0
        {
            bail!("Codex token usage contains a negative component");
        }
        Ok(())
    }

    fn checked_sub(&self, other: &Self) -> Result<Self> {
        let result = Self {
            input_tokens: self
                .input_tokens
                .checked_sub(other.input_tokens)
                .ok_or_else(|| anyhow!("Codex input token total underflowed"))?,
            cached_input_tokens: self
                .cached_input_tokens
                .checked_sub(other.cached_input_tokens)
                .ok_or_else(|| anyhow!("Codex cached input token total underflowed"))?,
            output_tokens: self
                .output_tokens
                .checked_sub(other.output_tokens)
                .ok_or_else(|| anyhow!("Codex output token total underflowed"))?,
            reasoning_output_tokens: self
                .reasoning_output_tokens
                .checked_sub(other.reasoning_output_tokens)
                .ok_or_else(|| anyhow!("Codex reasoning token total underflowed"))?,
            total_tokens: self
                .total_tokens
                .checked_sub(other.total_tokens)
                .ok_or_else(|| anyhow!("Codex token total underflowed"))?,
        };
        result.validate()?;
        Ok(result)
    }

    fn has_zero_breakdown(&self) -> bool {
        self.input_tokens == 0
            && self.cached_input_tokens == 0
            && self.output_tokens == 0
            && self.reasoning_output_tokens == 0
    }
}

fn validate_info(info: &TokenUsageInfo) -> Result<()> {
    info.total_token_usage.validate()?;
    info.last_token_usage.validate()?;
    Ok(())
}

fn scan_token_lines_forward(
    rollout_path: &Path,
    start: u64,
    end: u64,
    mut handle_line: impl FnMut(u64, &str) -> Result<bool>,
) -> Result<u64> {
    let mut file = fs::File::open(rollout_path)
        .with_context(|| format!("Failed to open rollout {}", rollout_path.display()))?;
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file.take(end.saturating_sub(start)));
    let mut chunk = [0_u8; READ_CHUNK_BYTES];
    let mut line = Vec::with_capacity(1024);
    let mut pattern_index = 0_usize;
    let mut has_match = false;
    let mut capture_line = true;
    let mut absolute_offset = start;
    let mut committed_offset = start;

    loop {
        let bytes_read = reader
            .read(&mut chunk)
            .with_context(|| format!("Failed to read rollout {}", rollout_path.display()))?;
        if bytes_read == 0 {
            break;
        }
        for byte in &chunk[..bytes_read] {
            absolute_offset += 1;
            if *byte == b'\n' {
                if has_match {
                    let text = std::str::from_utf8(&line).with_context(|| {
                        format!(
                            "Codex token record ending at byte {} in {} is not UTF-8",
                            absolute_offset,
                            rollout_path.display()
                        )
                    })?;
                    if !handle_line(absolute_offset, text)? {
                        return Ok(absolute_offset);
                    }
                }
                line.clear();
                pattern_index = 0;
                has_match = false;
                capture_line = true;
                committed_offset = absolute_offset;
                continue;
            }

            if capture_line {
                if line.len() == MAX_TOKEN_COUNT_LINE_BYTES {
                    line.clear();
                    capture_line = false;
                    pattern_index = 0;
                    continue;
                }
                line.push(*byte);
            }
            if capture_line && !has_match {
                if *byte == TOKEN_COUNT_PATTERN[pattern_index] {
                    pattern_index += 1;
                    if pattern_index == TOKEN_COUNT_PATTERN.len() {
                        has_match = true;
                    }
                } else {
                    pattern_index = usize::from(*byte == TOKEN_COUNT_PATTERN[0]);
                }
            }
        }
    }
    Ok(committed_offset)
}

struct TokenSnapshotCursor {
    rollout_path: PathBuf,
    file: fs::File,
    end: u64,
    absolute_offset: u64,
    chunk: [u8; READ_CHUNK_BYTES],
    chunk_len: usize,
    chunk_index: usize,
    line: Vec<u8>,
    pattern_index: usize,
    has_match: bool,
    capture_line: bool,
}

impl TokenSnapshotCursor {
    fn open(rollout_path: &Path, end: u64) -> Result<Self> {
        Ok(Self {
            rollout_path: rollout_path.to_path_buf(),
            file: fs::File::open(rollout_path)
                .with_context(|| format!("Failed to open rollout {}", rollout_path.display()))?,
            end,
            absolute_offset: 0,
            chunk: [0; READ_CHUNK_BYTES],
            chunk_len: 0,
            chunk_index: 0,
            line: Vec::with_capacity(1024),
            pattern_index: 0,
            has_match: false,
            capture_line: true,
        })
    }

    fn next(&mut self) -> Result<Option<RawSnapshot>> {
        loop {
            if self.chunk_index == self.chunk_len {
                let remaining = self.end.saturating_sub(self.absolute_offset);
                if remaining == 0 {
                    return Ok(None);
                }
                let read_len = remaining.min(READ_CHUNK_BYTES as u64) as usize;
                self.chunk_len = self.file.read(&mut self.chunk[..read_len])?;
                self.chunk_index = 0;
                if self.chunk_len == 0 {
                    return Ok(None);
                }
            }

            let byte = self.chunk[self.chunk_index];
            self.chunk_index += 1;
            self.absolute_offset += 1;
            if byte == b'\n' {
                let parsed = if self.has_match {
                    let text = std::str::from_utf8(&self.line).with_context(|| {
                        format!(
                            "Codex token record ending at byte {} in {} is not UTF-8",
                            self.absolute_offset,
                            self.rollout_path.display()
                        )
                    })?;
                    parse_token_record(text, &self.rollout_path)?
                } else {
                    None
                };
                self.line.clear();
                self.pattern_index = 0;
                self.has_match = false;
                self.capture_line = true;
                if let Some((_, info)) = parsed {
                    return Ok(Some(RawSnapshot {
                        source_end_offset: self.absolute_offset,
                        info,
                    }));
                }
                continue;
            }

            if self.capture_line {
                if self.line.len() == MAX_TOKEN_COUNT_LINE_BYTES {
                    self.line.clear();
                    self.capture_line = false;
                    self.pattern_index = 0;
                    continue;
                }
                self.line.push(byte);
            }
            if self.capture_line && !self.has_match {
                if byte == TOKEN_COUNT_PATTERN[self.pattern_index] {
                    self.pattern_index += 1;
                    if self.pattern_index == TOKEN_COUNT_PATTERN.len() {
                        self.has_match = true;
                    }
                } else {
                    self.pattern_index = usize::from(byte == TOKEN_COUNT_PATTERN[0]);
                }
            }
        }
    }
}

fn find_inherited_token_history(
    ledger: &Connection,
    home_id: &str,
    parent_thread_id: &str,
    child_rollout: &Path,
    child_size: u64,
) -> Result<Option<(TokenUsageInfo, u64, Vec<RawSnapshot>)>> {
    let parent_snapshots = {
        let mut statement = ledger.prepare(
            "
            SELECT input_tokens, cached_input_tokens, output_tokens,
                   reasoning_output_tokens, total_tokens
            FROM raw_snapshots
            WHERE home_id = ?1 AND thread_id = ?2
            ORDER BY source_end_offset
            ",
        )?;
        let rows = statement.query_map(params![home_id, parent_thread_id], token_usage_from_row)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    if parent_snapshots.is_empty() {
        return Ok(None);
    }

    let mut child = TokenSnapshotCursor::open(child_rollout, child_size)?;
    let mut child_snapshots = Vec::new();
    while let Some(snapshot) = child.next()? {
        child_snapshots.push(snapshot);
    }
    let best_length = longest_inherited_prefix_length(&parent_snapshots, &child_snapshots);
    if best_length == 0 {
        return Ok(None);
    }

    let inherited_snapshots = child_snapshots[..best_length].to_vec();
    let last = inherited_snapshots
        .last()
        .expect("non-empty inherited token history");
    Ok(Some((
        last.info.clone(),
        last.source_end_offset,
        inherited_snapshots,
    )))
}

fn longest_inherited_prefix_length(
    parent_snapshots: &[TokenUsage],
    child_snapshots: &[RawSnapshot],
) -> usize {
    let Some(first_child) = child_snapshots.first() else {
        return 0;
    };
    let mut best_length = 0_usize;
    for start in 0..parent_snapshots.len() {
        if parent_snapshots[start] != first_child.info.total_token_usage {
            continue;
        }
        let mut length = 1_usize;
        while start + length < parent_snapshots.len()
            && length < child_snapshots.len()
            && parent_snapshots[start + length] == child_snapshots[length].info.total_token_usage
        {
            length += 1;
        }
        best_length = best_length.max(length);
    }
    best_length
}

fn token_usage_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TokenUsage> {
    Ok(TokenUsage {
        input_tokens: row.get(0)?,
        cached_input_tokens: row.get(1)?,
        output_tokens: row.get(2)?,
        reasoning_output_tokens: row.get(3)?,
        total_tokens: row.get(4)?,
    })
}

fn first_token_info(rollout_path: &Path, file_size: u64) -> Result<Option<TokenUsageInfo>> {
    let mut found = None;
    scan_token_lines_forward(rollout_path, 0, file_size, |_, line| {
        if found.is_none() {
            found = parse_token_record(line, rollout_path)?.map(|(_, info)| info);
        }
        Ok(found.is_none())
    })?;
    Ok(found)
}

fn parse_token_record(line: &str, rollout_path: &Path) -> Result<Option<(i64, TokenUsageInfo)>> {
    let record: RolloutRecord = serde_json::from_str(line)
        .with_context(|| format!("Failed to parse token record in {}", rollout_path.display()))?;
    if record.record_type != "event_msg" {
        return Ok(None);
    }
    let Some(payload) = record.payload else {
        return Ok(None);
    };
    if payload.payload_type != "token_count" {
        return Ok(None);
    }
    let Some(info) = payload.info else {
        return Ok(None);
    };
    let timestamp = record.timestamp.ok_or_else(|| {
        anyhow!(
            "Codex token record in {} has no timestamp",
            rollout_path.display()
        )
    })?;
    Ok(Some((parse_timestamp_ms(&timestamp)?, info)))
}

fn parse_timestamp_ms(timestamp: &str) -> Result<i64> {
    Ok(DateTime::parse_from_rfc3339(timestamp)
        .with_context(|| format!("Invalid Codex timestamp {timestamp}"))?
        .timestamp_millis())
}

fn read_session_meta(rollout_path: &Path) -> Result<Option<SessionMetaPayload>> {
    let file = fs::File::open(rollout_path)
        .with_context(|| format!("Failed to open rollout {}", rollout_path.display()))?;
    let mut reader = BufReader::new(file);
    let mut first_line = Vec::new();
    loop {
        let mut byte = [0_u8; 1];
        if reader.read(&mut byte)? == 0 || byte[0] == b'\n' {
            break;
        }
        first_line.push(byte[0]);
    }
    if first_line.is_empty() {
        return Ok(None);
    }
    let record: SessionMetaRecord = serde_json::from_slice(&first_line).with_context(|| {
        format!(
            "Failed to parse session metadata in {}",
            rollout_path.display()
        )
    })?;
    if record.record_type != "session_meta" {
        return Ok(None);
    }
    Ok(Some(record.payload))
}

fn persist_parsed_append(
    transaction: &Transaction<'_>,
    home_id: &str,
    thread_id: &str,
    parsed: &ParsedAppend,
) -> Result<()> {
    let mut insert_event = transaction.prepare_cached(
        "
        INSERT INTO usage_events(
            home_id, thread_id, source_end_offset, occurred_at_ms, input_tokens,
            cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ON CONFLICT(home_id, thread_id, source_end_offset) DO NOTHING
        ",
    )?;
    for event in &parsed.events {
        insert_event.execute(params![
            home_id,
            thread_id,
            event.source_end_offset,
            event.occurred_at_ms,
            event.usage.input_tokens,
            event.usage.cached_input_tokens,
            event.usage.output_tokens,
            event.usage.reasoning_output_tokens,
            event.usage.total_tokens,
        ])?;
    }
    drop(insert_event);

    let mut insert_snapshot = transaction.prepare_cached(
        "
        INSERT INTO raw_snapshots(
            home_id, thread_id, source_end_offset, input_tokens, cached_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(home_id, thread_id, source_end_offset) DO NOTHING
        ",
    )?;
    for snapshot in &parsed.snapshots {
        insert_snapshot.execute(params![
            home_id,
            thread_id,
            snapshot.source_end_offset,
            snapshot.info.total_token_usage.input_tokens,
            snapshot.info.total_token_usage.cached_input_tokens,
            snapshot.info.total_token_usage.output_tokens,
            snapshot.info.total_token_usage.reasoning_output_tokens,
            snapshot.info.total_token_usage.total_tokens,
        ])?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn upsert_checkpoint(
    transaction: &Transaction<'_>,
    home_id: &str,
    thread: &StateThread,
    rollout_path: &Path,
    device: u64,
    inode: u64,
    committed_offset: u64,
    baseline: &TokenUsageInfo,
    raw_info: &TokenUsageInfo,
) -> Result<()> {
    transaction.execute(
        "
        INSERT INTO thread_checkpoints(
            home_id, thread_id, parent_thread_id, forked_at_ms, rollout_path, device, inode,
            committed_offset, baseline_json, raw_info_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(home_id, thread_id) DO UPDATE SET
            parent_thread_id = excluded.parent_thread_id,
            forked_at_ms = excluded.forked_at_ms,
            rollout_path = excluded.rollout_path,
            device = excluded.device,
            inode = excluded.inode,
            committed_offset = excluded.committed_offset,
            baseline_json = excluded.baseline_json,
            raw_info_json = excluded.raw_info_json
        ",
        params![
            home_id,
            thread.id,
            thread.parent_thread_id,
            thread.forked_at_ms,
            rollout_path.display().to_string(),
            device,
            inode,
            committed_offset,
            serde_json::to_string(baseline)?,
            serde_json::to_string(raw_info)?,
        ],
    )?;
    Ok(())
}

fn delete_thread_rows(transaction: &Transaction<'_>, home_id: &str, thread_id: &str) -> Result<()> {
    transaction.execute(
        "DELETE FROM usage_events WHERE home_id = ?1 AND thread_id = ?2",
        params![home_id, thread_id],
    )?;
    transaction.execute(
        "DELETE FROM raw_snapshots WHERE home_id = ?1 AND thread_id = ?2",
        params![home_id, thread_id],
    )?;
    transaction.execute(
        "DELETE FROM thread_checkpoints WHERE home_id = ?1 AND thread_id = ?2",
        params![home_id, thread_id],
    )?;
    Ok(())
}

fn remove_deleted_threads(
    ledger: &mut Connection,
    home_id: &str,
    threads: &[StateThread],
) -> Result<()> {
    let live_ids = threads
        .iter()
        .map(|thread| thread.id.as_str())
        .collect::<HashSet<_>>();
    let stored_ids = {
        let mut statement =
            ledger.prepare("SELECT thread_id FROM thread_checkpoints WHERE home_id = ?1")?;
        let rows = statement.query_map([home_id], |row| row.get::<_, String>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for thread_id in stored_ids {
        if !live_ids.contains(thread_id.as_str()) {
            let transaction = ledger.transaction()?;
            delete_thread_rows(&transaction, home_id, &thread_id)?;
            transaction.commit()?;
        }
    }
    Ok(())
}

fn query_totals(ledger: &Connection, home_id: &str, window: UsageWindow) -> Result<LedgerTotals> {
    let total_tokens = query_token_sum(ledger, home_id, None)?;
    Ok(LedgerTotals {
        total_tokens,
        tokens_today: query_token_sum(ledger, home_id, Some(window.today_start_ms))?,
        tokens_week: query_token_sum(ledger, home_id, Some(window.week_start_ms))?,
        tokens_month: query_token_sum(ledger, home_id, Some(window.month_start_ms))?,
    })
}

fn query_token_sum(db: &Connection, home_id: &str, start_ms: Option<i64>) -> Result<u64> {
    let value = if let Some(start_ms) = start_ms {
        db.query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM usage_events WHERE home_id = ?1 AND occurred_at_ms >= ?2",
            params![home_id, start_ms],
            |row| row.get::<_, i64>(0),
        )?
    } else {
        db.query_row(
            "SELECT COALESCE(SUM(total_tokens), 0) FROM usage_events WHERE home_id = ?1",
            [home_id],
            |row| row.get::<_, i64>(0),
        )?
    };
    u64::try_from(value).context("Token ledger aggregate is negative")
}

fn resolve_rollout_path(codex_home: &Path, stored_path: &Path) -> Result<PathBuf> {
    let direct_path = if stored_path.is_absolute() {
        stored_path.to_path_buf()
    } else {
        codex_home.join(stored_path)
    };
    if direct_path.exists() {
        return Ok(direct_path);
    }
    let file_name = stored_path.file_name().ok_or_else(|| {
        anyhow!(
            "Codex rollout path has no file name: {}",
            stored_path.display()
        )
    })?;
    let archived_path = codex_home.join("archived_sessions").join(file_name);
    if archived_path.exists() {
        return Ok(archived_path);
    }
    bail!("Codex rollout file not found: {}", stored_path.display())
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Write;

    use serde_json::json;
    use tempfile::TempDir;

    fn usage(total_tokens: i64) -> TokenUsage {
        TokenUsage {
            total_tokens,
            ..TokenUsage::default()
        }
    }

    fn info(total_tokens: i64, last_tokens: i64) -> TokenUsageInfo {
        TokenUsageInfo {
            total_token_usage: usage(total_tokens),
            last_token_usage: usage(last_tokens),
            model_context_window: None,
        }
    }

    fn token_line(timestamp: &str, total_tokens: i64, last_tokens: i64) -> String {
        json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": { "total_tokens": total_tokens },
                    "last_token_usage": { "total_tokens": last_tokens }
                }
            }
        })
        .to_string()
    }

    fn append_line(path: &Path, line: &str) -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        writeln!(file, "{line}")?;
        Ok(())
    }

    #[test]
    fn concurrent_cumulative_branches_count_each_actual_usage_once() -> Result<()> {
        let zero = TokenUsageInfo::default();
        let first = info(10, 10);
        let branch_one = info(25, 15);
        let branch_two = info(22, 12);
        let mut seen = HashSet::from([zero.total_token_usage.clone()]);

        assert_eq!(
            classify_transition(&zero, &first, &seen)?,
            TokenTransition::Actual
        );
        seen.insert(first.total_token_usage.clone());
        assert_eq!(
            classify_transition(&first, &first, &seen)?,
            TokenTransition::Replay
        );
        assert_eq!(
            classify_transition(&first, &branch_one, &seen)?,
            TokenTransition::Actual
        );
        seen.insert(branch_one.total_token_usage.clone());
        assert_eq!(
            classify_transition(&branch_one, &branch_two, &seen)?,
            TokenTransition::Actual
        );
        assert!(classify_transition(&branch_two, &info(40, 8), &seen).is_err());

        Ok(())
    }

    #[test]
    fn synthetic_context_fill_does_not_create_usage() -> Result<()> {
        let previous = info(100, 100);
        let current = TokenUsageInfo {
            total_token_usage: usage(200),
            last_token_usage: usage(100),
            model_context_window: Some(200),
        };
        let seen = HashSet::from([previous.total_token_usage.clone()]);

        assert_eq!(
            classify_transition(&previous, &current, &seen)?,
            TokenTransition::SyntheticContextFill
        );

        Ok(())
    }

    #[test]
    fn partial_line_is_committed_only_after_newline_arrives() -> Result<()> {
        let root = TempDir::new()?;
        let rollout = root.path().join("rollout.jsonl");
        let first = token_line("2026-03-22T01:00:00Z", 10, 10);
        let second = token_line("2026-03-22T01:01:00Z", 25, 15);
        fs::write(&rollout, format!("{first}\n{second}"))?;

        let parsed = parse_appended_token_records(
            &rollout,
            0,
            fs::metadata(&rollout)?.len(),
            TokenUsageInfo::default(),
            HashSet::from([TokenUsage::default()]),
        )?;
        assert_eq!(parsed.events.len(), 1);
        assert_eq!(parsed.committed_offset, (first.len() + 1) as u64);

        append_line(&rollout, "")?;
        let parsed = parse_appended_token_records(
            &rollout,
            parsed.committed_offset,
            fs::metadata(&rollout)?.len(),
            info(10, 10),
            HashSet::from([usage(0), usage(10)]),
        )?;
        assert_eq!(parsed.events.len(), 1);
        assert_eq!(parsed.events[0].usage.total_tokens, 15);
        assert_eq!(parsed.committed_offset, fs::metadata(&rollout)?.len());

        Ok(())
    }

    #[test]
    fn fork_boundary_matches_a_parent_history_suffix() {
        let parent = vec![usage(10), usage(20), usage(30)];
        let child = vec![
            RawSnapshot {
                source_end_offset: 100,
                info: info(20, 10),
            },
            RawSnapshot {
                source_end_offset: 200,
                info: info(30, 10),
            },
            RawSnapshot {
                source_end_offset: 300,
                info: info(45, 15),
            },
        ];

        assert_eq!(longest_inherited_prefix_length(&parent, &child), 2);
    }

    #[test]
    fn forked_thread_excludes_inherited_usage_and_keeps_child_usage() -> Result<()> {
        let root = TempDir::new()?;
        let codex_home = root.path().join(".codex");
        fs::create_dir_all(&codex_home)?;
        let parent_path = codex_home.join("parent.jsonl");
        let child_path = codex_home.join("child.jsonl");
        let inherited_only_path = codex_home.join("inherited-only.jsonl");
        let parent_line = token_line("2026-03-22T01:00:00Z", 10, 10);
        append_line(&parent_path, &parent_line)?;

        let session_meta = json!({
            "timestamp": "2026-03-22T01:01:00Z",
            "type": "session_meta",
            "payload": {
                "timestamp": "2026-03-22T01:01:00Z",
                "parent_thread_id": "parent"
            }
        })
        .to_string();
        append_line(&child_path, &session_meta)?;
        append_line(&child_path, &parent_line)?;
        append_line(&child_path, &token_line("2026-03-22T01:02:00Z", 15, 5))?;
        append_line(&child_path, &token_line("2026-03-22T01:03:00Z", 10, 10))?;
        append_line(&inherited_only_path, &session_meta)?;
        append_line(&inherited_only_path, &parent_line)?;

        let state = Connection::open(codex_home.join("state_1.sqlite"))?;
        state.execute_batch(
            "
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL
            );
            ",
        )?;
        state.execute(
            "INSERT INTO threads VALUES (?1, ?2, ?3, ?4)",
            params!["parent", parent_path.display().to_string(), 1_i64, 10_i64],
        )?;
        state.execute(
            "INSERT INTO threads VALUES (?1, ?2, ?3, ?4)",
            params!["child", child_path.display().to_string(), 2_i64, 15_i64],
        )?;
        state.execute(
            "INSERT INTO threads VALUES (?1, ?2, ?3, ?4)",
            params![
                "inherited-only",
                inherited_only_path.display().to_string(),
                3_i64,
                10_i64
            ],
        )?;

        let ledger_path = root.path().join("token-ledger.sqlite");
        let totals = sync_and_query(
            &codex_home,
            &state,
            &ledger_path,
            UsageWindow {
                today_start_ms: 0,
                week_start_ms: 0,
                month_start_ms: 0,
            },
        )?;

        assert_eq!(totals.total_tokens, 15);
        assert_eq!(totals.tokens_today, 15);
        let ledger = Connection::open(ledger_path)?;
        assert_eq!(
            ledger.query_row("SELECT COUNT(*) FROM thread_checkpoints", [], |row| row
                .get::<_, u64>(0))?,
            3
        );
        Ok(())
    }
}
