use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration as StdDuration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD_NO_PAD, URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, FixedOffset, Local, TimeZone, Utc};
use rayon::prelude::*;
use reqwest::StatusCode;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};

const USAGE_ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";
const RESPONSES_ENDPOINT: &str = "https://chatgpt.com/backend-api/codex/responses";
const TOKEN_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
const CHATGPT_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const WARMUP_MODEL: &str = "gpt-5";
const WARMUP_PROMPT: &str = "ok";
const DEFAULT_SOFT_TTL_SECONDS: i64 = 60;
const DEFAULT_HARD_TTL_SECONDS: i64 = 15 * 60;
const DEFAULT_TIMEOUT_SECONDS: u64 = 8;
const DEFAULT_CONCURRENCY: usize = 4;
const AUTO_SWITCH_COOLDOWN_SECONDS: i64 = 15 * 60;
const MAX_BACKOFF_SECONDS: i64 = 10 * 60;

#[derive(Debug, Clone)]
pub struct AccountsPaths {
    pub codex_home: PathBuf,
    pub registry_path: PathBuf,
    pub accounts_dir: PathBuf,
    pub auth_path: PathBuf,
    pub cache_path: PathBuf,
}

impl Default for AccountsPaths {
    fn default() -> Self {
        let home_dir = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        let cache_root = dirs::cache_dir().unwrap_or_else(|| home_dir.join(".cache"));
        let codex_home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir.join(".codex"));

