//! Scoped file handles for synchronous virtual-machine file I/O.
use super::*;

/// Logical descriptor extents, separate from per-call allocation and bulk-copy bounds.
/// Only trusted grant issuance supplies these values; no operation can widen them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DescriptorLimits {
    read_extent: u64,
    write_extent: u64,
}
impl DescriptorLimits {
    pub fn new(read_extent: u64, write_extent: u64) -> io::Result<Self> {
        let maximum = libc::off_t::MAX as u64;
        if read_extent == 0 || write_extent == 0 || read_extent > maximum || write_extent > maximum
        {
            return Err(denied());
        }
        Ok(Self {
            read_extent,
            write_extent,
        })
    }
    pub fn read_extent(self) -> u64 {
        self.read_extent
    }
    pub fn write_extent(self) -> u64 {
        self.write_extent
    }
}
impl Default for DescriptorLimits {
    fn default() -> Self {
        Self {
            read_extent: libc::off_t::MAX as u64,
            write_extent: MAX_FILE_BYTES as u64,
        }
    }
}
pub const MAX_HANDLE_CHUNK: usize = 1024 * 1024;
pub const MAX_HANDLES_PER_GRANT: usize = 64;
pub const MAX_TOTAL_HANDLES: usize = 256;
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct FileHandle(u64);
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileAccess {
    ReadOnly,
    WriteOnly,
    ReadWrite,
}
impl FileAccess {
    fn readable(self) -> bool {
        matches!(self, Self::ReadOnly | Self::ReadWrite)
    }
    fn writable(self) -> bool {
        matches!(self, Self::WriteOnly | Self::ReadWrite)
    }
}
#[derive(Clone, Copy, Debug)]
pub struct OpenOptions {
    pub access: FileAccess,
    pub create: bool,
    pub exclusive: bool,
    pub truncate: bool,
    pub append: bool,
}
impl OpenOptions {
    pub fn read_only() -> Self {
        Self {
            access: FileAccess::ReadOnly,
            create: false,
            exclusive: false,
            truncate: false,
            append: false,
        }
    }
    fn flags(self) -> io::Result<i32> {
        if (self.truncate || self.append) && !self.access.writable()
            || self.exclusive && !self.create
        {
            return Err(denied());
        }
        let mut flags = match self.access {
            FileAccess::ReadOnly => libc::O_RDONLY,
            FileAccess::WriteOnly => libc::O_WRONLY,
            FileAccess::ReadWrite => libc::O_RDWR,
        };
        if self.create {
            flags |= libc::O_CREAT;
        }
        if self.exclusive {
            flags |= libc::O_EXCL;
        }
        // O_TRUNC is deliberately deferred until after descriptor validation.
        if self.append {
            flags |= libc::O_APPEND;
        }
        Ok(flags | libc::O_NONBLOCK)
    }
}
pub(super) struct OpenFile {
    pub(super) capability: Capability,
    file: File,
    access: FileAccess,
    append: bool,
    extent: u64,
    read_extent: u64,
    write_extent: u64,
}
fn bounded_file(file: &File, issued: bool, extent: u64) -> io::Result<libc::stat> {
    let stat = info(file)?;
    // Newly opened paths require nlink==1. Already-issued descriptors retain
    // their original regular object after unlink/replacement, never a new path.
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || if issued {
            stat.st_nlink > 1
        } else {
            stat.st_nlink != 1
        }
    {
        return Err(denied());
    }
    if stat.st_size < 0 || stat.st_size as u64 > extent {
        return Err(denied());
    }
    Ok(stat)
}
fn range(offset: u64, chunk: usize, extent: u64, write: bool) -> io::Result<libc::off_t> {
    if chunk > MAX_HANDLE_CHUNK
        || offset > extent
        || write
            && offset
                .checked_add(chunk as u64)
                .is_none_or(|end| end > extent)
    {
        return Err(denied());
    }
    offset.try_into().map_err(|_| denied())
}
impl Harness {
    /// Issues a handle only from a live workspace capability. Never exposes its
    /// raw descriptor; file access mode and grant scope are checked on every use.
    pub fn open_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        options: OpenOptions,
    ) -> io::Result<FileHandle> {
        self.open_handle_internal(cap, scope, path, options, true)
    }
    /// Retained read-only stream matching the legacy read_range logical reach.
    pub fn open_read_stream_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
    ) -> io::Result<FileHandle> {
        self.open_handle_internal(cap, scope, path, OpenOptions::read_only(), false)
    }
    /// Explicit trusted-policy descriptor route, including bounded random writes.
    /// Uses grant-captured extents, never a per-operation guest supplied limit.
    pub fn open_stream_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        options: OpenOptions,
    ) -> io::Result<FileHandle> {
        self.open_handle_internal(cap, scope, path, options, false)
    }
    fn open_handle_internal(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        options: OpenOptions,
        legacy: bool,
    ) -> io::Result<FileHandle> {
        let p = parts(path)?;
        let flags = options.flags()?;
        let mut state = self.state.lock().map_err(|_| denied())?;
        let grant = state.grants.get(&cap).ok_or_else(denied)?;
        if &grant.scope != scope
            || (options.access.writable() || options.create)
                && matches!(grant.access, Access::ReadOnly)
        {
            return Err(denied());
        }
        if state.handles.len() >= MAX_TOTAL_HANDLES
            || state
                .handles
                .values()
                .filter(|h| h.capability == cap)
                .count()
                >= MAX_HANDLES_PER_GRANT
        {
            return Err(denied());
        }
        let par = parent(&grant.root, &p)?;
        let file = open_at(par.as_raw_fd(), p.last().unwrap(), flags)?;
        let read_extent = if legacy {
            grant
                .descriptor_limits
                .read_extent
                .min(MAX_FILE_BYTES as u64)
        } else {
            grant.descriptor_limits.read_extent
        };
        let write_extent = if legacy {
            grant
                .descriptor_limits
                .write_extent
                .min(MAX_FILE_BYTES as u64)
        } else {
            grant.descriptor_limits.write_extent
        };
        let extent = match options.access {
            FileAccess::ReadOnly => read_extent,
            FileAccess::WriteOnly => write_extent,
            FileAccess::ReadWrite => read_extent.max(write_extent),
        };
        bounded_file(&file, false, extent)?;
        if options.truncate {
            result(file.set_len(0))?;
        }
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |n| n.checked_add(1),
            )
            .map_err(|_| denied())?;
        let handle = FileHandle(id);
        state.handles.insert(
            handle,
            OpenFile {
                capability: cap,
                file,
                access: options.access,
                append: options.append,
                extent,
                read_extent,
                write_extent,
            },
        );
        Ok(handle)
    }
    fn with_handle<T>(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
        read: bool,
        write: bool,
        operation: impl FnOnce(&OpenFile) -> io::Result<T>,
    ) -> io::Result<T> {
        let state = self.state.lock().map_err(|_| denied())?;
        let grant = state.grants.get(&cap).ok_or_else(denied)?;
        let opened = state.handles.get(&handle).ok_or_else(denied)?;
        if &grant.scope != scope
            || opened.capability != cap
            || read && !opened.access.readable()
            || write && (!opened.access.writable() || matches!(grant.access, Access::ReadOnly))
        {
            return Err(denied());
        }
        bounded_file(&opened.file, true, opened.extent)?;
        result(operation(opened))
    }
    pub fn read_at(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
        offset: u64,
        max_bytes: usize,
    ) -> io::Result<Vec<u8>> {
        self.with_handle(cap, scope, handle, true, false, |opened| {
            let signed_offset = range(offset, max_bytes, opened.read_extent, false)?;
            // Allocate only the requested bounded prefix within the logical read
            // extent. EOF at the exact extent is valid and allocates zero bytes.
            let max_bytes =
                max_bytes.min((opened.read_extent - offset).min(usize::MAX as u64) as usize);
            let offset = signed_offset;
            let mut bytes = vec![0; max_bytes];
            let n = loop {
                let n = unsafe {
                    libc::pread(
                        opened.file.as_raw_fd(),
                        bytes.as_mut_ptr().cast(),
                        bytes.len(),
                        offset,
                    )
                };
                if n < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                break n;
            };
            if n < 0 {
                return Err(syscall_error());
            }
            bytes.truncate(n as usize);
            Ok(bytes)
        })
    }
    /// For append handles, ignores offset after validating its budget and uses
    /// write(O_APPEND) so the OS atomically chooses EOF. Otherwise uses pwrite.
    pub fn write_at(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
        offset: u64,
        bytes: &[u8],
    ) -> io::Result<usize> {
        self.with_handle(cap, scope, handle, false, true, |opened| {
            let offset = range(offset, bytes.len(), opened.write_extent, true)?;
            if opened.append
                && (bounded_file(&opened.file, true, opened.extent)?.st_size as u64)
                    .checked_add(bytes.len() as u64)
                    .is_none_or(|end| end > opened.write_extent)
            {
                return Err(denied());
            }
            let n = loop {
                let n = unsafe {
                    if opened.append {
                        libc::write(opened.file.as_raw_fd(), bytes.as_ptr().cast(), bytes.len())
                    } else {
                        libc::pwrite(
                            opened.file.as_raw_fd(),
                            bytes.as_ptr().cast(),
                            bytes.len(),
                            offset,
                        )
                    }
                };
                if n < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                break n;
            };
            if n < 0 {
                Err(syscall_error())
            } else {
                Ok(n as usize)
            }
        })
    }
    pub fn truncate_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
        length: u64,
    ) -> io::Result<()> {
        self.with_handle(cap, scope, handle, false, true, |opened| {
            if length > opened.write_extent || libc::off_t::try_from(length).is_err() {
                return Err(denied());
            }
            opened.file.set_len(length)
        })
    }
    pub fn stat_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
    ) -> io::Result<Metadata> {
        self.with_handle(cap, scope, handle, false, false, |opened| {
            Ok(metadata_from(info(&opened.file)?))
        })
    }
    pub fn close_handle(
        &self,
        cap: Capability,
        scope: &Scope,
        handle: FileHandle,
    ) -> io::Result<()> {
        let mut state = self.state.lock().map_err(|_| denied())?;
        let grant = state.grants.get(&cap).ok_or_else(denied)?;
        let opened = state.handles.get(&handle).ok_or_else(denied)?;
        if &grant.scope != scope || opened.capability != cap {
            return Err(denied());
        }
        state.handles.remove(&handle);
        Ok(())
    }
}
