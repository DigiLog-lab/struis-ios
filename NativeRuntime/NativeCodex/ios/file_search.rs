// Copyright 2026 Hyotan contributors. Licensed under Apache-2.0.
// Public data shapes follow the Apache-2.0 Codex app-server API.
// The matching and session implementation is independent of nucleo.
use std::num::NonZero;
use std::path::{Path, PathBuf};
use std::sync::{Arc, atomic::{AtomicBool, Ordering}, mpsc};
use std::time::Duration;
use serde::Serialize;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MatchType { File, Directory }
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct FileMatch {
    pub score: u32,
    pub path: PathBuf,
    pub match_type: MatchType,
    pub root: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub indices: Option<Vec<u32>>,
}
impl FileMatch { pub fn full_path(&self) -> PathBuf { self.root.join(&self.path) } }
pub fn file_name_from_path(path: &str) -> String {
    Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.into())
}
#[derive(Debug)]
pub struct FileSearchResults { pub matches: Vec<FileMatch>, pub total_match_count: usize }
#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
pub struct FileSearchSnapshot {
    pub query: String, pub matches: Vec<FileMatch>, pub total_match_count: usize,
    pub scanned_file_count: usize, pub walk_complete: bool,
}
#[derive(Debug, Clone)]
pub struct FileSearchOptions {
    pub limit: NonZero<usize>, pub exclude: Vec<String>, pub threads: NonZero<usize>,
    pub compute_indices: bool, pub respect_gitignore: bool,
}
impl Default for FileSearchOptions {
    fn default() -> Self {
        Self { limit: NonZero::new(20).unwrap(), exclude: Vec::new(), threads: NonZero::new(2).unwrap(), compute_indices: false, respect_gitignore: true }
    }
}
/// Receives real filesystem search snapshots and completion events.
pub trait SessionReporter: Send + Sync + 'static {
    fn on_update(&self, snapshot: &FileSearchSnapshot);
    fn on_complete(&self);
}
pub struct FileSearchSession { query: mpsc::Sender<String>, stop: Arc<AtomicBool> }
impl FileSearchSession {
    pub fn update_query(&self, query: &str) { let _ = self.query.send(query.into()); }
}
impl Drop for FileSearchSession { fn drop(&mut self) { self.stop.store(true, Ordering::Relaxed); } }

// Case-insensitive subsequence matching. Positions are Unicode character
// indices (not UTF-8 byte offsets). Consecutive and word-initial matches rank first.
fn matched(path: &str, query: &str) -> Option<(u32, Vec<u32>)> {
    let chars: Vec<char> = path.chars().collect();
    let mut cursor = 0;
    let mut score: u32 = 0;
    let mut indices = Vec::new();
    for wanted in query.chars().filter(|c| !c.is_whitespace()) {
        let folded = wanted.to_lowercase().collect::<String>();
        let offset = chars[cursor..].iter().position(|c| c.to_lowercase().collect::<String>() == folded)?;
        let position = cursor + offset;
        score = score.saturating_add(10 + if offset == 0 { 15 } else { 0 } + if position == 0 || "/_- .".contains(chars[position - 1]) { 20 } else { 0 });
        indices.push(u32::try_from(position).ok()?);
        cursor = position + 1;
    }
    Some((score, indices))
}

pub fn cmp_by_score_desc_then_path_asc<T, FScore, FPath>(score_of: FScore, path_of: FPath) -> impl FnMut(&T, &T) -> std::cmp::Ordering
where FScore: Fn(&T) -> u32, FPath: Fn(&T) -> &str {
    move |a, b| score_of(b).cmp(&score_of(a)).then_with(|| path_of(a).cmp(path_of(b)))
}

