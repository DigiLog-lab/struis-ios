//! Descriptor-relative file operations for a trusted AppServer broker.
//! This library does not sandbox native Python or other callers of libc.
mod handles;
pub use handles::{
    DescriptorLimits, FileAccess, FileHandle, MAX_HANDLE_CHUNK, MAX_HANDLES_PER_GRANT,
    MAX_TOTAL_HANDLES, OpenOptions,
};

use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    os::fd::{AsRawFd, FromRawFd, RawFd},
    path::{Component, Path},
    sync::Mutex,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct Capability(u64);
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Scope {
    pub owner: String,
    pub generation: u64,
}
#[derive(Clone, Copy, Debug)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Metadata {
    pub directory: bool,
    pub bytes: u64,
    pub created_at_ms: Option<u64>,
    pub modified_at_ms: Option<u64>,
}
pub const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_LIST_ENTRIES: usize = 4096;
pub const MAX_RECURSIVE_DEPTH: usize = 32;
pub const MAX_RECURSIVE_ENTRIES: usize = 4096;
pub const MAX_COPY_BYTES: u64 = 64 * 1024 * 1024;
#[derive(Default)]
struct Budget {
    entries: usize,
    bytes: u64,
}
impl Budget {
    fn node(&mut self, depth: usize) -> io::Result<()> {
        if depth > MAX_RECURSIVE_DEPTH || self.entries >= MAX_RECURSIVE_ENTRIES {
            return Err(denied());
        }
        self.entries += 1;
        Ok(())
    }
}
fn metadata_from(s: libc::stat) -> Metadata {
    let ms = |seconds: i64, nanos: i64| -> Option<u64> {
        u64::try_from(seconds)
            .ok()?
            .checked_mul(1000)?
            .checked_add(u64::try_from(nanos).ok()? / 1_000_000)
    };
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let (created, modified) = (None, ms(s.st_mtime, s.st_mtime_nsec));
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let (created, modified) = (
        ms(s.st_birthtime, s.st_birthtime_nsec),
        ms(s.st_mtime, s.st_mtime_nsec),
    );
    Metadata {
        directory: s.st_mode & libc::S_IFMT == libc::S_IFDIR,
        bytes: s.st_size.max(0) as u64,
        created_at_ms: created,
        modified_at_ms: modified,
    }
}
struct Grant {
    root: File,
    scope: Scope,
    access: Access,
    descriptor_limits: DescriptorLimits,
}
#[derive(Default)]
struct State {
    grants: HashMap<Capability, Grant>,
    handles: HashMap<FileHandle, handles::OpenFile>,
}
#[derive(Default)]
pub struct Harness {
    state: Mutex<State>,
}
fn denied() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "operation denied")
}
// Only errors created by the checked rename operation retain its finite errno
// vocabulary. Other system failures still pass through the existing sanitizer.
#[derive(Debug)]
struct RenameError;
impl std::fmt::Display for RenameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("operation failed")
    }
}
impl std::error::Error for RenameError {}
fn rename_error(code: i32) -> io::Error {
    let kind = match code {
        libc::ENOENT => io::ErrorKind::NotFound,
        libc::EISDIR => io::ErrorKind::IsADirectory,
        libc::ENOTDIR => io::ErrorKind::NotADirectory,
        libc::ENOTEMPTY | libc::EEXIST => io::ErrorKind::DirectoryNotEmpty,
        libc::EXDEV => io::ErrorKind::CrossesDevices,
        libc::EINVAL => io::ErrorKind::InvalidInput,
        _ => return denied(),
    };
    io::Error::new(kind, RenameError)
}
fn result<T>(r: io::Result<T>) -> io::Result<T> {
    r.map_err(|e| {
        if e.get_ref().is_some_and(|cause| cause.is::<RenameError>()) {
            return e;
        }
        match e.kind() {
            io::ErrorKind::NotFound | io::ErrorKind::AlreadyExists => {
                io::Error::new(e.kind(), "operation failed")
            }
            _ => denied(),
        }
    })
}
fn syscall_error() -> io::Error {
    match io::Error::last_os_error().raw_os_error() {
        Some(libc::ENOENT) => io::Error::new(io::ErrorKind::NotFound, "operation failed"),
        Some(libc::EEXIST) => io::Error::new(io::ErrorKind::AlreadyExists, "operation failed"),
        _ => denied(),
    }
}
fn name(s: &std::ffi::OsStr) -> io::Result<CString> {
    use std::os::unix::ffi::OsStrExt;
    CString::new(s.as_bytes()).map_err(|_| denied())
}
fn parts(path: &Path) -> io::Result<Vec<CString>> {
    let mut out = Vec::new();
    for c in path.components() {
        match c {
            Component::Normal(s) => out.push(name(s)?),
            Component::CurDir => {}
            _ => return Err(denied()),
        }
    }
    if out.is_empty() {
        return Err(denied());
    }
    Ok(out)
}
fn open_at(fd: RawFd, n: &CStr, flags: i32) -> io::Result<File> {
    let raw = unsafe {
        libc::openat(
            fd,
            n.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            // Darwin's mode_t is u16; C varargs require integer promotion.
            0o600 as libc::c_uint,
        )
    };
    if raw < 0 {
        Err(syscall_error())
    } else {
        Ok(unsafe { File::from_raw_fd(raw) })
    }
}
fn info(f: &File) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe { libc::fstat(f.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(denied());
    }
    Ok(unsafe { stat.assume_init() })
}
fn regular(f: &File) -> io::Result<libc::stat> {
    let s = info(f)?;
    if s.st_mode & libc::S_IFMT != libc::S_IFREG || s.st_nlink != 1 {
        return Err(denied());
    }
    Ok(s)
}
fn parent(root: &File, p: &[CString]) -> io::Result<File> {
    let mut fd = result(root.try_clone())?;
    for n in &p[..p.len() - 1] {
        fd = open_at(fd.as_raw_fd(), n, libc::O_RDONLY | libc::O_DIRECTORY)?;
    }
    Ok(fd)
}
fn target(root: &File, p: &[CString]) -> io::Result<File> {
    let fd = parent(root, p)?;
    open_at(
        fd.as_raw_fd(),
        p.last().unwrap(),
        libc::O_RDONLY | libc::O_NONBLOCK,
    )
}
fn entries(dir: &File) -> io::Result<Vec<CString>> {
    // Open '.' for an independent directory offset: dup alone shares offsets.
    let dot = CString::new(".").unwrap();
    let fd = open_at(dir.as_raw_fd(), &dot, libc::O_RDONLY | libc::O_DIRECTORY)?;
    use std::os::fd::IntoRawFd;
    let raw = fd.into_raw_fd();
    let stream = unsafe { libc::fdopendir(raw) };
    if stream.is_null() {
        unsafe {
            libc::close(raw);
        }
        return Err(denied());
    }
    struct Close(*mut libc::DIR);
    impl Drop for Close {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let _close = Close(stream);
    let mut names = Vec::new();
    loop {
        unsafe {
            *errno_ptr() = 0;
        }
        let e = unsafe { libc::readdir(stream) };
        if e.is_null() {
            if unsafe { *errno_ptr() } != 0 {
                return Err(denied());
            }
            break;
        }
        let n = unsafe { CStr::from_ptr((*e).d_name.as_ptr()) };
        if n.to_bytes() != b"." && n.to_bytes() != b".." {
            if names.len() >= MAX_LIST_ENTRIES {
                return Err(denied());
            }
            names.push(n.to_owned());
        }
    }
    names.sort();
    Ok(names)
}
fn unlink(parent: &File, n: &CStr, directory: bool) -> io::Result<()> {
    if unsafe {
        libc::unlinkat(
            parent.as_raw_fd(),
            n.as_ptr(),
            if directory { libc::AT_REMOVEDIR } else { 0 },
        )
    } != 0
    {
        return Err(syscall_error());
    }
    Ok(())
}
fn remove_node(
    parent: &File,
    n: &CStr,
    recursive: bool,
    depth: usize,
    budget: &mut Budget,
) -> io::Result<()> {
    budget.node(depth)?;
    let fd = open_at(parent.as_raw_fd(), n, libc::O_RDONLY | libc::O_NONBLOCK)?;
    let s = info(&fd)?;
    let directory = s.st_mode & libc::S_IFMT == libc::S_IFDIR;
    if directory {
        if recursive {
            for child in entries(&fd)? {
                remove_node(&fd, &child, true, depth + 1, budget)?;
            }
        }
    } else {
        regular(&fd)?;
    }
    unlink(parent, n, directory)
}
// Inspect the complete moved subtree before changing the namespace. This does
// not synchronize independent privileged actors; trusted workspace mutation
// must share the lifecycle lock (including across independent C instances).
fn validate_rename_node(file: &File, depth: usize, budget: &mut Budget) -> io::Result<libc::stat> {
    budget.node(depth)?;
    let stat = info(file)?;
    if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
        for child in entries(file)? {
            let opened = open_at(file.as_raw_fd(), &child, libc::O_RDONLY | libc::O_NONBLOCK)?;
            validate_rename_node(&opened, depth + 1, budget)?;
        }
    } else {
        regular(file)?;
    }
    Ok(stat)
}
fn rename_at(
    source_parent: &File,
    source: &CStr,
    destination_parent: &File,
    destination: &CStr,
) -> io::Result<()> {
    if unsafe {
        libc::renameat(
            source_parent.as_raw_fd(),
            source.as_ptr(),
            destination_parent.as_raw_fd(),
            destination.as_ptr(),
        )
    } != 0
    {
        return Err(rename_error(
            io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(libc::EIO),
        ));
    }
    Ok(())
}
impl Harness {
    /// Trusted host bootstrap only. Never accept a root supplied by a model.
    /// Root and all ancestors are opened without following symbolic links.
    pub fn grant(&self, root: &Path, scope: Scope, access: Access) -> io::Result<Capability> {
        self.grant_with_descriptor_limits(root, scope, access, DescriptorLimits::default())
    }
    /// Trusted policy is immutable for the lifetime of this grant.
    pub fn grant_with_descriptor_limits(
        &self,
        root: &Path,
        scope: Scope,
        access: Access,
        descriptor_limits: DescriptorLimits,
    ) -> io::Result<Capability> {
        if !root.is_absolute() {
            return Err(denied());
        }
        let slash = CString::new("/").unwrap();
        let mut fd = open_at(libc::AT_FDCWD, &slash, libc::O_RDONLY | libc::O_DIRECTORY)?;
        for c in root.components() {
            match c {
                Component::RootDir => {}
                Component::Normal(n) => {
                    fd = open_at(
                        fd.as_raw_fd(),
                        &name(n)?,
                        libc::O_RDONLY | libc::O_DIRECTORY,
                    )?;
                }
                _ => return Err(denied()),
            }
        }
        self.grant_from_owned_directory_with_descriptor_limits(fd, scope, access, descriptor_limits)
    }
    /// Trusted bootstrap for sandboxes that cannot traverse root ancestors.
    /// The host is responsible for the descriptor's workspace provenance; a
    /// descriptor supplied by a model or untrusted caller is not acceptable.
    pub fn grant_from_owned_directory(
        &self,
        root: File,
        scope: Scope,
        access: Access,
    ) -> io::Result<Capability> {
        self.grant_from_owned_directory_with_descriptor_limits(
            root,
            scope,
            access,
            DescriptorLimits::default(),
        )
    }
    /// Trusted owned-root variant. Limits never originate in guest operation arguments.
    pub fn grant_from_owned_directory_with_descriptor_limits(
        &self,
        root: File,
        scope: Scope,
        access: Access,
        descriptor_limits: DescriptorLimits,
    ) -> io::Result<Capability> {
        if info(&root)?.st_mode & libc::S_IFMT != libc::S_IFDIR {
            return Err(denied());
        }
        let mut state = self.state.lock().map_err(|_| denied())?;
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |n| n.checked_add(1),
            )
            .map_err(|_| denied())?;
        let cap = Capability(id);
        state.grants.insert(
            cap,
            Grant {
                root,
                scope,
                access,
                descriptor_limits,
            },
        );
        Ok(cap)
    }
    pub fn revoke(&self, cap: Capability, scope: &Scope) -> io::Result<()> {
        let mut state = self.state.lock().map_err(|_| denied())?;
        let grant = state.grants.get(&cap).ok_or_else(denied)?;
        if &grant.scope != scope {
            return Err(denied());
        }
        state.grants.remove(&cap);
        state.handles.retain(|_, handle| handle.capability != cap);
        Ok(())
    }
    fn with<T>(
        &self,
        cap: Capability,
        scope: &Scope,
        write: bool,
        operation: impl FnOnce(&File) -> io::Result<T>,
    ) -> io::Result<T> {
        // Hold the grant lock through final syscalls; revoke returns after in-flight
        // operations finish, and future operations cannot acquire the removed grant.
        let state = self.state.lock().map_err(|_| denied())?;
        let g = state.grants.get(&cap).ok_or_else(denied)?;
        if &g.scope != scope || (write && matches!(g.access, Access::ReadOnly)) {
            return Err(denied());
        }
        result(operation(&g.root))
    }
    pub fn read(&self, cap: Capability, scope: &Scope, path: &Path) -> io::Result<Vec<u8>> {
        let p = parts(path)?;
        self.with(cap, scope, false, |root| {
            let mut fd = target(root, &p)?;
            let stat = regular(&fd)?;
            if stat.st_size > MAX_FILE_BYTES as i64 {
                return Err(denied());
            }
            let mut bytes = Vec::new();
            Read::by_ref(&mut fd)
                .take(MAX_FILE_BYTES as u64 + 1)
                .read_to_end(&mut bytes)?;
            if bytes.len() > MAX_FILE_BYTES {
                return Err(denied());
            }
            Ok(bytes)
        })
    }
    /// Each range reacquires its grant. This is suitable for a bounded stream
    /// adapter, provided each yielded chunk invokes this method again.
    pub fn read_range(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        offset: u64,
        max_bytes: usize,
    ) -> io::Result<Vec<u8>> {
        if max_bytes > MAX_FILE_BYTES {
            return Err(denied());
        }
        let p = parts(path)?;
        let state = self.state.lock().map_err(|_| denied())?;
        let grant = state.grants.get(&cap).ok_or_else(denied)?;
        let extent = grant.descriptor_limits.read_extent();
        if &grant.scope != scope || offset > extent || libc::off_t::try_from(offset).is_err() {
            return Err(denied());
        }
        result((|| {
            let mut fd = target(&grant.root, &p)?;
            let stat = regular(&fd)?;
            if stat.st_size < 0 || stat.st_size as u64 > extent {
                return Err(denied());
            }
            fd.seek(SeekFrom::Start(offset))?;
            let count = (max_bytes as u64).min(extent - offset);
            let mut bytes = Vec::new();
            fd.take(count).read_to_end(&mut bytes)?;
            Ok(bytes)
        })())
    }
    pub fn metadata_root(&self, cap: Capability, scope: &Scope) -> io::Result<Metadata> {
        self.with(cap, scope, false, |root| Ok(metadata_from(info(root)?)))
    }
    pub fn write(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        bytes: &[u8],
    ) -> io::Result<()> {
        if bytes.len() > MAX_FILE_BYTES {
            return Err(denied());
        }
        let p = parts(path)?;
        self.with(cap, scope, true, |root| {
            let par = parent(root, &p)?;
            let leaf = p.last().unwrap();
            let mut fd = match open_at(
                par.as_raw_fd(),
                leaf,
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NONBLOCK,
            ) {
                Ok(fd) => fd,
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    open_at(par.as_raw_fd(), leaf, libc::O_WRONLY | libc::O_NONBLOCK)?
                }
                Err(e) => return Err(e),
            };
            regular(&fd)?;
            fd.set_len(0)?;
            fd.write_all(bytes)?;
            Ok(())
        })
    }
    pub fn mkdir(&self, cap: Capability, scope: &Scope, path: &Path) -> io::Result<()> {
        let p = parts(path)?;
        self.with(cap, scope, true, |root| {
            let par = parent(root, &p)?;
            if unsafe { libc::mkdirat(par.as_raw_fd(), p.last().unwrap().as_ptr(), 0o700) } != 0 {
                return Err(syscall_error());
            }
            Ok(())
        })
    }
    pub fn metadata(&self, cap: Capability, scope: &Scope, path: &Path) -> io::Result<Metadata> {
        let p = parts(path)?;
        self.with(cap, scope, false, |root| {
            let fd = target(root, &p)?;
            let s = info(&fd)?;
            let directory = s.st_mode & libc::S_IFMT == libc::S_IFDIR;
            if !directory {
                regular(&fd)?;
            }
            Ok(metadata_from(s))
        })
    }
    /// List names only; symbolic links are never followed. Use metadata/read to
    /// acquire each returned entry, which enforces permissions again.
    pub fn list(
        &self,
        cap: Capability,
        scope: &Scope,
        path: Option<&Path>,
    ) -> io::Result<Vec<std::ffi::OsString>> {
        let p = path.map(parts).transpose()?;
        self.with(cap, scope, false, |root| {
            let dir = match &p {
                Some(p) => target(root, p)?,
                None => root.try_clone()?,
            };
            if info(&dir)?.st_mode & libc::S_IFMT != libc::S_IFDIR {
                return Err(denied());
            }
            use std::os::unix::ffi::OsStringExt;
            Ok(entries(&dir)?
                .into_iter()
                .map(|n| std::ffi::OsString::from_vec(n.into_bytes()))
                .collect())
        })
    }
    pub fn remove(
        &self,
        cap: Capability,
        scope: &Scope,
        path: &Path,
        recursive: bool,
    ) -> io::Result<()> {
        let p = parts(path)?;
        self.with(cap, scope, true, |root| {
            let par = parent(root, &p)?;
            remove_node(
                &par,
                p.last().unwrap(),
                recursive,
                0,
                &mut Budget::default(),
            )
        })
    }
    /// Atomic namespace replacement within a live writable capability. Both
    /// parents remain descriptor anchored; no unrestricted pathname fallback.
    pub fn rename(
        &self,
        cap: Capability,
        scope: &Scope,
        source: &Path,
        destination: &Path,
    ) -> io::Result<()> {
        let src = parts(source)?;
        let dst = parts(destination)?;
        self.with(cap, scope, true, |root| {
            let source_parent = parent(root, &src)?;
            let destination_parent = parent(root, &dst)?;
            let source_file = open_at(
                source_parent.as_raw_fd(),
                src.last().unwrap(),
                libc::O_RDONLY | libc::O_NONBLOCK,
            )?;
            let source_stat = validate_rename_node(&source_file, 0, &mut Budget::default())?;
            let source_directory = source_stat.st_mode & libc::S_IFMT == libc::S_IFDIR;
            let same = |stat: &libc::stat| {
                stat.st_dev == source_stat.st_dev && stat.st_ino == source_stat.st_ino
            };
            match open_at(
                destination_parent.as_raw_fd(),
                dst.last().unwrap(),
                libc::O_RDONLY | libc::O_NONBLOCK,
            ) {
                Ok(file) => {
                    let stat = info(&file)?;
                    let directory = stat.st_mode & libc::S_IFMT == libc::S_IFDIR;
                    if !directory {
                        regular(&file)?;
                    }
                    if same(&stat) {
                        return Ok(());
                    }
                    if source_directory != directory {
                        return Err(rename_error(if directory {
                            libc::EISDIR
                        } else {
                            libc::ENOTDIR
                        }));
                    }
                    if directory && !entries(&file)?.is_empty() {
                        return Err(rename_error(libc::ENOTEMPTY));
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            if source_directory {
                let mut current = root.try_clone()?;
                if same(&info(&current)?) {
                    return Err(rename_error(libc::EINVAL));
                }
                for name in &dst[..dst.len() - 1] {
                    current = open_at(
                        current.as_raw_fd(),
                        name,
                        libc::O_RDONLY | libc::O_DIRECTORY,
                    )?;
                    if same(&info(&current)?) {
                        return Err(rename_error(libc::EINVAL));
                    }
                }
            }
            // Held descriptors protect parent replacement. POSIX renameat still
            // resolves leaf names; no inode-CAS guarantee against privileged actors.
            rename_at(
                &source_parent,
                src.last().unwrap(),
                &destination_parent,
                dst.last().unwrap(),
            )
        })
    }
    /// Copy within one capability. Both source read and destination write are
    /// required. Destination must not exist; partial copies are not rolled back.
    pub fn copy(
        &self,
        cap: Capability,
        scope: &Scope,
        source: &Path,
        destination: &Path,
        recursive: bool,
    ) -> io::Result<()> {
        let src = parts(source)?;
        let dst = parts(destination)?;
        self.with(cap, scope, true, |root| {
            let input = target(root, &src)?;
            if info(&input)?.st_mode & libc::S_IFMT == libc::S_IFDIR {
                // Reject copying a directory into itself or a descendant.
                let original = info(&input)?;
                let mut current = root.try_clone()?;
                let same = |f: &File| -> io::Result<bool> {
                    let s = info(f)?;
                    Ok(s.st_dev == original.st_dev && s.st_ino == original.st_ino)
                };
                if same(&current)? {
                    return Err(denied());
                }
                for n in &dst[..dst.len() - 1] {
                    current = open_at(current.as_raw_fd(), n, libc::O_RDONLY | libc::O_DIRECTORY)?;
                    if same(&current)? {
                        return Err(denied());
                    }
                }
            }
            let par = parent(root, &dst)?;
            copy_node(
                &input,
                &par,
                dst.last().unwrap(),
                recursive,
                0,
                &mut Budget::default(),
            )
        })
    }
}
fn copy_node(
    input: &File,
    parent: &File,
    leaf: &CStr,
    recursive: bool,
    depth: usize,
    budget: &mut Budget,
) -> io::Result<()> {
    budget.node(depth)?;
    let s = info(input)?;
    if s.st_mode & libc::S_IFMT == libc::S_IFDIR {
        if !recursive {
            return Err(denied());
        }
        if unsafe { libc::mkdirat(parent.as_raw_fd(), leaf.as_ptr(), 0o700) } != 0 {
            return Err(syscall_error());
        }
        let out = open_at(parent.as_raw_fd(), leaf, libc::O_RDONLY | libc::O_DIRECTORY)?;
        for child in entries(input)? {
            let fd = open_at(input.as_raw_fd(), &child, libc::O_RDONLY | libc::O_NONBLOCK)?;
            copy_node(&fd, &out, &child, true, depth + 1, budget)?;
        }
    } else {
        regular(input)?;
        if s.st_size < 0
            || s.st_size as u64 > MAX_FILE_BYTES as u64
            || budget.bytes.saturating_add(s.st_size as u64) > MAX_COPY_BYTES
        {
            return Err(denied());
        }
        let mut out = open_at(
            parent.as_raw_fd(),
            leaf,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NONBLOCK,
        )?;
        regular(&out)?;
        let source = input.try_clone()?;
        let remaining = (MAX_COPY_BYTES - budget.bytes).min(MAX_FILE_BYTES as u64);
        let mut source = source.take(remaining + 1);
        let mut copied = 0;
        let mut buffer = vec![0u8; 65536];
        loop {
            let n = source.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            if copied + n as u64 > remaining {
                return Err(denied());
            }
            out.write_all(&buffer[..n])?;
            copied += n as u64;
        }
        budget.bytes += copied;
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn errno_ptr() -> *mut libc::c_int {
    unsafe { libc::__errno_location() }
}
#[cfg(any(target_os = "macos", target_os = "ios"))]
unsafe fn errno_ptr() -> *mut libc::c_int {
    unsafe { libc::__error() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rename_parents_survive_replacement_before_final_syscall() {
        let base =
            std::env::temp_dir().join(format!("hyotan-rename-parent-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("work/source")).unwrap();
        std::fs::create_dir(base.join("work/destination")).unwrap();
        std::fs::create_dir(base.join("private")).unwrap();
        std::fs::write(base.join("work/source/file"), b"allowed").unwrap();
        std::fs::write(base.join("private/file"), b"private").unwrap();
        let root = File::open(base.join("work")).unwrap();
        let src = parts(Path::new("source/file")).unwrap();
        let dst = parts(Path::new("destination/file")).unwrap();
        let source_parent = parent(&root, &src).unwrap();
        let destination_parent = parent(&root, &dst).unwrap();
        std::fs::rename(base.join("work/source"), base.join("work/old-source")).unwrap();
        std::fs::rename(
            base.join("work/destination"),
            base.join("work/old-destination"),
        )
        .unwrap();
        std::os::unix::fs::symlink(base.join("private"), base.join("work/source")).unwrap();
        std::os::unix::fs::symlink(base.join("private"), base.join("work/destination")).unwrap();
        rename_at(
            &source_parent,
            src.last().unwrap(),
            &destination_parent,
            dst.last().unwrap(),
        )
        .unwrap();
        assert_eq!(
            std::fs::read(base.join("work/old-destination/file")).unwrap(),
            b"allowed"
        );
        assert_eq!(
            std::fs::read(base.join("private/file")).unwrap(),
            b"private"
        );
        std::fs::remove_dir_all(base).unwrap();
    }
    #[test]
    fn opened_parent_survives_replacement_between_acquisition_and_syscall() {
        let base =
            std::env::temp_dir().join(format!("hyotan-opened-parent-{}", std::process::id()));
        std::fs::create_dir(&base).unwrap();
        let root = base.join("work");
        let secret = base.join("private");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&secret).unwrap();
        std::fs::write(secret.join("canary"), b"private").unwrap();
        std::fs::create_dir(root.join("ancestor")).unwrap();
        let root_fd = File::open(&root).unwrap();
        let p = parts(Path::new("ancestor/canary")).unwrap();
        let acquired = parent(&root_fd, &p).unwrap();
        std::fs::rename(root.join("ancestor"), root.join("old")).unwrap();
        std::os::unix::fs::symlink(&secret, root.join("ancestor")).unwrap();
        let mut fd = open_at(
            acquired.as_raw_fd(),
            p.last().unwrap(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        )
        .unwrap();
        regular(&fd).unwrap();
        fd.write_all(b"authorized").unwrap();
        assert_eq!(
            std::fs::read(root.join("old/canary")).unwrap(),
            b"authorized"
        );
        assert_eq!(std::fs::read(secret.join("canary")).unwrap(), b"private");
        std::fs::remove_dir_all(&base).unwrap();
    }
}
