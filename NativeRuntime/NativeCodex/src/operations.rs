// Copyright 2026 Hyotan contributors. SPDX-License-Identifier: Apache-2.0
//! Trusted-host C boundary, not a JS or model-callable pointer API.
use hyotan_operation_harness::{
    Access, Capability, DescriptorLimits, FileAccess, FileHandle, Harness, MAX_HANDLE_CHUNK,
    Metadata, OpenOptions, Scope,
};
use std::{
    collections::HashMap,
    ffi::{CStr, c_char},
    fs::File,
    io,
    os::fd::FromRawFd,
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
const MAX_PATH: usize = 4096;
const MAX_LIST_BYTES: usize = 1024 * 1024;
#[repr(C)]
#[derive(Default)]
pub struct HyotanOperationMetadata {
    bytes: u64,
    created_at_ms: u64,
    modified_at_ms: u64,
    flags: u32,
    reserved: u32,
}
impl From<Metadata> for HyotanOperationMetadata {
    fn from(m: Metadata) -> Self {
        Self {
            bytes: m.bytes,
            created_at_ms: m.created_at_ms.unwrap_or(0),
            modified_at_ms: m.modified_at_ms.unwrap_or(0),
            flags: u32::from(m.directory)
                | if m.created_at_ms.is_some() { 2 } else { 0 }
                | if m.modified_at_ms.is_some() { 4 } else { 0 },
            reserved: 0,
        }
    }
}
#[derive(Default)]
struct BridgeState {
    revoked: bool,
    handles: HashMap<u64, FileHandle>,
}
pub struct HyotanWorkspace {
    harness: Harness,
    capability: Capability,
    scope: Scope,
    state: Mutex<BridgeState>,
    descriptor_limits: DescriptorLimits,
    configured_descriptors: bool,
}
type Result<T> = std::result::Result<T, i32>;
fn errno(e: io::Error) -> i32 {
    match e.kind() {
        io::ErrorKind::PermissionDenied => libc::EACCES,
        io::ErrorKind::NotFound => libc::ENOENT,
        io::ErrorKind::AlreadyExists => libc::EEXIST,
        io::ErrorKind::IsADirectory => libc::EISDIR,
        io::ErrorKind::NotADirectory => libc::ENOTDIR,
        io::ErrorKind::DirectoryNotEmpty => libc::ENOTEMPTY,
        io::ErrorKind::CrossesDevices => libc::EXDEV,
        io::ErrorKind::InvalidInput => libc::EINVAL,
        _ => libc::EIO,
    }
}
fn boundary(f: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => e,
        Err(_) => libc::EIO,
    }
}
unsafe fn output_zero<T: Default>(output: *mut T) -> Result<()> {
    if output.is_null() {
        return Err(libc::EINVAL);
    }
    unsafe {
        output.write(T::default());
    }
    Ok(())
}
unsafe fn input_bytes<'a>(pointer: *const u8, length: usize, limit: usize) -> Result<&'a [u8]> {
    if length > limit {
        return Err(libc::EFBIG);
    }
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(libc::EINVAL);
    }
    Ok(unsafe { std::slice::from_raw_parts(pointer, length) })
}
unsafe fn path<'a>(pointer: *const u8, length: usize, root_allowed: bool) -> Result<&'a Path> {
    let bytes = unsafe { input_bytes(pointer, length, MAX_PATH) }?;
    if bytes.contains(&0) {
        return Err(libc::EINVAL);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| libc::EINVAL)?;
    if text.is_empty() && !root_allowed {
        return Err(libc::EINVAL);
    }
    Ok(Path::new(text))
}
unsafe fn with_workspace<T>(
    workspace: *mut HyotanWorkspace,
    f: impl FnOnce(&HyotanWorkspace, &mut BridgeState) -> Result<T>,
) -> Result<T> {
    let workspace = unsafe { workspace.as_ref() }.ok_or(libc::EINVAL)?;
    let mut state = workspace.state.lock().map_err(|_| libc::EIO)?;
    if state.revoked {
        return Err(libc::EACCES);
    }
    f(workspace, &mut state)
}
fn handle(state: &BridgeState, id: u64) -> Result<FileHandle> {
    state.handles.get(&id).copied().ok_or(libc::EACCES)
}
// Pointer/instance lifetimes and nonaliasing buffers are the trusted host's
// responsibility as documented in HyotanOperations.h. All functions catch Rust
// panics; invalid/dangling C pointers remain outside that safety contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_create(
    directory_fd: i32,
    owner: *const c_char,
    generation: u64,
    access: u32,
    out: *mut *mut HyotanWorkspace,
) -> i32 {
    unsafe {
        create_workspace(
            directory_fd,
            owner,
            generation,
            access,
            DescriptorLimits::default(),
            false,
            out,
        )
    }
}
/// Trusted bootstrap only. These extents are never accepted in a guest operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_create_with_descriptor_limits(
    directory_fd: i32,
    owner: *const c_char,
    generation: u64,
    access: u32,
    read_extent: u64,
    write_extent: u64,
    out: *mut *mut HyotanWorkspace,
) -> i32 {
    boundary(|| {
        if out.is_null() {
            return Err(libc::EINVAL);
        }
        unsafe {
            out.write(std::ptr::null_mut());
        }
        let limits = DescriptorLimits::new(read_extent, write_extent).map_err(|_| libc::EINVAL)?;
        let code =
            unsafe { create_workspace(directory_fd, owner, generation, access, limits, true, out) };
        if code == 0 { Ok(()) } else { Err(code) }
    })
}
unsafe fn create_workspace(
    directory_fd: i32,
    owner: *const c_char,
    generation: u64,
    access: u32,
    descriptor_limits: DescriptorLimits,
    configured_descriptors: bool,
    out: *mut *mut HyotanWorkspace,
) -> i32 {
    boundary(|| {
        if out.is_null() {
            return Err(libc::EINVAL);
        }
        unsafe {
            out.write(std::ptr::null_mut());
        }
        if owner.is_null() {
            return Err(libc::EINVAL);
        }
        let owner = unsafe { CStr::from_ptr(owner) }
            .to_str()
            .map_err(|_| libc::EINVAL)?;
        if owner.is_empty() || owner.len() > 256 {
            return Err(libc::EINVAL);
        }
        let access = match access {
            1 => Access::ReadOnly,
            2 => Access::ReadWrite,
            _ => return Err(libc::EINVAL),
        };
        let fd = unsafe { libc::fcntl(directory_fd, libc::F_DUPFD_CLOEXEC, 0) };
        if fd < 0 {
            return Err(libc::EBADF);
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let harness = Harness::default();
        let scope = Scope {
            owner: owner.to_owned(),
            generation,
        };
        let capability = harness
            .grant_from_owned_directory_with_descriptor_limits(
                file,
                scope.clone(),
                access,
                descriptor_limits,
            )
            .map_err(errno)?;
        let instance = Box::new(HyotanWorkspace {
            harness,
            capability,
            scope,
            state: Mutex::new(BridgeState::default()),
            descriptor_limits,
            configured_descriptors,
        });
        unsafe {
            out.write(Box::into_raw(instance));
        }
        Ok(())
    })
}
/// Read-only policy observation for a trusted bootstrap. Revoked instances deny.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_descriptor_limits(
    workspace: *mut HyotanWorkspace,
    out_read: *mut u64,
    out_write: *mut u64,
    out_configured: *mut u32,
) -> i32 {
    boundary(|| {
        unsafe {
            output_zero(out_read)?;
            output_zero(out_write)?;
            output_zero(out_configured)?;
        }
        unsafe {
            with_workspace(workspace, |w, _| {
                let legacy = hyotan_operation_harness::MAX_FILE_BYTES as u64;
                out_read.write(if w.configured_descriptors {
                    w.descriptor_limits.read_extent()
                } else {
                    legacy
                });
                out_write.write(if w.configured_descriptors {
                    w.descriptor_limits.write_extent()
                } else {
                    legacy
                });
                out_configured.write(u32::from(w.configured_descriptors));
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_revoke(workspace: *mut HyotanWorkspace) -> i32 {
    boundary(|| unsafe {
        with_workspace(workspace, |w, state| {
            w.harness.revoke(w.capability, &w.scope).map_err(errno)?;
            state.revoked = true;
            state.handles.clear();
            Ok(())
        })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_destroy(workspace: *mut HyotanWorkspace) -> i32 {
    boundary(|| {
        if workspace.is_null() {
            return Err(libc::EINVAL);
        }
        let instance = unsafe { Box::from_raw(workspace) };
        let state = instance.state.lock().map_err(|_| libc::EIO)?;
        if !state.revoked {
            instance
                .harness
                .revoke(instance.capability, &instance.scope)
                .map_err(errno)?;
        }
        drop(state);
        drop(instance);
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_open(
    workspace: *mut HyotanWorkspace,
    p: *const u8,
    len: usize,
    flags: u32,
    out: *mut u64,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out) }?;
        let p = unsafe { path(p, len, false) }?;
        if flags & !63 != 0
            || flags & 3 == 0
            || flags & 8 != 0 && flags & 4 == 0
            || flags & 48 != 0 && flags & 2 == 0
        {
            return Err(libc::EINVAL);
        }
        let access = match flags & 3 {
            1 => FileAccess::ReadOnly,
            2 => FileAccess::WriteOnly,
            3 => FileAccess::ReadWrite,
            _ => unreachable!(),
        };
        let options = OpenOptions {
            access,
            create: flags & 4 != 0,
            exclusive: flags & 8 != 0,
            truncate: flags & 16 != 0,
            append: flags & 32 != 0,
        };
        unsafe {
            with_workspace(workspace, |w, state| {
                let core = if w.configured_descriptors {
                    w.harness
                        .open_stream_handle(w.capability, &w.scope, p, options)
                } else {
                    w.harness.open_handle(w.capability, &w.scope, p, options)
                }
                .map_err(errno)?;
                static NEXT: AtomicU64 = AtomicU64::new(1);
                let id = match NEXT
                    .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
                {
                    Ok(id) => id,
                    Err(_) => {
                        let _ = w.harness.close_handle(w.capability, &w.scope, core);
                        return Err(libc::EIO);
                    }
                };
                state.handles.insert(id, core);
                out.write(id);
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_read_at(
    workspace: *mut HyotanWorkspace,
    id: u64,
    offset: u64,
    requested: usize,
    output: *mut u8,
    capacity: usize,
    out_read: *mut usize,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out_read) }?;
        if requested > MAX_HANDLE_CHUNK || capacity > MAX_HANDLE_CHUNK {
            return Err(libc::EFBIG);
        }
        if capacity < requested {
            return Err(libc::ERANGE);
        }
        if requested > 0 && output.is_null() {
            return Err(libc::EINVAL);
        }
        unsafe {
            with_workspace(workspace, |w, state| {
                let bytes = w
                    .harness
                    .read_at(
                        w.capability,
                        &w.scope,
                        handle(state, id)?,
                        offset,
                        requested,
                    )
                    .map_err(errno)?;
                if !bytes.is_empty() {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
                }
                out_read.write(bytes.len());
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_write_at(
    workspace: *mut HyotanWorkspace,
    id: u64,
    offset: u64,
    input: *const u8,
    length: usize,
    out_written: *mut usize,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out_written) }?;
        let bytes = unsafe { input_bytes(input, length, MAX_HANDLE_CHUNK) }?;
        unsafe {
            with_workspace(workspace, |w, state| {
                let count = w
                    .harness
                    .write_at(w.capability, &w.scope, handle(state, id)?, offset, bytes)
                    .map_err(errno)?;
                out_written.write(count);
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_truncate(
    workspace: *mut HyotanWorkspace,
    id: u64,
    length: u64,
) -> i32 {
    boundary(|| unsafe {
        with_workspace(workspace, |w, state| {
            w.harness
                .truncate_handle(w.capability, &w.scope, handle(state, id)?, length)
                .map_err(errno)
        })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_stat(
    workspace: *mut HyotanWorkspace,
    id: u64,
    out: *mut HyotanOperationMetadata,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out) }?;
        unsafe {
            with_workspace(workspace, |w, state| {
                let metadata = w
                    .harness
                    .stat_handle(w.capability, &w.scope, handle(state, id)?)
                    .map_err(errno)?;
                out.write(metadata.into());
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_close(workspace: *mut HyotanWorkspace, id: u64) -> i32 {
    boundary(|| unsafe {
        with_workspace(workspace, |w, state| {
            w.harness
                .close_handle(w.capability, &w.scope, handle(state, id)?)
                .map_err(errno)?;
            state.handles.remove(&id);
            Ok(())
        })
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_metadata(
    workspace: *mut HyotanWorkspace,
    p: *const u8,
    len: usize,
    out: *mut HyotanOperationMetadata,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out) }?;
        let p = unsafe { path(p, len, true) }?;
        unsafe {
            with_workspace(workspace, |w, _| {
                let metadata = if p.as_os_str().is_empty() {
                    w.harness.metadata_root(w.capability, &w.scope)
                } else {
                    w.harness.metadata(w.capability, &w.scope, p)
                }
                .map_err(errno)?;
                out.write(metadata.into());
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_list(
    workspace: *mut HyotanWorkspace,
    p: *const u8,
    len: usize,
    output: *mut u8,
    capacity: usize,
    out_written: *mut usize,
    out_entries: *mut usize,
    out_required: *mut usize,
) -> i32 {
    boundary(|| {
        unsafe { output_zero(out_written) }?;
        unsafe { output_zero(out_entries) }?;
        unsafe { output_zero(out_required) }?;
        let p = unsafe { path(p, len, true) }?;
        if capacity > MAX_LIST_BYTES {
            return Err(libc::EFBIG);
        }
        if capacity > 0 && output.is_null() {
            return Err(libc::EINVAL);
        }
        unsafe {
            with_workspace(workspace, |w, _| {
                let names = w
                    .harness
                    .list(
                        w.capability,
                        &w.scope,
                        if p.as_os_str().is_empty() {
                            None
                        } else {
                            Some(p)
                        },
                    )
                    .map_err(errno)?;
                let mut bytes = Vec::new();
                for name in &names {
                    let text = name.to_str().ok_or(libc::EINVAL)?;
                    if bytes
                        .len()
                        .checked_add(text.len() + 1)
                        .is_none_or(|n| n > MAX_LIST_BYTES)
                    {
                        return Err(libc::EFBIG);
                    }
                    bytes.extend_from_slice(text.as_bytes());
                    bytes.push(0);
                }
                out_required.write(bytes.len());
                if capacity < bytes.len() {
                    return Err(libc::ERANGE);
                }
                if !bytes.is_empty() {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
                }
                out_written.write(bytes.len());
                out_entries.write(names.len());
                Ok(())
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_mkdir(
    workspace: *mut HyotanWorkspace,
    p: *const u8,
    len: usize,
) -> i32 {
    boundary(|| {
        let p = unsafe { path(p, len, false) }?;
        unsafe {
            with_workspace(workspace, |w, _| {
                w.harness.mkdir(w.capability, &w.scope, p).map_err(errno)
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_remove(
    workspace: *mut HyotanWorkspace,
    p: *const u8,
    len: usize,
    recursive: u32,
) -> i32 {
    boundary(|| {
        let p = unsafe { path(p, len, false) }?;
        if recursive > 1 {
            return Err(libc::EINVAL);
        }
        unsafe {
            with_workspace(workspace, |w, _| {
                w.harness
                    .remove(w.capability, &w.scope, p, recursive == 1)
                    .map_err(errno)
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_copy(
    workspace: *mut HyotanWorkspace,
    source: *const u8,
    source_len: usize,
    destination: *const u8,
    destination_len: usize,
    recursive: u32,
) -> i32 {
    boundary(|| {
        let source = unsafe { path(source, source_len, false) }?;
        let destination = unsafe { path(destination, destination_len, false) }?;
        if recursive > 1 {
            return Err(libc::EINVAL);
        }
        unsafe {
            with_workspace(workspace, |w, _| {
                w.harness
                    .copy(w.capability, &w.scope, source, destination, recursive == 1)
                    .map_err(errno)
            })
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_operations_rename(
    workspace: *mut HyotanWorkspace,
    source: *const u8,
    source_len: usize,
    destination: *const u8,
    destination_len: usize,
) -> i32 {
    boundary(|| {
        let source = unsafe { path(source, source_len, false) }?;
        let destination = unsafe { path(destination, destination_len, false) }?;
        unsafe {
            with_workspace(workspace, |w, _| {
                w.harness
                    .rename(w.capability, &w.scope, source, destination)
                    .map_err(errno)
            })
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn hyotan_operations_error_message(error: i32) -> *const c_char {
    let message:&CStr=match error {
  0=>c"Operation completed.",
  libc::EACCES=>c"Operation denied. Use files in the active workspace with its current granted permissions; do not retry through unrestricted file APIs.",
  libc::EISDIR=>c"Workspace destination is a directory.",libc::ENOTDIR=>c"Workspace destination is not a directory.",libc::ENOTEMPTY=>c"Workspace destination directory is not empty.",libc::EXDEV=>c"Operation must remain on one workspace filesystem.",libc::ENOENT=>c"Workspace entry does not exist.",libc::EEXIST=>c"Workspace destination already exists.",libc::EINVAL=>c"Invalid operation arguments.",libc::ERANGE=>c"Output buffer is too small; allocate the bounded required capacity.",libc::EFBIG=>c"Operation exceeds the permitted size limit.",libc::EBADF=>c"Trusted workspace descriptor is unavailable.",_=>c"Operation failed; no unrestricted fallback is allowed."
 };
    message.as_ptr()
}