fn walk(roots: &[PathBuf], options: &FileSearchOptions, stop: &AtomicBool, cancel: &AtomicBool) -> anyhow::Result<Vec<FileMatch>> {
    let first = roots.first().ok_or_else(|| anyhow::anyhow!("at least one search directory is required"))?;
    let mut builder = ignore::WalkBuilder::new(first);
    for root in &roots[1..] { builder.add(root); }
    builder.hidden(false).follow_links(true).require_git(true);
    if !options.respect_gitignore { builder.git_ignore(false).git_global(false).git_exclude(false).ignore(false).parents(false); }
    let mut excludes = ignore::overrides::OverrideBuilder::new(first);
    for pattern in &options.exclude { excludes.add(&format!("!{pattern}"))?; }
    builder.overrides(excludes.build()?);
    let mut entries = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for result in builder.build() {
        if stop.load(Ordering::Relaxed) || cancel.load(Ordering::Relaxed) { break; }
        let entry = match result { Ok(entry) => entry, Err(_) => continue };
        let path = entry.path();
        let Some(root) = roots.iter().filter(|root| path.starts_with(root)).max_by_key(|root| root.components().count()) else { continue; };
        let relative = path.strip_prefix(root)?;
        if relative.as_os_str().is_empty() || !seen.insert(path.to_path_buf()) { continue; }
        entries.push(FileMatch { score: 0, path: relative.into(), root: root.clone(), match_type: if entry.file_type().is_some_and(|t| t.is_dir()) { MatchType::Directory } else { MatchType::File }, indices: None });
    }
    Ok(entries)
}
fn search(entries: &[FileMatch], query: &str, options: &FileSearchOptions) -> FileSearchSnapshot {
    let mut matches: Vec<_> = entries.iter().filter_map(|entry| {
        let (score, indices) = matched(&entry.path.to_string_lossy(), query)?;
        Some(FileMatch { score, indices: options.compute_indices.then_some(indices), ..entry.clone() })
    }).collect();
    matches.sort_by(|a,b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
    let total_match_count = matches.len();
    matches.truncate(options.limit.get());
    FileSearchSnapshot { query: query.into(), matches, total_match_count, scanned_file_count: entries.len(), walk_complete: true }
}
pub fn run(query: &str, roots: Vec<PathBuf>, options: FileSearchOptions, cancel: Option<Arc<AtomicBool>>) -> anyhow::Result<FileSearchResults> {
    let cancel = cancel.unwrap_or_default();
    let entries = walk(&roots, &options, &AtomicBool::new(false), &cancel)?;
    let snapshot = search(&entries, query, &options);
    Ok(FileSearchResults { matches: snapshot.matches, total_match_count: snapshot.total_match_count })
}
pub fn create_session(roots: Vec<PathBuf>, options: FileSearchOptions, reporter: Arc<dyn SessionReporter>, cancel: Option<Arc<AtomicBool>>) -> anyhow::Result<FileSearchSession> {
    // Validate patterns before handing work to the thread so API callers receive errors.
    let first = roots.first().ok_or_else(|| anyhow::anyhow!("at least one search directory is required"))?;
    let mut excludes = ignore::overrides::OverrideBuilder::new(first);
    for pattern in &options.exclude { excludes.add(&format!("!{pattern}"))?; }
    excludes.build()?;
    let (query, receiver) = mpsc::channel::<String>();
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = stop.clone();
    let cancel = cancel.unwrap_or_default();
    std::thread::Builder::new().name("hyotan.file-search".into()).spawn(move || {
        let entries = match walk(&roots, &options, &worker_stop, &cancel) {
            Ok(entries) => entries,
            Err(_) => { reporter.on_complete(); return; }
        };
        while !worker_stop.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) {
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(mut query) => {
                    while let Ok(newer) = receiver.try_recv() { query = newer; }
                    reporter.on_update(&search(&entries, &query, &options));
                    reporter.on_complete();
                },
                Err(mpsc::RecvTimeoutError::Timeout) => {},
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        reporter.on_complete();
    })?;
    Ok(FileSearchSession { query, stop })
}
