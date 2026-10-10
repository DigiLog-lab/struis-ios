//! Capability-bound implementation of the pinned real Codex filesystem trait.
//! This adapter is not installed into AppServer by this crate.
use bytes::Bytes;
use codex_file_system::*;
use codex_protocol::models::PermissionProfile;
use codex_protocol::permissions::{FileSystemPath, FileSystemSandboxKind, ReadDenyMatcher};
use codex_utils_path_uri::PathUri;
use futures::stream;
use hyotan_operation_harness::{Capability, FileHandle, Harness, Metadata, Scope};
use std::{
    collections::VecDeque,
    io,
    path::{Path, PathBuf},
    sync::Arc,
};

pub struct CapabilityFileSystem {
    harness: Arc<Harness>,
    capability: Capability,
    scope: Scope,
    root: PathBuf,
    captured_sandbox: Option<FileSystemSandboxContext>,
}
/// A stream owns one issued object, not a path to reopen between chunks.
/// Cancellation removes the handle in Core; early drop/EOF/error close it here.
struct StreamFile {
    harness: Arc<Harness>,
    capability: Capability,
    scope: Scope,
    handle: FileHandle,
}
impl Drop for StreamFile {
    fn drop(&mut self) {
        // Revoke has already closed issued handles when the grant is gone.
        let _ = self
            .harness
            .close_handle(self.capability, &self.scope, self.handle);
    }
}
fn deny(op: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!(
            "{op} denied by workspace capability; use a permitted workspace file or request the trusted application workflow"
        ),
    )
}
fn failure(op: &str, e: io::Error) -> io::Error {
    match e.kind() {
        io::ErrorKind::NotFound | io::ErrorKind::AlreadyExists => {
            io::Error::new(e.kind(), format!("{op} failed for the workspace entry"))
        }
        _ => deny(op),
    }
}
impl CapabilityFileSystem {
    /// Only the trusted host binds the grant, owner, generation and display root.
    /// The root is a lexical URI namespace, not an authority to open native paths.
    pub fn new(
        harness: Arc<Harness>,
        capability: Capability,
        scope: Scope,
        root: PathBuf,
    ) -> io::Result<Self> {
        if !root.is_absolute()
            || root.components().any(|c| {
                !matches!(
                    c,
                    std::path::Component::RootDir | std::path::Component::Normal(_)
                )
            })
        {
            return Err(deny("bind"));
        }
        harness
            .metadata_root(capability, &scope)
            .map_err(|e| failure("bind", e))?;
        Ok(Self {
            harness,
            capability,
            scope,
            root,
            captured_sandbox: None,
        })
    }
    /// A protected turn binds its actual resolved sandbox at issuance. Optional
    /// per-call permissions only narrow this policy; None never removes it.
    pub fn new_protected(
        harness: Arc<Harness>, capability: Capability, scope: Scope,
        root: PathBuf, sandbox: FileSystemSandboxContext,
    ) -> io::Result<Self> {
        PermissionProfile::try_from(sandbox.permissions.clone()).map_err(|_| deny("bind"))?;
        sandbox.policy_context().ok_or_else(|| deny("bind"))?;
        let mut filesystem = Self::new(harness, capability, scope, root)?;
        filesystem.captured_sandbox = Some(sandbox);
        Ok(filesystem)
    }
    fn relative(
        &self,
        uri: &PathUri,
        sandbox: Option<&FileSystemSandboxContext>,
        write: bool,
        op: &str,
    ) -> io::Result<PathBuf> {
        let native = uri.to_abs_path().map_err(|_| deny(op))?;
        let rel = native
            .as_path()
            .strip_prefix(&self.root)
            .map_err(|_| deny(op))?;
        if rel
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            return Err(deny(op));
        }
        for s in self.captured_sandbox.iter().chain(sandbox) {
            let permissions =
                PermissionProfile::try_from(s.permissions.clone()).map_err(|_| deny(op))?;
            let policy = permissions.file_system_sandbox_policy();
            if matches!(policy.kind, FileSystemSandboxKind::Restricted) {
                // URI-only exact entries avoid native glob expansion, filesystem probes,
                // and unresolved special path semantics in this first adapter.
                if policy
                    .entries
                    .iter()
                    .any(|e| !matches!(e.path, FileSystemPath::Path { .. }))
                {
                    return Err(deny(op));
                }
                let context = s.policy_context().ok_or_else(|| deny(op))?;
                let access = policy.resolve_access(uri, &context);
                if (write && !access.can_write()) || (!write && !access.can_read()) {
                    return Err(deny(op));
                }
                if ReadDenyMatcher::from_context(&policy, &context)
                    .is_some_and(|m| m.is_read_denied_uri(uri, &context))
                {
                    return Err(deny(op));
                }
                // Preserve Codex protected workspace metadata write rules.
                if write
                    && codex_protocol::permissions::forbidden_agent_metadata_write(
                        native.as_path(),
                        context.cwd.to_abs_path().map_err(|_| deny(op))?.as_path(),
                        &policy,
                    )
                    .is_some()
                {
                    return Err(deny(op));
                }
            }
        }
        Ok(rel.to_owned())
    }
    fn meta(&self, rel: &Path, op: &str) -> io::Result<Metadata> {
        if rel.as_os_str().is_empty() {
            self.harness.metadata_root(self.capability, &self.scope)
        } else {
            self.harness.metadata(self.capability, &self.scope, rel)
        }
        .map_err(|e| failure(op, e))
    }
    fn uri(&self, rel: &Path, op: &str) -> io::Result<PathUri> {
        PathUri::from_host_native_path(self.root.join(rel)).map_err(|_| deny(op))
    }
    fn names(&self, rel: &Path, op: &str) -> io::Result<Vec<std::ffi::OsString>> {
        self.harness
            .list(
                self.capability,
                &self.scope,
                if rel.as_os_str().is_empty() {
                    None
                } else {
                    Some(rel)
                },
            )
            .map_err(|_| deny(op))
    }
}
impl ExecutorFileSystem for CapabilityFileSystem {
    fn canonicalize<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, PathUri> {
        Box::pin(async move {
            let rel = self.relative(path, sandbox, false, "canonicalize")?;
            self.meta(&rel, "canonicalize")?;
            // No symlinks accepted. URI stays in the trusted lexical namespace even
            // if an ancestor is renamed; all future accesses use the anchored grant.
            self.uri(&rel, "canonicalize")
        })
    }
    fn read_file<'a>(
        &'a self,
        path: &'a PathUri,
        options: ReadFileOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let _ = options; // Follow requests accept ordinary files; links always deny.
            let rel = self.relative(path, sandbox, false, "read")?;
            self.harness
                .read(self.capability, &self.scope, &rel)
                .map_err(|e| failure("read", e))
        })
    }
    fn read_file_stream<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileSystemReadStream> {
        Box::pin(async move {
            let rel = self.relative(path, sandbox, false, "read stream")?;
            let handle = self
                .harness
                .open_read_stream_handle(self.capability, &self.scope, &rel)
                .map_err(|e| failure("read stream", e))?;
            let file = StreamFile {
                harness: self.harness.clone(),
                capability: self.capability,
                scope: self.scope.clone(),
                handle,
            };
            Ok(FileSystemReadStream::new(stream::unfold(
                (Some(file), 0u64),
                |(file, offset)| async move {
                    let file = file?;
                    match file.harness.read_at(
                        file.capability,
                        &file.scope,
                        file.handle,
                        offset,
                        FILE_READ_CHUNK_SIZE,
                    ) {
                        Ok(bytes) if bytes.is_empty() => None,
                        Ok(bytes) => {
                            let next = offset + bytes.len() as u64;
                            Some((Ok(Bytes::from(bytes)), (Some(file), next)))
                        }
                        Err(e) => {
                            // Close before publishing the terminal failure.
                            drop(file);
                            Some((Err(failure("read stream", e)), (None, offset)))
                        }
                    }
                },
            )))
        })
    }
    fn write_file<'a>(
        &'a self,
        path: &'a PathUri,
        contents: Vec<u8>,
        options: WriteFileOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async move {
            let _ = options;
            let rel = self.relative(path, sandbox, true, "write")?;
            self.harness
                .write(self.capability, &self.scope, &rel, &contents)
                .map_err(|e| failure("write", e))
        })
    }
    fn create_directory<'a>(
        &'a self,
        path: &'a PathUri,
        options: CreateDirectoryOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async move {
            if options.recursive {
                return Err(deny("recursive create directory unsupported"));
            }
            let rel = self.relative(path, sandbox, true, "create directory")?;
            self.harness
                .mkdir(self.capability, &self.scope, &rel)
                .map_err(|e| failure("create directory", e))
        })
    }
    fn get_metadata<'a>(
        &'a self,
        path: &'a PathUri,
        options: GetMetadataOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileMetadata> {
        Box::pin(async move {
            let _ = options;
            let rel = self.relative(path, sandbox, false, "metadata")?;
            let m = self.meta(&rel, "metadata")?;
            Ok(FileMetadata {
                is_directory: m.directory,
                is_file: !m.directory,
                is_symlink: false,
                size: m.bytes,
                created_at_ms: m
                    .created_at_ms
                    .unwrap_or(0)
                    .try_into()
                    .map_err(|_| deny("metadata timestamp"))?,
                modified_at_ms: m
                    .modified_at_ms
                    .unwrap_or(0)
                    .try_into()
                    .map_err(|_| deny("metadata timestamp"))?,
            })
        })
    }
    fn read_directory<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<ReadDirectoryEntry>> {
        Box::pin(async move {
            let rel = self.relative(path, sandbox, false, "list")?;
            let mut result = Vec::new();
            for name in self.names(&rel, "list")? {
                let child = rel.join(&name);
                let uri = self.uri(&child, "list")?;
                self.relative(&uri, sandbox, false, "list")?;
                let m = self.meta(&child, "list")?;
                result.push(ReadDirectoryEntry {
                    file_name: name
                        .into_string()
                        .map_err(|_| deny("non UTF8 list unsupported"))?,
                    is_directory: m.directory,
                    is_file: !m.directory,
                });
            }
            Ok(result)
        })
    }
    fn walk<'a>(
        &'a self,
        path: &'a PathUri,
        options: WalkOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, WalkOutcome> {
        Box::pin(async move {
            if options.follow_directory_symlinks
                || options.max_depth > MAX_WALK_DEPTH
                || options.max_directories == 0
                || options.max_directories > MAX_WALK_DIRECTORIES
                || options.max_entries == 0
                || options.max_entries > MAX_WALK_ENTRIES
            {
                return Err(deny("walk options unsupported"));
            }
            let rel = self.relative(path, sandbox, false, "walk")?;
            if !self.meta(&rel, "walk")?.directory {
                return Err(deny("walk"));
            }
            let mut out = WalkOutcome::default();
            let mut queue = VecDeque::from([(rel, 0usize)]);
            let (mut directories, mut examined, mut budget) = (1usize, 0usize, 0usize);
            while let Some((dir, depth)) = queue.pop_front() {
                if depth >= options.max_depth {
                    continue;
                }
                for name in self.names(&dir, "walk")? {
                    if examined >= options.max_entries {
                        out.truncated = true;
                        return Ok(out);
                    }
                    examined += 1;
                    let child = dir.join(&name);
                    let uri = self.uri(&child, "walk")?;
                    self.harness
                        .metadata_root(self.capability, &self.scope)
                        .map_err(|e| failure("walk", e))?;
                    let m = self
                        .relative(&uri, sandbox, false, "walk")
                        .and_then(|p| self.meta(&p, "walk"));
                    let cost = uri.to_string().len()
                        + WALK_RESPONSE_ITEM_OVERHEAD_BYTES
                        + if m.is_err() {
                            deny("walk").to_string().len()
                        } else {
                            0
                        };
                    if budget + cost > MAX_WALK_RESPONSE_BYTES {
                        out.truncated = true;
                        return Ok(out);
                    }
                    budget += cost;
                    match m {
                        Err(_) => out.errors.push(WalkError {
                            path: uri,
                            message: deny("walk").to_string(),
                        }),
                        Ok(m) => {
                            out.entries.push(WalkEntry {
                                path: uri,
                                kind: if m.directory {
                                    WalkEntryKind::Directory
                                } else {
                                    WalkEntryKind::File
                                },
                            });
                            let hidden = name.to_string_lossy().starts_with('.');
                            if m.directory
                                && depth + 1 < options.max_depth
                                && !(hidden && options.prune_hidden_directories)
                            {
                                if directories >= options.max_directories {
                                    out.truncated = true;
                                } else {
                                    directories += 1;
                                    queue.push_back((child, depth + 1));
                                }
                            }
                        }
                    }
                }
            }
            Ok(out)
        })
    }
    fn remove<'a>(
        &'a self,
        path: &'a PathUri,
        options: RemoveOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async move {
            if options.force {
                return Err(deny("force remove unsupported"));
            }
            // A restricted sandbox may contain descendant deny/read-only entries;
            // core recursive removal cannot apply those per descendant. Fail closed.
            if options.recursive && (sandbox.is_some() || self.captured_sandbox.is_some()) {
                return Err(deny("recursive sandbox remove unsupported"));
            }
            let rel = self.relative(path, sandbox, true, "remove")?;
            self.harness
                .remove(self.capability, &self.scope, &rel, options.recursive)
                .map_err(|e| failure("remove", e))
        })
    }
    fn copy<'a>(
        &'a self,
        source: &'a PathUri,
        destination: &'a PathUri,
        options: CopyOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        Box::pin(async move {
            if options.recursive && (sandbox.is_some() || self.captured_sandbox.is_some()) {
                return Err(deny("recursive sandbox copy unsupported"));
            }
            let src = self.relative(source, sandbox, false, "copy source")?;
            let dst = self.relative(destination, sandbox, true, "copy destination")?;
            self.harness
                .copy(self.capability, &self.scope, &src, &dst, options.recursive)
                .map_err(|e| failure("copy", e))
        })
    }
}
