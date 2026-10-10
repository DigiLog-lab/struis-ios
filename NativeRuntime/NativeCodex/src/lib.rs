#[cfg(feature = "search")]
mod search;
#[cfg(feature = "operations")]
mod operations;

#[cfg(feature = "codex")]
mod codex {
use std::ffi::{CStr, c_char};
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicU16, AtomicU32, Ordering};

use codex_app_server::{
    AppServerRuntimeOptions, AppServerTransport, AppServerWebsocketAuthArgs,
    CodeModeHostTransport, PluginStartupTasks, RemoteControlStartupMode,
    WebsocketAuthCliMode, run_main_with_transport_options,
};
use codex_arg0::Arg0DispatchPaths;
use codex_config::LoaderOverrides;
use codex_protocol::protocol::SessionSource;
use codex_utils_cli::CliConfigOverrides;

static STARTED: OnceLock<()> = OnceLock::new();
static BOUND_PORT: AtomicU16 = AtomicU16::new(0);
static FAILURE: Mutex<Option<String>> = Mutex::new(None);
static BOOTSTRAP: Mutex<()> = Mutex::new(());
static PANIC_SITE: Mutex<Option<String>> = Mutex::new(None);
static PANICS: AtomicU32 = AtomicU32::new(0);

/// Records where the latest panic happened (source location only, never the
/// message) and keeps the default report. A panic in one connection task closes
/// only that WebSocket and leaves the process alive, so no crash report exists.
fn install_panic_site_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        PANICS.fetch_add(1, Ordering::Relaxed);
        if let (Some(location), Ok(mut site)) = (info.location(), PANIC_SITE.try_lock()) {
            *site = Some(format!("{}:{}", location.file(), location.line()));
        }
        previous(info);
    }));
}

unsafe fn copy_out(value: Option<&str>, buffer: *mut c_char, capacity: usize) -> usize {
    if buffer.is_null() || capacity == 0 { return 0; }
    let Some(value) = value else { unsafe { *buffer = 0; } return 0; };
    let length = value.len().min(capacity - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), buffer.cast::<u8>(), length);
        *buffer.add(length) = 0;
    }
    length
}

/// Trusted bootstrap: the app installs the workspace capability before starting
/// Codex in its own process. The caller retains its descriptor; the grant owns a
/// duplicate. This installs only the Environment filesystem, not a sandbox for
/// every Codex reader (native Python runs in the separate Exec worker).
///
/// # Safety
/// root and owner must be valid NUL-terminated UTF-8 strings for this call;
/// directory_fd must refer to the trusted workspace corresponding to root.
#[cfg(target_os = "ios")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_codex_install_operation_harness(directory_fd: i32, root: *const c_char, owner: *const c_char, generation: u64) -> i32 {
    use std::os::fd::FromRawFd;
    use hyotan_operation_harness::{Access, Harness, Scope};
    use hyotan_appserver_operation_harness::CapabilityFileSystem;
    if root.is_null() || owner.is_null() { return 22; }
    let Ok(root) = (unsafe { CStr::from_ptr(root) }).to_str() else { return 22; };
    let Ok(owner) = (unsafe { CStr::from_ptr(owner) }).to_str() else { return 22; };
    let Ok(_bootstrap) = BOOTSTRAP.lock() else { return 5; };
    if STARTED.get().is_some() { return 114; }
    // Local media read without a turn lease must resolve inside the same workspace.
    let Ok(media_root) = std::fs::canonicalize(root) else { return 13; };
    let descriptor = unsafe { libc::fcntl(directory_fd, libc::F_DUPFD_CLOEXEC, 0) };
    if descriptor < 0 { return 13; }
    let directory = unsafe { std::fs::File::from_raw_fd(descriptor) };
    let scope = Scope { owner: owner.to_owned(), generation };
    let harness = std::sync::Arc::new(Harness::default());
    let Ok(capability) = harness.grant_from_owned_directory(directory, scope.clone(), Access::ReadWrite) else { return 13; };
    let Ok(filesystem) = CapabilityFileSystem::new(harness, capability, scope, PathBuf::from(root)) else { return 13; };
    if codex_exec_server::hyotan_install_local_file_system(std::sync::Arc::new(filesystem)).is_err() { return 114; }
    if codex_protocol::models::HYOTAN_LOCAL_MEDIA_ROOT.set(media_root).is_err() { return 114; }
    0
}

/// The trusted bootstrap reserves the actual port, not a temporary probe.
#[cfg(target_os = "ios")]
fn reserve_websocket_listener(port: u16) -> std::io::Result<SocketAddr> {
    let listener = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))?;
    let address = listener.local_addr()?;
    codex_app_server::hyotan_install_websocket_listener(listener)?;
    Ok(address)
}

/// Moves the running server to a new loopback listener and returns its port, or
/// zero. iOS reclaims a suspended app's listening socket; the server keeps
/// running but can no longer accept connections until it listens again.
#[unsafe(no_mangle)]
pub extern "C" fn hyotan_codex_rebind() -> u16 {
    #[cfg(target_os = "ios")]
    {
        let Ok(_bootstrap) = BOOTSTRAP.lock() else { return 0; };
        if STARTED.get().is_none() { return 0; }
        let Ok(listener) = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))) else { return 0; };
        let Ok(address) = listener.local_addr() else { return 0; };
        if codex_app_server::hyotan_replace_websocket_listener(listener).is_err() { return 0; }
        BOUND_PORT.store(address.port(), Ordering::Release);
        address.port()
    }
    #[cfg(not(target_os = "ios"))]
    { 0 }
}