        Self {
            registry_path: codex_home.join("accounts").join("registry.json"),
            accounts_dir: codex_home.join("accounts"),
            auth_path: codex_home.join("auth.json"),
            cache_path: cache_root.join("codexbar").join("accounts-snapshot-v1.json"),
            codex_home,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AccountsSnapshotOptions {
    pub now: DateTime<FixedOffset>,
    pub paths: AccountsPaths,
    pub soft_ttl: Duration,
    pub hard_ttl: Duration,
    pub timeout: StdDuration,
    pub force_refresh: bool,
    pub active_only: bool,
    pub concurrency: usize,
}

impl Default for AccountsSnapshotOptions {
    fn default() -> Self {
        Self {
            now: Local::now().fixed_offset(),
            paths: AccountsPaths::default(),
            soft_ttl: Duration::seconds(DEFAULT_SOFT_TTL_SECONDS),
            hard_ttl: Duration::seconds(DEFAULT_HARD_TTL_SECONDS),
            timeout: StdDuration::from_secs(DEFAULT_TIMEOUT_SECONDS),
            force_refresh: false,
            active_only: false,
            concurrency: DEFAULT_CONCURRENCY,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AutoSwitchOptions {
    pub now: DateTime<FixedOffset>,
    pub paths: AccountsPaths,
    pub soft_ttl: Duration,
    pub hard_ttl: Duration,
    pub timeout: StdDuration,
    pub concurrency: usize,
    pub threshold_5h_percent: u8,
    pub threshold_weekly_percent: u8,
    pub force_refresh: bool,
}

impl Default for AutoSwitchOptions {
    fn default() -> Self {
        Self {
            now: Local::now().fixed_offset(),
            paths: AccountsPaths::default(),
            soft_ttl: Duration::seconds(DEFAULT_SOFT_TTL_SECONDS),
            hard_ttl: Duration::seconds(DEFAULT_HARD_TTL_SECONDS),
            timeout: StdDuration::from_secs(DEFAULT_TIMEOUT_SECONDS),
            concurrency: DEFAULT_CONCURRENCY,
            threshold_5h_percent: 10,
            threshold_weekly_percent: 5,
            force_refresh: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountsSnapshotV1 {
    pub generated_at: String,
    pub status: AccountSnapshotStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_account_key: Option<String>,
    pub account_count: u32,
    pub healthy_account_count: u32,
    pub stale_account_count: u32,
    pub accounts: Vec<AccountUsageSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountUsageSnapshot {
    pub account_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    pub email: String,
    pub alias: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_name: Option<String>,
    pub plan: String,
    pub auth_mode: String,
    pub is_active: bool,
    pub is_reachable: bool,
    pub status: AccountSnapshotStatus,
    pub usage_source: UsageSource,
    pub generated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_usage_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<UsageWindowSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weekly: Option<UsageWindowSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AccountSnapshotStatus {
    Ok,
    Stale,
    Error,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UsageSource {
    Live,
    Cache,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindowSnapshot {
    pub used_percent: u8,
    pub window_minutes: u32,
    pub resets_at: String,
    pub resets_in_label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountActionResult {
    pub ok: bool,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_key: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct AccountsCacheEnvelope {
    #[serde(default)]
    accounts: HashMap<String, CachedAccountEntry>,
    #[serde(default)]
    auto_switch_last_applied_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedAccountEntry {
    snapshot: AccountUsageSnapshot,
    #[serde(default)]
    failure_count: u32,
    #[serde(default)]
    next_retry_at: Option<String>,
    #[serde(default)]
    last_live_success_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct RegistryFile {
    #[serde(default = "default_schema_version")]
    schema_version: u32,
    #[serde(default)]
    active_account_key: Option<String>,
    #[serde(default)]
    active_account_activated_at_ms: Option<i64>,
    #[serde(default)]
    auto_switch: RegistryAutoSwitch,
    #[serde(default)]
    accounts: Vec<RegistryAccount>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "snake_case")]
struct RegistryAutoSwitch {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    threshold_5h_percent: u8,
    #[serde(default)]
    threshold_weekly_percent: u8,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct RegistryAccount {
    account_key: String,
    #[serde(default)]
    chatgpt_account_id: Option<String>,
    #[serde(default)]
    chatgpt_user_id: Option<String>,
    #[serde(default)]
    email: String,
    #[serde(default)]
    alias: String,
    #[serde(default)]
    workspace_name: Option<String>,
    #[serde(default)]
    plan: String,
    #[serde(default)]
    auth_mode: String,
    #[serde(default)]
    last_usage: Option<RegistryUsage>,
    #[serde(default)]
    last_usage_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct RegistryUsage {
    #[serde(default)]
    primary: Option<RegistryWindow>,
    #[serde(default)]
    secondary: Option<RegistryWindow>,
    #[serde(default)]
    plan_type: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct RegistryWindow {
    #[serde(default)]
    used_percent: u8,
    #[serde(default)]
    window_minutes: u32,
    #[serde(default)]
    resets_at: i64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
struct AuthFile {
    #[serde(default)]
    auth_mode: String,
    #[serde(default)]
    tokens: AuthTokens,
    #[serde(default)]
    last_refresh: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "snake_case")]
struct AuthTokens {
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    id_token: Option<String>,
    #[serde(default)]
    account_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
struct IdTokenClaims {
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default, rename = "https://api.openai.com/auth")]
    auth: Option<OpenAiAuthClaims>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
struct OpenAiAuthClaims {
    #[serde(default)]
    chatgpt_account_id: Option<String>,
    #[serde(default)]
    chatgpt_plan_type: Option<String>,
    #[serde(default)]
    chatgpt_user_id: Option<String>,
    #[serde(default)]
    user_id: Option<String>,
    #[serde(default)]
    organizations: Vec<OpenAiOrganization>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
struct OpenAiOrganization {
    #[serde(default)]
    is_default: bool,
    #[serde(default)]
    title: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct LiveUsageResponse {
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    plan_type: Option<String>,
    #[serde(default)]
    rate_limit: Option<LiveRateLimit>,
}

#[derive(Debug, Clone, Deserialize)]
struct LiveRateLimit {
    #[serde(default)]
    primary_window: Option<LiveWindow>,
    #[serde(default)]
    secondary_window: Option<LiveWindow>,
}

#[derive(Debug, Clone, Deserialize)]
struct LiveWindow {
    used_percent: u8,
    #[serde(default)]
    limit_window_seconds: u32,
    #[serde(default)]
    reset_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
struct RefreshResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    id_token: Option<String>,
}

#[derive(Debug, Clone)]
struct AccountContext {
    registry: RegistryAccount,
    auth_file_path: Option<PathBuf>,
    auth_file: Option<AuthFile>,
    cached: Option<CachedAccountEntry>,
    is_active: bool,
}

#[derive(Debug, Clone)]
struct FetchResult {
    snapshot: AccountUsageSnapshot,
    cache_entry: Option<CachedAccountEntry>,
}

pub fn load_accounts_snapshot(options: &AccountsSnapshotOptions) -> Result<AccountsSnapshotV1> {
    let mut registry = read_or_init_registry(&options.paths.registry_path)?;
    sync_current_auth_into_registry(&options.paths, &mut registry)?;
    let mut cache = read_accounts_cache(&options.paths.cache_path).unwrap_or_default();
    let auth_files = discover_auth_files(&options.paths.accounts_dir)?;
    let contexts = build_account_contexts(&registry, auth_files, &cache, options.active_only);
    let client = Arc::new(build_http_client(options.timeout)?);

    let threads = options.concurrency.max(1);
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .context("Failed to build account refresh thread pool")?;

    let fetch_results = pool.install(|| {
        contexts
            .into_par_iter()
            .map(|context| resolve_account_snapshot(context, options, client.as_ref()))
            .collect::<Vec<_>>()
    });

    let mut accounts = Vec::new();
    let mut errors = Vec::new();
    for result in fetch_results {
        match result {
            Ok(fetch) => {
                cache.accounts.insert(
                    fetch.snapshot.account_key.clone(),
                    fetch.cache_entry.unwrap_or_else(|| CachedAccountEntry {
                        snapshot: fetch.snapshot.clone(),
                        failure_count: 0,
                        next_retry_at: None,
                        last_live_success_at: Some(fetch.snapshot.generated_at.clone()),
                    }),
                );
                accounts.push(fetch.snapshot);
            }
            Err(error) => errors.push(error.to_string()),
        }
    }

    if accounts.is_empty() {
        write_accounts_cache(&options.paths.cache_path, &cache)?;
        return Ok(AccountsSnapshotV1 {
            generated_at: options.now.to_rfc3339(),
            status: AccountSnapshotStatus::Ok,
            error: None,
            active_account_key: registry.active_account_key,
            account_count: 0,
            healthy_account_count: 0,
            stale_account_count: 0,
            accounts,
        });
    }

    accounts.sort_by(account_sort_key);
    write_accounts_cache(&options.paths.cache_path, &cache)?;

    let healthy_account_count = accounts
        .iter()
        .filter(|account| account.status == AccountSnapshotStatus::Ok)
        .count() as u32;
    let stale_account_count = accounts
        .iter()
        .filter(|account| account.status == AccountSnapshotStatus::Stale)
        .count() as u32;
    let status = if healthy_account_count > 0 {
        if stale_account_count > 0 || accounts.iter().any(|account| account.status == AccountSnapshotStatus::Error) {
            AccountSnapshotStatus::Stale
        } else {
            AccountSnapshotStatus::Ok
        }
    } else {
        AccountSnapshotStatus::Error
    };

    Ok(AccountsSnapshotV1 {
        generated_at: options.now.to_rfc3339(),
        status,
        error: (!errors.is_empty()).then(|| errors.join(" | ")),
        active_account_key: registry.active_account_key,
        account_count: accounts.len() as u32,
        healthy_account_count,
        stale_account_count,
        accounts,
    })
}

pub fn activate_account(paths: &AccountsPaths, account_key: &str, now: DateTime<FixedOffset>) -> Result<AccountActionResult> {
    let mut registry = read_registry(&paths.registry_path)?;
    let auth_files = discover_auth_files(&paths.accounts_dir)?;
    let registry_account = registry
        .accounts
        .iter()
        .find(|account| account.account_key == account_key)
        .cloned()
        .with_context(|| format!("Unknown account key: {account_key}"))?;
    let account_id = registry_account
        .chatgpt_account_id
        .clone()
        .ok_or_else(|| anyhow!("Account {account_key} is missing chatgptAccountId"))?;
    let auth_path = auth_files
        .get(&account_id)
        .map(|entry| entry.0.clone())
        .with_context(|| format!("Missing auth file for account {account_key}"))?;

    if paths.auth_path.exists() {
        let backup_path = paths
            .accounts_dir
            .join(format!("auth.json.bak.{}", now.format("%Y%m%d-%H%M%S")));
        fs::create_dir_all(&paths.accounts_dir)?;
        fs::copy(&paths.auth_path, &backup_path)
            .with_context(|| format!("Failed to backup {}", paths.auth_path.display()))?;
    }

    let auth_payload = fs::read(&auth_path)
        .with_context(|| format!("Failed to read {}", auth_path.display()))?;
    atomic_write(&paths.auth_path, &auth_payload)?;

    registry.active_account_key = Some(account_key.to_string());
    registry.active_account_activated_at_ms = Some(now.timestamp_millis());
    write_registry(&paths.registry_path, &registry)?;

    Ok(AccountActionResult {
        ok: true,
        action: "activate".to_string(),
        account_key: Some(account_key.to_string()),
        message: format!("Activated account {account_key}"),
    })
}

pub fn warmup_account(
    paths: &AccountsPaths,
    account_key: &str,
    timeout: StdDuration,
) -> Result<AccountActionResult> {
    let registry = read_registry(&paths.registry_path)?;
    let registry_account = registry
        .accounts
        .iter()
        .find(|account| account.account_key == account_key)
        .cloned()
        .with_context(|| format!("Unknown account key: {account_key}"))?;
    let account_id = registry_account
        .chatgpt_account_id
        .clone()
        .ok_or_else(|| anyhow!("Account {account_key} is missing chatgptAccountId"))?;

    let auth_files = discover_auth_files(&paths.accounts_dir)?;
    let (auth_path, mut auth_file) = auth_files
        .get(&account_id)
        .cloned()
        .with_context(|| format!("Missing auth file for account {account_key}"))?;

    let client = build_http_client(timeout)?;

    let mut response = send_responses_warmup(&client, &auth_file, Some(account_id.as_str()))?;
    if response.status() == StatusCode::UNAUTHORIZED {
        refresh_auth_tokens(&client, &mut auth_file)?;
        let bytes = serde_json::to_vec_pretty(&auth_file)
            .context("Failed to serialize refreshed auth file")?;
        atomic_write(&auth_path, &bytes)?;
        response = send_responses_warmup(&client, &auth_file, Some(account_id.as_str()))?;
    }

    let status = response.status();
    if !status.is_success() {
        let body = response
            .text()
            .unwrap_or_else(|_| "<unreadable body>".to_string());
        bail!("Warm-up request returned {status}: {body}");
    }

    // Drain the body so the connection can be returned to the pool. We don't
    // need the contents — the request itself is what registers the message
    // against the account's 5h window on OpenAI's backend.
    let _ = response.bytes();

    Ok(AccountActionResult {
        ok: true,
        action: "warmup".to_string(),
        account_key: Some(account_key.to_string()),
        message: format!("Warm-up request sent for {account_key}"),
    })
}

fn send_responses_warmup(
    client: &Client,
    auth_file: &AuthFile,
    chatgpt_account_id: Option<&str>,
) -> Result<reqwest::blocking::Response> {
    let access_token = auth_file
        .tokens
        .access_token
        .as_deref()
        .ok_or_else(|| anyhow!("Auth file is missing access_token"))?;

    // Minimal Responses API payload. The endpoint *requires* `stream: true`
    // (it returns 400 "Stream must be set to true" otherwise), so we ask for
    // the cheapest possible streamed response and drain it. `store: false`
    // avoids polluting the account's saved history; `max_output_tokens: 16`
    // keeps token spend trivial. The goal isn't to get a useful answer —
    // just to ping the Responses endpoint as this account so OpenAI starts
    // the rolling 5h rate-limit window.
    let body = serde_json::json!({
        "model": WARMUP_MODEL,
        "instructions": "Reply with the single word: ok",
        "input": [{
            "type": "message",
            "role": "user",
            "content": [{ "type": "input_text", "text": WARMUP_PROMPT }]
        }],
        "store": false,
        "stream": true
    });

    let mut request = client
        .post(RESPONSES_ENDPOINT)
        .bearer_auth(access_token)
        .header("Accept", "text/event-stream")
        .header("OpenAI-Beta", "responses=experimental")
        .json(&body);
    if let Some(id) = chatgpt_account_id {
        request = request.header("chatgpt-account-id", id);
    }

    request
        .send()
        .context("Failed to send warm-up request to Responses endpoint")
}

pub fn remove_account(paths: &AccountsPaths, account_key: &str) -> Result<AccountActionResult> {
    let mut registry = read_or_init_registry(&paths.registry_path)?;
    if registry.active_account_key.as_deref() == Some(account_key) {
        bail!("Cannot remove the active account");
    }

    let index = registry
        .accounts
        .iter()
        .position(|account| account.account_key == account_key)
        .with_context(|| format!("Unknown account key: {account_key}"))?;
    let removed_account = registry.accounts.remove(index);

    if let Some(account_id) = removed_account.chatgpt_account_id.as_deref() {
        let auth_files = discover_auth_files(&paths.accounts_dir)?;
        if let Some((auth_path, _)) = auth_files.get(account_id) {
            if auth_path.exists() {
                fs::remove_file(auth_path)
                    .with_context(|| format!("Failed to remove {}", auth_path.display()))?;
            }
        }
    }

    write_registry(&paths.registry_path, &registry)?;

    let mut cache = read_accounts_cache(&paths.cache_path).unwrap_or_default();
    cache.accounts.remove(account_key);
    write_accounts_cache(&paths.cache_path, &cache)?;

    Ok(AccountActionResult {
        ok: true,
        action: "remove".to_string(),
        account_key: Some(account_key.to_string()),
        message: format!("Removed account {account_key}"),
    })
}

pub fn spawn_account_login(terminal_command: Option<&str>, login_command: Option<&str>) -> Result<AccountActionResult> {
    let login_command = login_command
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("codex login");
    let shell_command = if let Some(template) = terminal_command.filter(|value| !value.trim().is_empty()) {
        if template.contains("{command}") {
            template.replace("{command}", login_command)
        } else {
            format!("{template} {login_command}")
        }
    } else if let Ok(terminal) = std::env::var("TERMINAL") {
        format!("{terminal} -e {login_command}")
    } else {
        format!("kitty -e {login_command}")
    };

    Command::new("sh")
        .arg("-lc")
        .arg(shell_command)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("Failed to launch Codex login terminal")?;

    Ok(AccountActionResult {
        ok: true,
        action: "login".to_string(),
        account_key: None,
        message: format!("Started Codex login using `{login_command}`"),
    })
}

pub fn auto_switch_account(options: &AutoSwitchOptions) -> Result<AccountActionResult> {
    let snapshot = load_accounts_snapshot(&AccountsSnapshotOptions {
        now: options.now,
        paths: options.paths.clone(),
        soft_ttl: options.soft_ttl,
        hard_ttl: options.hard_ttl,
        timeout: options.timeout,
        force_refresh: options.force_refresh,
        active_only: false,
        concurrency: options.concurrency,
    })?;

    let current = snapshot
        .accounts
        .iter()
        .find(|account| account.is_active)
        .ok_or_else(|| anyhow!("No active account available"))?;

    let current_session = current.session.as_ref().map(|window| window.used_percent).unwrap_or(0);
    let current_weekly = current.weekly.as_ref().map(|window| window.used_percent).unwrap_or(0);
    if current_session < options.threshold_5h_percent && current_weekly < options.threshold_weekly_percent {
        return Ok(AccountActionResult {
            ok: true,
            action: "auto-switch".to_string(),
            account_key: Some(current.account_key.clone()),
            message: "Current account is below auto-switch thresholds".to_string(),
        });
    }

    let mut cache = read_accounts_cache(&options.paths.cache_path).unwrap_or_default();
    if let Some(last_applied_at) = cache
        .auto_switch_last_applied_at
        .as_deref()
        .and_then(parse_datetime)
        && options.now - last_applied_at < Duration::seconds(AUTO_SWITCH_COOLDOWN_SECONDS)
    {
        return Ok(AccountActionResult {
            ok: true,
            action: "auto-switch".to_string(),
            account_key: Some(current.account_key.clone()),
            message: "Auto-switch cooldown is still active".to_string(),
        });
    }

    let candidate = snapshot
        .accounts
        .iter()
        .filter(|account| !account.is_active)
        .filter(|account| account.usage_source == UsageSource::Live && account.status == AccountSnapshotStatus::Ok)
        .max_by_key(|account| {
            (
                100_i16 - account.session.as_ref().map(|window| window.used_percent as i16).unwrap_or(100),
                100_i16 - account.weekly.as_ref().map(|window| window.used_percent as i16).unwrap_or(100),
                account.generated_at.clone(),
            )
        });

    let candidate = if let Some(candidate) = candidate {
        candidate
    } else {
        return Ok(AccountActionResult {
            ok: true,
            action: "auto-switch".to_string(),
            account_key: Some(current.account_key.clone()),
            message: "No live account candidate is better than the current account".to_string(),
        });
    };

    let candidate_session_left = 100_i16 - candidate.session.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    let candidate_weekly_left = 100_i16 - candidate.weekly.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    let current_session_left = 100_i16 - current.session.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    let current_weekly_left = 100_i16 - current.weekly.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    if (candidate_session_left, candidate_weekly_left) <= (current_session_left, current_weekly_left) {
        return Ok(AccountActionResult {
            ok: true,
            action: "auto-switch".to_string(),
            account_key: Some(current.account_key.clone()),
            message: "Current account is already the best live candidate".to_string(),
        });
    }

    let result = activate_account(&options.paths, &candidate.account_key, options.now)?;
    cache.auto_switch_last_applied_at = Some(options.now.to_rfc3339());
    write_accounts_cache(&options.paths.cache_path, &cache)?;
    Ok(result)
}

fn build_http_client(timeout: StdDuration) -> Result<Client> {
    Client::builder()
        .timeout(timeout)
        .user_agent("codexbar-collector/0.1")
        .build()
        .context("Failed to build HTTP client")
}

fn read_registry(path: &Path) -> Result<RegistryFile> {
    let content = fs::read_to_string(path).with_context(|| format!("Failed to read {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| format!("Failed to parse {}", path.display()))
}

fn read_or_init_registry(path: &Path) -> Result<RegistryFile> {
    if path.exists() {
        return read_registry(path);
    }

    let registry = RegistryFile {
        schema_version: default_schema_version(),
        active_account_key: None,
        active_account_activated_at_ms: None,
        auto_switch: RegistryAutoSwitch::default(),
        accounts: Vec::new(),
    };
    write_registry(path, &registry)?;
    Ok(registry)
}

fn write_registry(path: &Path, registry: &RegistryFile) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(registry)?;
    atomic_write(path, &bytes)
}

fn discover_auth_files(accounts_dir: &Path) -> Result<HashMap<String, (PathBuf, AuthFile)>> {
    let mut auth_files = HashMap::new();
    if !accounts_dir.exists() {
        return Ok(auth_files);
    }

    for entry in fs::read_dir(accounts_dir).with_context(|| format!("Failed to read {}", accounts_dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if !path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".auth.json"))
        {
            continue;
        }

        let content = fs::read_to_string(&path).with_context(|| format!("Failed to read {}", path.display()))?;
        let auth_file: AuthFile =
            serde_json::from_str(&content).with_context(|| format!("Failed to parse {}", path.display()))?;
        if let Some(account_id) = auth_file.tokens.account_id.clone() {
            auth_files.insert(account_id, (path, auth_file));
        }
    }

    Ok(auth_files)
}

fn sync_current_auth_into_registry(paths: &AccountsPaths, registry: &mut RegistryFile) -> Result<()> {
    if !paths.auth_path.exists() {
        return Ok(());
    }

    let content =
        fs::read_to_string(&paths.auth_path).with_context(|| format!("Failed to read {}", paths.auth_path.display()))?;
    let auth_file: AuthFile =
        serde_json::from_str(&content).with_context(|| format!("Failed to parse {}", paths.auth_path.display()))?;
    let claims = auth_file
        .tokens
        .id_token
        .as_deref()
        .and_then(parse_id_token_claims);
    let Some(account_id) = auth_file.tokens.account_id.clone().or_else(|| {
        claims
            .as_ref()
            .and_then(|claims| claims.auth.as_ref())
            .and_then(|auth| auth.chatgpt_account_id.clone())
    }) else {
        return Ok(());
    };
    let user_id = claims
        .as_ref()
        .and_then(|claims| claims.auth.as_ref())
        .and_then(|auth| auth.chatgpt_user_id.clone().or_else(|| auth.user_id.clone()))
        .unwrap_or_else(|| account_id.clone());
    let account_key = format!("{user_id}::{account_id}");
    let email = claims
        .as_ref()
        .and_then(|claims| claims.email.clone())
        .unwrap_or_default();
    let alias = claims
        .as_ref()
        .and_then(|claims| claims.name.clone())
        .unwrap_or_default();
    let workspace_name = claims
        .as_ref()
        .and_then(|claims| claims.auth.as_ref())
        .and_then(default_workspace_name);
    let plan = claims
        .as_ref()
        .and_then(|claims| claims.auth.as_ref())
        .and_then(|auth| auth.chatgpt_plan_type.clone())
        .unwrap_or_default();

    let mut changed = false;
    if let Some(existing) = registry.accounts.iter_mut().find(|account| {
        account.account_key == account_key
            || account.chatgpt_account_id.as_deref() == Some(account_id.as_str())
    }) {
        if existing.account_key != account_key {
            existing.account_key = account_key.clone();
            changed = true;
        }
        if existing.chatgpt_account_id.as_deref() != Some(account_id.as_str()) {
            existing.chatgpt_account_id = Some(account_id.clone());
            changed = true;
        }
        if existing.chatgpt_user_id.as_deref() != Some(user_id.as_str()) {
            existing.chatgpt_user_id = Some(user_id.clone());
            changed = true;
        }
        if !email.is_empty() {
            if existing.email != email {
                existing.email = email.clone();
                changed = true;
            }
        }
        if existing.alias.is_empty() && !alias.is_empty() {
            existing.alias = alias.clone();
            changed = true;
        }
        if existing.workspace_name.as_deref() != workspace_name.as_deref() {
            existing.workspace_name = workspace_name.clone();
            changed = true;
        }
        if existing.plan.is_empty() && !plan.is_empty() {
            existing.plan = plan.clone();
            changed = true;
        }
        if existing.auth_mode.is_empty() && !auth_file.auth_mode.is_empty() {
            existing.auth_mode = auth_file.auth_mode.clone();
            changed = true;
        }
    } else {
        registry.accounts.push(RegistryAccount {
            account_key: account_key.clone(),
            chatgpt_account_id: Some(account_id.clone()),
            chatgpt_user_id: Some(user_id.clone()),
            email,
            alias,
            workspace_name,
            plan,
            auth_mode: auth_file.auth_mode.clone(),
            last_usage: None,
            last_usage_at: None,
        });
        changed = true;
    }

    if registry.active_account_key.as_deref() != Some(account_key.as_str()) {
        registry.active_account_key = Some(account_key.clone());
        changed = true;
    }

    let encoded_name = STANDARD_NO_PAD.encode(account_key.as_bytes());
    let target_auth_path = paths.accounts_dir.join(format!("{encoded_name}.auth.json"));
    if !target_auth_path.exists() {
        fs::create_dir_all(&paths.accounts_dir)?;
        let bytes = serde_json::to_vec_pretty(&auth_file)?;
        atomic_write(&target_auth_path, &bytes)?;
        changed = true;
    }

    if changed {
        write_registry(&paths.registry_path, registry)?;
    }

    Ok(())
}

fn build_account_contexts(
    registry: &RegistryFile,
    auth_files: HashMap<String, (PathBuf, AuthFile)>,
    cache: &AccountsCacheEnvelope,
    active_only: bool,
) -> Vec<AccountContext> {
    registry
        .accounts
        .iter()
        .filter(|account| !active_only || registry.active_account_key.as_deref() == Some(account.account_key.as_str()))
        .map(|account| {
            let auth_match = account
                .chatgpt_account_id
                .as_ref()
                .and_then(|account_id| auth_files.get(account_id))
                .cloned();
            AccountContext {
                registry: account.clone(),
                auth_file_path: auth_match.as_ref().map(|entry| entry.0.clone()),
                auth_file: auth_match.map(|entry| entry.1),
                cached: cache.accounts.get(&account.account_key).cloned(),
                is_active: registry.active_account_key.as_deref() == Some(account.account_key.as_str()),
            }
        })
        .collect()
}

fn resolve_account_snapshot(
    context: AccountContext,
    options: &AccountsSnapshotOptions,
    client: &Client,
) -> Result<FetchResult> {
    let now = options.now;
    let cache_entry = context.cached.clone();
    let can_retry_live = can_attempt_live(cache_entry.as_ref(), now, options.force_refresh);
    let cache_is_fresh = cache_entry
        .as_ref()
        .and_then(|entry| parse_datetime(&entry.snapshot.generated_at))
        .is_some_and(|timestamp| now - timestamp <= options.soft_ttl);

    if !options.force_refresh && cache_is_fresh {
        let snapshot = normalize_snapshot_from_cache(&context, cache_entry.clone(), options);
        return Ok(FetchResult { snapshot, cache_entry });
    }

    if can_retry_live {
        if let Some(auth_file) = context.auth_file.clone() {
            match fetch_live_usage_for_account(client, &context, auth_file, options.timeout, options.now) {
                Ok((snapshot, auth_file)) => {
                    if let Some(auth_path) = context.auth_file_path.as_ref() {
                        let bytes = serde_json::to_vec_pretty(&auth_file)?;
                        atomic_write(auth_path, &bytes)?;
                    }
                    let cache_entry = CachedAccountEntry {
                        snapshot: snapshot.clone(),
                        failure_count: 0,
                        next_retry_at: None,
                        last_live_success_at: Some(snapshot.generated_at.clone()),
                    };
                    return Ok(FetchResult {
                        snapshot,
                        cache_entry: Some(cache_entry),
                    });
                }
                Err(error) => {
                    let fallback_snapshot =
                        build_fallback_snapshot(&context, cache_entry.clone(), options, Some(error.to_string()));
                    let failure_count = cache_entry.as_ref().map(|entry| entry.failure_count).unwrap_or(0) + 1;
                    let next_retry_at = options.now + Duration::seconds(backoff_seconds(failure_count));
                    let updated_cache = CachedAccountEntry {
                        snapshot: fallback_snapshot.clone(),
                        failure_count,
                        next_retry_at: Some(next_retry_at.to_rfc3339()),
                        last_live_success_at: cache_entry.and_then(|entry| entry.last_live_success_at),
                    };
                    return Ok(FetchResult {
                        snapshot: fallback_snapshot,
                        cache_entry: Some(updated_cache),
                    });
                }
            }
        }
    }

    let snapshot = build_fallback_snapshot(&context, cache_entry.clone(), options, None);
    Ok(FetchResult { snapshot, cache_entry })
}

fn fetch_live_usage_for_account(
    client: &Client,
    context: &AccountContext,
    mut auth_file: AuthFile,
    timeout: StdDuration,
    now: DateTime<FixedOffset>,
) -> Result<(AccountUsageSnapshot, AuthFile)> {
    let _ = timeout;
    let mut response = fetch_usage_with_access_token(client, &auth_file)?;
    if response.status() == StatusCode::UNAUTHORIZED {
        refresh_auth_tokens(client, &mut auth_file)?;
        response = fetch_usage_with_access_token(client, &auth_file)?;
    }

    if !response.status().is_success() {
        bail!("Usage endpoint returned {}", response.status());
    }

    let payload: LiveUsageResponse = response.json().context("Failed to decode usage response")?;
    let rate_limit = payload
        .rate_limit
        .ok_or_else(|| anyhow!("Usage response is missing rate_limit"))?;

    let session = rate_limit.primary_window.as_ref().map(|window| live_window_to_snapshot(window, now));
    let weekly = rate_limit
        .secondary_window
        .as_ref()
        .map(|window| live_window_to_snapshot(window, now));

    if session.is_none() && weekly.is_none() {
        bail!("Usage response does not include primary or secondary windows");
    }

    let generated_at = now.to_rfc3339();
    let email = payload.email.unwrap_or_else(|| context.registry.email.clone());
    let plan = payload
        .plan_type
        .or_else(|| context.registry.last_usage.as_ref().and_then(|usage| usage.plan_type.clone()))
        .unwrap_or_else(|| context.registry.plan.clone());

    Ok((
        AccountUsageSnapshot {
            account_key: context.registry.account_key.clone(),
            account_id: context.registry.chatgpt_account_id.clone(),
            user_id: context.registry.chatgpt_user_id.clone(),
            email,
            alias: context.registry.alias.clone(),
            workspace_name: context.registry.workspace_name.clone(),
            plan,
            auth_mode: if context.registry.auth_mode.is_empty() {
                auth_file.auth_mode.clone()
            } else {
                context.registry.auth_mode.clone()
            },
            is_active: context.is_active,
            is_reachable: true,
            status: AccountSnapshotStatus::Ok,
            usage_source: UsageSource::Live,
            generated_at: generated_at.clone(),
            last_usage_at: Some(generated_at),
            session,
            weekly,
            error: None,
        },
        auth_file,
    ))
}

fn fetch_usage_with_access_token(client: &Client, auth_file: &AuthFile) -> Result<reqwest::blocking::Response> {
    let access_token = auth_file
        .tokens
        .access_token
        .as_deref()
        .ok_or_else(|| anyhow!("Auth file is missing access_token"))?;
    client
        .get(USAGE_ENDPOINT)
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .send()
        .context("Failed to query usage endpoint")
}

fn refresh_auth_tokens(client: &Client, auth_file: &mut AuthFile) -> Result<()> {
    let refresh_token = auth_file
        .tokens
        .refresh_token
        .as_deref()
        .ok_or_else(|| anyhow!("Auth file is missing refresh_token"))?;
    let payload = serde_json::json!({
        "client_id": CHATGPT_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email offline_access"
    });
    let response = client
        .post(TOKEN_ENDPOINT)
        .json(&payload)
        .send()
        .context("Failed to refresh access token")?;
    if !response.status().is_success() {
        bail!("Token refresh failed with {}", response.status());
    }
    let refreshed: RefreshResponse = response.json().context("Failed to decode refreshed token response")?;
    auth_file.tokens.access_token = Some(refreshed.access_token);
    if let Some(refresh_token) = refreshed.refresh_token {
        auth_file.tokens.refresh_token = Some(refresh_token);
    }
    if let Some(id_token) = refreshed.id_token {
        auth_file.tokens.id_token = Some(id_token);
    }
    auth_file.last_refresh = Some(Utc::now().to_rfc3339());
    Ok(())
}

fn normalize_snapshot_from_cache(
    context: &AccountContext,
    cache_entry: Option<CachedAccountEntry>,
    options: &AccountsSnapshotOptions,
) -> AccountUsageSnapshot {
    build_fallback_snapshot(context, cache_entry, options, None)
}

fn build_fallback_snapshot(
    context: &AccountContext,
    cache_entry: Option<CachedAccountEntry>,
    options: &AccountsSnapshotOptions,
    error: Option<String>,
) -> AccountUsageSnapshot {
    if let Some(entry) = cache_entry.as_ref() {
        let snapshot_age = parse_datetime(&entry.snapshot.generated_at)
            .map(|timestamp| options.now - timestamp)
            .unwrap_or_else(|| options.hard_ttl + Duration::seconds(1));
        let mut snapshot = entry.snapshot.clone();
        snapshot.is_active = context.is_active;
        snapshot.is_reachable = context.auth_file.is_some();
        snapshot.usage_source = UsageSource::Cache;
        snapshot.status = if snapshot_age > options.hard_ttl {
            AccountSnapshotStatus::Stale
        } else {
            snapshot.status
        };
        if snapshot.status != AccountSnapshotStatus::Ok {
            snapshot.status = AccountSnapshotStatus::Stale;
        }
        if snapshot.last_usage_at.is_none() {
            snapshot.last_usage_at = Some(snapshot.generated_at.clone());
        }
        if snapshot.workspace_name.is_none() {
            snapshot.workspace_name = context.registry.workspace_name.clone();
        }
        snapshot.error = error.or(snapshot.error);
        return snapshot;
    }

    let session = context
        .registry
        .last_usage
        .as_ref()
        .and_then(|usage| usage.primary.as_ref())
        .map(|window| registry_window_to_snapshot(window, options.now));
    let weekly = context
        .registry
        .last_usage
        .as_ref()
        .and_then(|usage| usage.secondary.as_ref())
        .map(|window| registry_window_to_snapshot(window, options.now));

    let last_usage_at = context
        .registry
        .last_usage_at
        .and_then(|timestamp| options.now.timezone().timestamp_opt(timestamp, 0).single())
        .map(|timestamp| timestamp.to_rfc3339());

    let status = if session.is_some() || weekly.is_some() {
        AccountSnapshotStatus::Stale
    } else {
        AccountSnapshotStatus::Error
    };

    AccountUsageSnapshot {
        account_key: context.registry.account_key.clone(),
        account_id: context.registry.chatgpt_account_id.clone(),
        user_id: context.registry.chatgpt_user_id.clone(),
        email: context.registry.email.clone(),
        alias: context.registry.alias.clone(),
        workspace_name: context.registry.workspace_name.clone(),
        plan: context
            .registry
            .last_usage
            .as_ref()
            .and_then(|usage| usage.plan_type.clone())
            .unwrap_or_else(|| context.registry.plan.clone()),
        auth_mode: context.registry.auth_mode.clone(),
        is_active: context.is_active,
        is_reachable: context.auth_file.is_some(),
        status,
        usage_source: UsageSource::Cache,
        generated_at: last_usage_at.clone().unwrap_or_else(|| options.now.to_rfc3339()),
        last_usage_at,
        session,
        weekly,
        error,
    }
}

fn can_attempt_live(cache_entry: Option<&CachedAccountEntry>, now: DateTime<FixedOffset>, force_refresh: bool) -> bool {
    if force_refresh {
        return true;
    }
    let Some(entry) = cache_entry else {
        return true;
    };
    let Some(next_retry_at) = entry.next_retry_at.as_deref().and_then(parse_datetime) else {
        return true;
    };
    now >= next_retry_at
}

fn account_sort_key(account: &AccountUsageSnapshot, other: &AccountUsageSnapshot) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if account.is_active != other.is_active {
        return other.is_active.cmp(&account.is_active);
    }
    if account.status != other.status {
        let rank = |status: AccountSnapshotStatus| match status {
            AccountSnapshotStatus::Ok => 3,
            AccountSnapshotStatus::Stale => 2,
            AccountSnapshotStatus::Error => 1,
        };
        return rank(other.status).cmp(&rank(account.status));
    }
    let account_session_left = 100_i16 - account.session.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    let other_session_left = 100_i16 - other.session.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    match other_session_left.cmp(&account_session_left) {
        Ordering::Equal => {}
        ordering => return ordering,
    }
    let account_weekly_left = 100_i16 - account.weekly.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    let other_weekly_left = 100_i16 - other.weekly.as_ref().map(|window| window.used_percent as i16).unwrap_or(100);
    match other_weekly_left.cmp(&account_weekly_left) {
        Ordering::Equal => {}
        ordering => return ordering,
    }
    account.email.cmp(&other.email)
}

fn live_window_to_snapshot(window: &LiveWindow, now: DateTime<FixedOffset>) -> UsageWindowSnapshot {
    let reset_at = now
        .timezone()
        .timestamp_opt(window.reset_at, 0)
        .single()
        .unwrap_or(now);
    UsageWindowSnapshot {
        used_percent: window.used_percent,
        window_minutes: window.limit_window_seconds / 60,
        resets_at: reset_at.to_rfc3339(),
        resets_in_label: format_reset_label(now, reset_at),
    }
}

fn registry_window_to_snapshot(window: &RegistryWindow, now: DateTime<FixedOffset>) -> UsageWindowSnapshot {
    let reset_at = now
        .timezone()
        .timestamp_opt(window.resets_at, 0)
        .single()
        .unwrap_or(now);
    UsageWindowSnapshot {
        used_percent: window.used_percent,
        window_minutes: window.window_minutes,
        resets_at: reset_at.to_rfc3339(),
        resets_in_label: format_reset_label(now, reset_at),
    }
}

fn format_reset_label(now: DateTime<FixedOffset>, reset_at: DateTime<FixedOffset>) -> String {
    let diff = reset_at - now;
    if diff.num_seconds() <= 0 {
        return "now".to_string();
    }
    if diff.num_days() >= 1 {
        return format!("{}d {}h", diff.num_days(), diff.num_hours() % 24);
    }
    if diff.num_hours() >= 1 {
        return format!("{}h {}m", diff.num_hours(), diff.num_minutes() % 60);
    }
    format!("{}m", diff.num_minutes().max(1))
}

fn parse_datetime(value: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(value).ok()
}

fn read_accounts_cache(path: &Path) -> Result<AccountsCacheEnvelope> {
    let content = fs::read_to_string(path).with_context(|| format!("Failed to read {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| format!("Failed to parse {}", path.display()))
}

fn write_accounts_cache(path: &Path, cache: &AccountsCacheEnvelope) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(cache)?;
    atomic_write(path, &bytes)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} does not have a parent directory", path.display()))?;
    fs::create_dir_all(parent)?;
    let temp_path = parent.join(format!(
        ".{}.tmp",
        path.file_name().and_then(|name| name.to_str()).unwrap_or("write")
    ));
    {
        let mut file = fs::File::create(&temp_path)
            .with_context(|| format!("Failed to create {}", temp_path.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("Failed to write {}", temp_path.display()))?;
        file.sync_all()
            .with_context(|| format!("Failed to sync {}", temp_path.display()))?;
    }
    fs::rename(&temp_path, path)
        .with_context(|| format!("Failed to move {} into place", temp_path.display()))?;
    Ok(())
}

fn parse_id_token_claims(id_token: &str) -> Option<IdTokenClaims> {
    let payload = id_token.split('.').nth(1)?;
    let decoded = URL_SAFE_NO_PAD.decode(payload.as_bytes()).ok()?;
    serde_json::from_slice(&decoded).ok()
}

fn default_workspace_name(auth: &OpenAiAuthClaims) -> Option<String> {
    auth.organizations
        .iter()
        .find(|organization| organization.is_default)
        .or_else(|| auth.organizations.first())
        .and_then(|organization| organization.title.as_ref())
        .map(|title| title.trim())
        .filter(|title| !title.is_empty())
        .map(ToOwned::to_owned)
}

fn default_schema_version() -> u32 {
    3
}

fn backoff_seconds(failure_count: u32) -> i64 {
    let exponent = failure_count.saturating_sub(1).min(6);
    let seconds = 30_i64 * (1_i64 << exponent);
    seconds.min(MAX_BACKOFF_SECONDS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_now() -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339("2026-04-08T12:00:00+08:00").unwrap()
    }

    fn test_paths(root: &TempDir) -> AccountsPaths {
        let codex_home = root.path().join(".codex");
        AccountsPaths {
            registry_path: codex_home.join("accounts").join("registry.json"),
            accounts_dir: codex_home.join("accounts"),
            auth_path: codex_home.join("auth.json"),
            cache_path: root.path().join(".cache").join("codexbar").join("accounts-snapshot-v1.json"),
            codex_home,
        }
    }

    fn write_json(path: &Path, value: serde_json::Value) -> Result<()> {
        let parent = path.parent().unwrap();
        fs::create_dir_all(parent)?;
        fs::write(path, serde_json::to_vec_pretty(&value)?)?;
        Ok(())
    }

    fn create_fixture(root: &TempDir) -> Result<()> {
        let paths = test_paths(root);
        write_json(
            &paths.registry_path,
            serde_json::json!({
                "active_account_key": "user-a::acct-1",
                "auto_switch": { "enabled": true, "threshold_5h_percent": 10, "threshold_weekly_percent": 5 },
                "accounts": [
                    {
                        "account_key": "user-a::acct-1",
                        "chatgpt_account_id": "acct-1",
                        "chatgpt_user_id": "user-a",
                        "email": "a@example.com",
                        "alias": "Alpha",
                        "workspace_name": "Acme Workspace",
                        "plan": "team",
                        "auth_mode": "chatgpt",
                        "last_usage": {
                            "primary": { "used_percent": 20, "window_minutes": 300, "resets_at": 1775649600 },
                            "secondary": { "used_percent": 40, "window_minutes": 10080, "resets_at": 1776211200 },
                            "plan_type": "team"
                        },
                        "last_usage_at": 1775611200
                    },
                    {
                        "account_key": "user-b::acct-2",
                        "chatgpt_account_id": "acct-2",
                        "chatgpt_user_id": "user-b",
                        "email": "b@example.com",
                        "alias": "",
                        "plan": "plus",
                        "auth_mode": "chatgpt",
                        "last_usage": null,
                        "last_usage_at": null
                    }
                ]
            }),
        )?;

        write_json(
            &paths.accounts_dir.join("acct-1.auth.json"),
            serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": "access-1",
                    "refresh_token": "refresh-1",
                    "account_id": "acct-1"
                }
            }),
        )?;
        write_json(
            &paths.accounts_dir.join("acct-2.auth.json"),
            serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": "access-2",
                    "refresh_token": "refresh-2",
                    "account_id": "acct-2"
                }
            }),
        )?;
        write_json(
            &paths.auth_path,
            serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": "current",
                    "refresh_token": "refresh-current",
                    "account_id": "acct-1"
                }
            }),
        )?;
        Ok(())
    }

    #[test]
    fn activate_account_replaces_auth_and_registry() -> Result<()> {
        let root = TempDir::new()?;
        create_fixture(&root)?;
        let paths = test_paths(&root);
        activate_account(&paths, "user-b::acct-2", test_now())?;

        let registry = read_registry(&paths.registry_path)?;
        assert_eq!(registry.active_account_key.as_deref(), Some("user-b::acct-2"));

        let auth: AuthFile = serde_json::from_str(&fs::read_to_string(&paths.auth_path)?)?;
        assert_eq!(auth.tokens.account_id.as_deref(), Some("acct-2"));
        Ok(())
    }

    #[test]
    fn sync_current_auth_updates_existing_registry_entry() -> Result<()> {
        let root = TempDir::new()?;
        create_fixture(&root)?;
        let paths = test_paths(&root);

        write_json(
            &paths.auth_path,
            serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": "current",
                    "refresh_token": "refresh-current",
                    "account_id": "acct-2",
                    "id_token": "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6ImJldGFAZXhhbXBsZS5jb20iLCJuYW1lIjoiQmV0YSIsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0LTIiLCJjaGF0Z3B0X3BsYW5fdHlwZSI6InBybyIsImNoYXRncHRfdXNlcl9pZCI6InVzZXItYiJ9fQ."
                }
            }),
        )?;

        let mut registry = read_registry(&paths.registry_path)?;
        registry.accounts[1].email = String::new();
        registry.accounts[1].alias = String::new();
        registry.accounts[1].workspace_name = None;
        registry.accounts[1].plan = String::new();
        write_registry(&paths.registry_path, &registry)?;

        let mut registry = read_registry(&paths.registry_path)?;
        sync_current_auth_into_registry(&paths, &mut registry)?;

        let updated = read_registry(&paths.registry_path)?;
        assert_eq!(updated.active_account_key.as_deref(), Some("user-b::acct-2"));
        assert_eq!(updated.accounts[1].email, "beta@example.com");
        assert_eq!(updated.accounts[1].alias, "Beta");
        assert_eq!(updated.accounts[1].workspace_name, None);
        assert_eq!(updated.accounts[1].plan, "pro");
        Ok(())
    }

    #[test]
    fn remove_account_deletes_non_active_account_and_cache() -> Result<()> {
        let root = TempDir::new()?;
        create_fixture(&root)?;
        let paths = test_paths(&root);

        write_accounts_cache(
            &paths.cache_path,
            &AccountsCacheEnvelope {
                accounts: HashMap::from([(
                    "user-b::acct-2".to_string(),
                    CachedAccountEntry {
                        snapshot: AccountUsageSnapshot {
                            account_key: "user-b::acct-2".to_string(),
                            account_id: Some("acct-2".to_string()),
                            user_id: Some("user-b".to_string()),
                            email: "b@example.com".to_string(),
                            alias: String::new(),
                            workspace_name: None,
                            plan: "plus".to_string(),
                            auth_mode: "chatgpt".to_string(),
                            is_active: false,
                            is_reachable: true,
                            status: AccountSnapshotStatus::Stale,
                            usage_source: UsageSource::Cache,
                            generated_at: test_now().to_rfc3339(),
                            last_usage_at: Some(test_now().to_rfc3339()),
                            session: None,
                            weekly: None,
                            error: None,
                        },
                        failure_count: 0,
                        next_retry_at: None,
                        last_live_success_at: None,
                    },
                )]),
                auto_switch_last_applied_at: None,
            },
        )?;

        let auth_path = paths.accounts_dir.join("acct-2.auth.json");
        assert!(auth_path.exists());

        let result = remove_account(&paths, "user-b::acct-2")?;
        assert!(result.ok);

        let registry = read_registry(&paths.registry_path)?;
        assert_eq!(registry.accounts.len(), 1);
        assert_eq!(registry.accounts[0].account_key, "user-a::acct-1");
        assert!(!auth_path.exists());

        let cache = read_accounts_cache(&paths.cache_path)?;
        assert!(!cache.accounts.contains_key("user-b::acct-2"));
        Ok(())
    }

    #[test]
    fn remove_account_rejects_active_account() -> Result<()> {
        let root = TempDir::new()?;
        create_fixture(&root)?;
        let paths = test_paths(&root);

        let error = remove_account(&paths, "user-a::acct-1").unwrap_err();
        assert!(error.to_string().contains("Cannot remove the active account"));
        Ok(())
    }

    #[test]
    fn fallback_snapshot_uses_registry_usage() -> Result<()> {
        let root = TempDir::new()?;
        create_fixture(&root)?;
        let registry = read_registry(&test_paths(&root).registry_path)?;
        let context = AccountContext {
            registry: registry.accounts[0].clone(),
            auth_file_path: None,
            auth_file: None,
            cached: None,
            is_active: true,
        };
        let snapshot = build_fallback_snapshot(
            &context,
            None,
            &AccountsSnapshotOptions {
                now: test_now(),
                paths: test_paths(&root),
                ..AccountsSnapshotOptions::default()
            },
            Some("network error".to_string()),
        );
        assert_eq!(snapshot.status, AccountSnapshotStatus::Stale);
        assert_eq!(snapshot.usage_source, UsageSource::Cache);
        assert_eq!(snapshot.session.as_ref().map(|window| window.used_percent), Some(20));
        assert_eq!(snapshot.workspace_name.as_deref(), Some("Acme Workspace"));
        Ok(())
    }

    #[test]
    fn backoff_is_capped() {
        assert_eq!(backoff_seconds(1), 30);
        assert_eq!(backoff_seconds(2), 60);
        assert_eq!(backoff_seconds(6), 960.min(MAX_BACKOFF_SECONDS));
        assert_eq!(backoff_seconds(10), MAX_BACKOFF_SECONDS);
    }
}
