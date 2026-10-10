//! Read-only captured skill sources. Embedded bytes are compile-time ingress;
//! workspace reads use the captured capability AND its immutable policy.
use codex_exec_server::{
    CopyOptions, CreateDirectoryOptions, ExecutorFileSystem, ExecutorFileSystemFuture,
    FileMetadata, FileSystemReadStream, FileSystemSandboxContext, GetMetadataOptions,
    ReadDirectoryEntry, ReadFileOptions, RemoveOptions, WalkEntry, WalkEntryKind, WalkOptions,
    WalkOutcome, WriteFileOptions,
};
use codex_utils_absolute_path::AbsolutePathBuf;
use codex_utils_path_uri::PathUri;
use std::{collections::BTreeMap, io, path::PathBuf, sync::Arc};

pub const DENIAL: &str = "skill read denied by turn workspace capability; use a permitted workspace skill or the trusted application workflow";
pub type Check = Arc<dyn Fn() -> io::Result<()> + Send + Sync>;
pub fn denied() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, DENIAL)
}

pub struct SkillFileSystem {
    check: Check,
    source: Source,
}
enum Source {
    Workspace {
        filesystem: Arc<dyn ExecutorFileSystem>,
        sandbox: FileSystemSandboxContext,
    },
    Embedded {
        entries: BTreeMap<PathBuf, Option<&'static [u8]>>,
    },
}
impl SkillFileSystem {
    pub fn workspace(
        filesystem: Arc<dyn ExecutorFileSystem>,
        sandbox: FileSystemSandboxContext,
        check: Check,
    ) -> Arc<dyn ExecutorFileSystem> {
        Arc::new(Self {
            check,
            source: Source::Workspace {
                filesystem,
                sandbox,
            },
        })
    }
    pub fn embedded(root: &AbsolutePathBuf, check: Check) -> Arc<dyn ExecutorFileSystem> {
        // Authority is established by the compile-time asset table and trusted
        // service root, never a model-selected scope/path or disk cache contents.
        let mut entries = BTreeMap::new();
        entries.insert(root.to_path_buf(), None);
        for (relative, bytes) in codex_skills::hyotan_embedded_skill_files() {
            let path = root.as_path().join(relative);
            let mut parent = path.parent();
            while let Some(directory) = parent {
                if !directory.starts_with(root.as_path()) {
                    break;
                }
                entries.insert(directory.to_path_buf(), None);
                if directory == root.as_path() {
                    break;
                }
                parent = directory.parent();
            }
            entries.insert(path, Some(bytes));
        }
        Arc::new(Self {
            check,
            source: Source::Embedded { entries },
        })
    }
    fn check(&self) -> io::Result<()> {
        (self.check)().map_err(|_| denied())
    }
    fn check_context(&self, additional: Option<&FileSystemSandboxContext>) -> io::Result<()> {
        // This read-only source retains its captured policy. Alternate per-call
        // policies are unsupported and cannot remove or widen that constraint.
        match (&self.source, additional) {
            (_, None) => Ok(()),
            (Source::Workspace { sandbox, .. }, Some(additional)) if sandbox == additional => {
                Ok(())
            }
            _ => Err(denied()),
        }
    }
    fn key(path: &PathUri) -> io::Result<PathBuf> {
        let key = path.to_abs_path().map_err(|_| denied())?.to_path_buf();
        if key
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        {
            return Err(denied());
        }
        Ok(key)
    }
    fn missing() -> io::Error {
        io::Error::new(io::ErrorKind::NotFound, "skill resource unavailable")
    }
}
impl ExecutorFileSystem for SkillFileSystem {
    fn canonicalize<'a>(
        &'a self,
        path: &'a PathUri,
        additional: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, PathUri> {
        Box::pin(async move {
            self.check()?;
            self.check_context(additional)?;
            let result = match &self.source {
                Source::Workspace {
                    filesystem,
                    sandbox,
                } => filesystem.canonicalize(path, Some(sandbox)).await,
                Source::Embedded { entries } => {
                    if entries.contains_key(&Self::key(path)?) {
                        Ok(path.clone())
                    } else {
                        Err(Self::missing())
                    }
                }
            };
            self.check()?;
            result.map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Self::missing()
                } else {
                    denied()
                }
            })
        })
    }
    fn read_file<'a>(
        &'a self,
        path: &'a PathUri,
        options: ReadFileOptions,
        additional: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            self.check()?;
            self.check_context(additional)?;
            let result = match &self.source {
                Source::Workspace {
                    filesystem,
                    sandbox,
                } => filesystem.read_file(path, options, Some(sandbox)).await,
                Source::Embedded { entries } => entries
                    .get(&Self::key(path)?)
                    .and_then(|bytes| *bytes)
                    .map(|bytes| bytes.to_vec())
                    .ok_or_else(Self::missing),
            };
            self.check()?;
            result.map_err(|_| denied())
        })
    }
    fn read_file_stream<'a>(
        &'a self,
        _: &'a PathUri,
        _: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileSystemReadStream> {
        Box::pin(async { Err(denied()) })
    }
    fn get_metadata<'a>(
        &'a self,
        path: &'a PathUri,
        options: GetMetadataOptions,
        additional: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileMetadata> {
        Box::pin(async move {
            self.check()?;
            self.check_context(additional)?;
            let result = match &self.source {
                Source::Workspace {
                    filesystem,
                    sandbox,
                } => filesystem.get_metadata(path, options, Some(sandbox)).await,
                Source::Embedded { entries } => entries
                    .get(&Self::key(path)?)
                    .map(|bytes| FileMetadata {
                        is_directory: bytes.is_none(),
                        is_file: bytes.is_some(),
                        is_symlink: false,
                        size: bytes.map_or(0, |bytes| bytes.len() as u64),
                        created_at_ms: 0,
                        modified_at_ms: 0,
                    })
                    .ok_or_else(Self::missing),
            };
            self.check()?;
            result.map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Self::missing()
                } else {
                    denied()
                }
            })
        })
    }
    fn read_directory<'a>(
        &'a self,
        path: &'a PathUri,
        additional: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<ReadDirectoryEntry>> {
        Box::pin(async move {
            self.check()?;
            self.check_context(additional)?;
            let result = match &self.source {
                Source::Workspace {
                    filesystem,
                    sandbox,
                } => filesystem.read_directory(path, Some(sandbox)).await,
                Source::Embedded { entries } => {
                    let key = Self::key(path)?;
                    if !matches!(entries.get(&key), Some(None)) {
                        return Err(Self::missing());
                    }
                    Ok(entries
                        .iter()
                        .filter(|(entry, _)| entry.parent() == Some(key.as_path()))
                        .map(|(entry, bytes)| ReadDirectoryEntry {
                            file_name: entry.file_name().unwrap().to_string_lossy().into_owned(),
                            is_directory: bytes.is_none(),
                            is_file: bytes.is_some(),
                        })
                        .collect())
                }
            };
            self.check()?;
            result.map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Self::missing()
                } else {
                    denied()
                }
            })
        })
    }
    fn walk<'a>(
        &'a self,
        path: &'a PathUri,
        options: WalkOptions,
        additional: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, WalkOutcome> {
        Box::pin(async move {
            self.check()?;
            self.check_context(additional)?;
            let result = match &self.source {
                Source::Workspace {
                    filesystem,
                    sandbox,
                } => {
                    let mut options = options;
                    options.follow_directory_symlinks = false;
                    filesystem.walk(path, options, Some(sandbox)).await
                }
                Source::Embedded { entries } => {
                    let key = Self::key(path)?;
                    if !matches!(entries.get(&key), Some(None)) {
                        return Err(Self::missing());
                    }
                    let mut outcome = WalkOutcome::default();
                    let mut directories = 0;
                    for (entry, bytes) in entries {
                        let Ok(relative) = entry.strip_prefix(&key) else {
                            continue;
                        };
                        if relative.as_os_str().is_empty() {
                            continue;
                        }
                        if relative.components().count() > options.max_depth {
                            outcome.truncated = true;
                            continue;
                        }
                        if options.prune_hidden_directories
                            && relative.parent().is_some_and(|parent| {
                                parent
                                    .components()
                                    .any(|part| part.as_os_str().to_string_lossy().starts_with('.'))
                            })
                        {
                            continue;
                        }
                        if bytes.is_none() {
                            directories += 1;
                        }
                        if outcome.entries.len() >= options.max_entries
                            || directories > options.max_directories
                        {
                            outcome.truncated = true;
                            break;
                        }
                        let absolute = AbsolutePathBuf::from_absolute_path(entry.clone())
                            .map_err(|_| denied())?;
                        outcome.entries.push(WalkEntry {
                            path: PathUri::from_abs_path(&absolute),
                            kind: if bytes.is_none() {
                                WalkEntryKind::Directory
                            } else {
                                WalkEntryKind::File
                            },
                        });
                    }
                    Ok(outcome)
                }
            };
            self.check()?;
            result.map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Self::missing()
                } else {
                    denied()
                }
            })
        })
    }
    fn write_file<'a>(
        &'a self,
        _: &'a PathUri,
        _: Vec<u8>,
        _: WriteFileOptions,
        _: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async { Err(denied()) })
    }
    fn create_directory<'a>(
        &'a self,
        _: &'a PathUri,
        _: CreateDirectoryOptions,
        _: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async { Err(denied()) })
    }
    fn remove<'a>(
        &'a self,
        _: &'a PathUri,
        _: RemoveOptions,
        _: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async { Err(denied()) })
    }
    fn copy<'a>(
        &'a self,
        _: &'a PathUri,
        _: &'a PathUri,
        _: CopyOptions,
        _: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async { Err(denied()) })
    }
}