/// Actual owned listener port; zero before successful native startup.
#[unsafe(no_mangle)]
pub extern "C" fn hyotan_codex_port() -> u16 {
    BOUND_PORT.load(Ordering::Acquire)
}

/// Starts the bundled server once. The caller owns the token file and must set
/// CODEX_HOME before starting any terminal/Python worker. No native executable
/// is downloaded or spawned by this bridge. On iOS, port0 requests an OS-assigned
/// port whose listener is kept owned by the actual AppServer transport.
///
/// # Safety
/// token_file must point to a valid, NUL-terminated UTF-8 string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_codex_start(port: u16, token_file: *const c_char) -> i32 {
    if token_file.is_null() { return 22; }
    let Ok(token_path) = (unsafe { CStr::from_ptr(token_file) }).to_str() else { return 22; };
    let token_path = PathBuf::from(token_path);
    let Ok(_bootstrap) = BOOTSTRAP.lock() else { return 5; };
    if STARTED.get().is_some() { return 114; }
    #[cfg(target_os = "ios")]
    let bind_address = match reserve_websocket_listener(port) {
        Ok(address) => address,
        Err(error) => {
            if let Ok(mut value) = FAILURE.lock() { *value = Some(error.to_string()); }
            return error.raw_os_error().unwrap_or(5);
        }
    };
    #[cfg(not(target_os = "ios"))]
    let bind_address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    if STARTED.set(()).is_err() { return 114; }
    // A previous attempt's bind failure no longer describes this server.
    if let Ok(mut value) = FAILURE.lock() { *value = None; }
    install_panic_site_hook();
    let thread = std::thread::Builder::new().name("hyotan.codex".into()).stack_size(16 * 1024 * 1024).spawn(move || {
        let result = std::panic::catch_unwind(|| -> Result<(), String> {
            let auth = AppServerWebsocketAuthArgs {
                ws_auth: Some(WebsocketAuthCliMode::CapabilityToken),
                ws_token_file: Some(token_path),
                ..Default::default()
            }.try_into_settings().map_err(|e| e.to_string())?;
            let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2)
                .thread_stack_size(8 * 1024 * 1024)
                // Tokio filesystem work shares this pool. Bound concurrent allocation
                // without changing the already validated async-worker stack capacity.
                .max_blocking_threads(8).enable_all().build().map_err(|e| e.to_string())?;
            let overrides = CliConfigOverrides {
                raw_overrides: vec![
                    "features.shell_tool=false".into(),
                    "features.code_mode=false".into(),
                    "features.code_mode_host=false".into(),
                    "features.shell_snapshot=false".into(),
                    // Built-in sub-agents read model-chosen local media with plain
                    // std::fs, outside the workspace capability. Struis delegates
                    // through its own struis_delegate tool instead. The model's own
                    // multi-agent version wins over features.multi_agent, so only
                    // agents.enabled=false (with v2 off) removes the tools.
                    "features.multi_agent=false".into(),
                    "features.multi_agent_v2=false".into(),
                    "agents.enabled=false".into(),
                    "cli_auth_credentials_store=\"file\"".into(),
                    "analytics.enabled=false".into(),
                ],
            };
            runtime.block_on(run_main_with_transport_options(
                Arg0DispatchPaths { codex_self_exe: Some(std::env::current_exe().map_err(|e| e.to_string())?), ..Default::default() }, overrides, LoaderOverrides::default(),
                true, false,
                AppServerTransport::WebSocket { bind_address },
                SessionSource::Custom("hyotan".into()), auth,
                AppServerRuntimeOptions {
                    code_mode_host_transport: CodeModeHostTransport::Local,
                    plugin_startup_tasks: PluginStartupTasks::Skip,
                    remote_control_startup_mode: RemoteControlStartupMode::DisabledEphemeral,
                    install_shutdown_signal_handler: false,
                },
            )).map_err(|e| e.to_string())
        });
        let error = match result {
            Ok(Ok(())) => "Codex server stopped".into(),
            Ok(Err(error)) => error,
            Err(_) => "Codex server panicked".into(),
        };
        if let Ok(mut value) = FAILURE.lock() { *value = Some(error); }
    });
    if thread.is_ok() {
        BOUND_PORT.store(bind_address.port(), Ordering::Release);
        0
    } else {
        // STARTED stays set: a later start reports this instead of trying again.
        if let Ok(mut value) = FAILURE.lock() { *value = Some("Codex server thread could not start".into()); }
        11
    }
}

/// Copies the startup/runtime error into the caller's buffer, with a NUL terminator.
///
/// # Safety
/// buffer must be writable for capacity bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_codex_error(buffer: *mut c_char, capacity: usize) -> usize {
    let Ok(value) = FAILURE.lock() else { return 0; };
    unsafe { copy_out(value.as_deref(), buffer, capacity) }
}

/// Copies the latest panic's source location (`file:line`), with a NUL terminator.
///
/// # Safety
/// buffer must be writable for capacity bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_codex_panic_site(buffer: *mut c_char, capacity: usize) -> usize {
    let Ok(value) = PANIC_SITE.lock() else { return 0; };
    unsafe { copy_out(value.as_deref(), buffer, capacity) }
}

/// Panics observed in this process, including ones that ended only one task.
#[unsafe(no_mangle)]
pub extern "C" fn hyotan_codex_panic_count() -> u32 {
    PANICS.load(Ordering::Relaxed)
}
}
