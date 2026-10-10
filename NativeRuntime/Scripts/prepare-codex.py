#!/usr/bin/env python3
"""Apply reproducible iOS-only adaptations to the pinned Apache-2.0 Codex source."""
import pathlib
import shutil
import subprocess
import tarfile
import hashlib

from fetch import fetch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/codex-source'
REVISION = '3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'

def original(relative):
    return subprocess.check_output(['git', '-C', str(SOURCE), 'show', f'{REVISION}:{relative}'], text=True)

def write(relative, text):
    (SOURCE / relative).parent.mkdir(parents=True, exist_ok=True)
    (SOURCE / relative).write_text(('# Hyotan: iOS-only dependency selection.\n' if relative.endswith('.toml') else '// Hyotan: modified for the embedded iOS runtime.\n') + text)

def platform_dependency(relative, dependency):
    text = original(relative)
    line = f'{dependency} = {{ workspace = true }}\n'
    if text.count(line) != 1:
        raise RuntimeError(f'Unexpected upstream dependency: {relative}: {dependency}')
    text = text.replace(line, '')
    text += f'\n[target.\'cfg(not(target_os = "ios"))\'.dependencies]\n{line}'
    write(relative, text)

if subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip() != REVISION:
    raise RuntimeError('Codex checkout does not match the recorded revision')
platform_dependency('codex-rs/file-search/Cargo.toml', 'nucleo')
write('codex-rs/file-search/src/upstream.rs', original('codex-rs/file-search/src/lib.rs'))
shutil.copyfile(ROOT / 'NativeCodex/ios/file_search.rs', SOURCE / 'codex-rs/file-search/src/hyotan.rs')
write('codex-rs/file-search/src/lib.rs', '''// Hyotan iOS adaptation; upstream Apache-2.0 implementation retained for other targets.
#[cfg(not(target_os = "ios"))]
#[path = "upstream.rs"]
mod platform;
#[cfg(target_os = "ios")]
#[path = "hyotan.rs"]
mod platform;
pub use platform::*;
''')
platform_dependency('codex-rs/utils/audio/Cargo.toml', 'symphonia')
text = original('codex-rs/utils/audio/src/lib.rs')
for line in text.splitlines():
    if line.startswith('use symphonia::') or line == 'use std::io::Cursor;':
        text = text.replace(line, '#[cfg(not(target_os = "ios"))]\n' + line)
start = text.index('    let media_source = MediaSourceStream::new')
end = text.index('\n}\n\nfn prepare_audio', start)
body = text[start:end]
text = text[:start] + '''    #[cfg(target_os = "ios")]
    {
        let _ = canonical_mime;
        unsafe extern "C" {
            fn hyotan_audio_duration(bytes: *const u8, length: usize) -> f64;
        }
        let duration = unsafe { hyotan_audio_duration(bytes.as_ptr(), bytes.len()) };
        duration.is_finite().then_some(duration)
    }
    #[cfg(not(target_os = "ios"))]
    {
''' + body + '\n    }' + text[end:]
write('codex-rs/utils/audio/src/lib.rs', text)

# Keep independent databases and diagnostics intact while bounding their
# embedded-process resource use. Always derive from the pin, not prior output.
sqlite_path = 'codex-rs/state/src/sqlite.rs'
SQLITE_IOS_JOURNAL = '''            .journal_mode(if cfg!(target_os = "ios") {
                SqliteJournalMode::Delete
            } else {
                SqliteJournalMode::Wal
            })
'''
text = original(sqlite_path)
sqlite_connections = '            .max_connections(5)'
if text.count(sqlite_connections) != 1:
    raise RuntimeError('Unexpected upstream writable SQLite pool limit')
sqlite_limits = '''#[cfg(target_os = "ios")]
const MAX_READ_WRITE_CONNECTIONS: u32 = 1;
#[cfg(not(target_os = "ios"))]
const MAX_READ_WRITE_CONNECTIONS: u32 = 5;

'''
sqlite_import = 'use crate::DbTelemetry;'
if text.count(sqlite_import) != 1:
    raise RuntimeError('Unexpected upstream SQLite configuration imports')
text = text.replace(sqlite_import, sqlite_limits + sqlite_import)
# iOS kills a suspended process (0xDEAD10CC) that holds a file lock in the app
# group, where CODEX_HOME lives. An open WAL connection keeps a shared lock on
# the -shm file even while idle; a rollback journal holds locks only inside a
# transaction.
sqlite_wal = '            .journal_mode(SqliteJournalMode::Wal)\n'
if text.count(sqlite_wal) != 1 or text.count('SqliteJournalMode::') != 1:
    raise RuntimeError('Unexpected upstream SQLite journal mode')
text = text.replace(sqlite_wal, SQLITE_IOS_JOURNAL)
write(sqlite_path, text.replace(
    sqlite_connections, '            .max_connections(MAX_READ_WRITE_CONNECTIONS)'))

feedback_path = 'codex-rs/feedback/src/lib.rs'
text = original(feedback_path)
feedback_limit = 'const DEFAULT_MAX_BYTES: usize = 4 * 1024 * 1024; // 4 MiB'
if text.count(feedback_limit) != 1:
    raise RuntimeError('Unexpected upstream feedback ring limit')
write(feedback_path, text.replace(feedback_limit, '''#[cfg(target_os = "ios")]
const DEFAULT_MAX_BYTES: usize = 256 * 1024; // 256 KiB
#[cfg(not(target_os = "ios"))]
''' + feedback_limit))

# Codex runs in the app process, and model-directed commands can write the
# workspace. Project-local .codex/config.toml (trusted automatically for a cwd
# with full access) can name files Codex then reads directly, outside the
# workspace capability, such as model_instructions_file. Struis supplies its
# instructions per thread, so iOS loads no project config layers.
loader_path = 'codex-rs/config/src/loader/mod.rs'
text = original(loader_path)
project_layers = """) -> io::Result<LoadedProjectLayers> {
    let discovered = discover_project_layers(
"""
if text.count(project_layers) != 1:
    raise RuntimeError('Unexpected upstream project config loader')
write(loader_path, text.replace(project_layers, """) -> io::Result<LoadedProjectLayers> {
    if cfg!(target_os = "ios") {
        return Ok(LoadedProjectLayers { layers: Vec::new(), startup_warnings: Vec::new() });
    }
    let discovered = discover_project_layers(
""", 1))

history_path = 'codex-rs/core/src/context_manager/history.rs'
text = original(history_path)
start = text.index('        let dynamic = match image::load_from_memory(&bytes) {', text.index('fn estimate_original_image_bytes('))
end = text.index('        let patch_size = ', start)
full_dimensions = text[start:end]
expected_dimensions = '''        let dynamic = match image::load_from_memory(&bytes) {
            Ok(dynamic) => dynamic,
            Err(error) => {
                tracing::trace!("failed to decode original-detail image bytes: {error}");
                return None;
            }
        };
        let width = i64::from(dynamic.width());
        let height = i64::from(dynamic.height());
'''
if full_dimensions != expected_dimensions:
    raise RuntimeError('Unexpected upstream original-detail image estimator')
header_dimensions = '''        // Token estimation only: input validation remains in utils/image.
        // A readable header may yield dimensions even if the image body is invalid.
        #[cfg(target_os = "ios")]
        let (width, height) = {
            let reader = match image::ImageReader::new(std::io::Cursor::new(&bytes)).with_guessed_format() {
                Ok(reader) => reader,
                Err(error) => {
                    tracing::trace!("failed to read original-detail image header: {error}");
                    return None;
                }
            };
            match reader.into_dimensions() {
                Ok((width, height)) => (i64::from(width), i64::from(height)),
                Err(error) => {
                    tracing::trace!("failed to read original-detail image dimensions: {error}");
                    return None;
                }
            }
        };
        #[cfg(not(target_os = "ios"))]
        let (width, height) = {
''' + ''.join('    ' + line + '\n' for line in full_dimensions.splitlines()) + '''            (width, height)
        };
'''
write(history_path, text[:start] + header_dimensions + text[end:])

# A trusted embedding caller can install the capability adapter before startup.
# Without installation, retain the existing extension filesystem. This does not
# mediate LOCAL_FS, protocol media readers, native search or arbitrary native code;
# it must not be used as authorization to move AppServer into the app host.
environment_path = 'codex-rs/exec-server/src/environment.rs'
text = original(environment_path)
filesystem = '''            filesystem: Arc::new(LocalFileSystem::with_runtime_paths(
                local_runtime_paths.clone(),
            )),'''
if text.count(filesystem) != 1:
    raise RuntimeError('Unexpected upstream local environment filesystem factory')
text = text.replace(filesystem, '            filesystem: hyotan_local_file_system(local_runtime_paths.clone()),')
text += '''

#[cfg(target_os = "ios")]
static HYOTAN_LOCAL_FILE_SYSTEM: std::sync::OnceLock<Arc<dyn ExecutorFileSystem>> = std::sync::OnceLock::new();

/// Trusted bootstrap only; install before constructing any local environment.
#[cfg(target_os = "ios")]
pub fn hyotan_install_local_file_system(filesystem: Arc<dyn ExecutorFileSystem>) -> Result<(), Arc<dyn ExecutorFileSystem>> {
    HYOTAN_LOCAL_FILE_SYSTEM.set(filesystem)
}

fn hyotan_local_file_system(runtime_paths: ExecServerRuntimePaths) -> Arc<dyn ExecutorFileSystem> {
    #[cfg(target_os = "ios")]
    if let Some(filesystem) = HYOTAN_LOCAL_FILE_SYSTEM.get() {
        return Arc::clone(filesystem);
    }
    Arc::new(LocalFileSystem::with_runtime_paths(runtime_paths))
}
'''
write(environment_path, text)
exec_lib = 'codex-rs/exec-server/src/lib.rs'
text = original(exec_lib)
text += '\n#[cfg(target_os = "ios")]\npub use environment::hyotan_install_local_file_system;\n'
write(exec_lib, text)

# Reserve one actual loopback socket in trusted native bootstrap and hand the
# same listener to Tokio. Never close a probe socket and race a later rebind.
websocket_path = 'codex-rs/app-server-transport/src/transport/websocket.rs'
text = original(websocket_path)
websocket_bind = '    let listener = TcpListener::bind(bind_address).await?;'
if text.count(websocket_bind) != 1:
    raise RuntimeError('Unexpected upstream WebSocket listener binding')
text = text.replace(websocket_bind, '    let listener = hyotan_websocket_listener(bind_address).await?;')
# iOS reclaims a suspended app's listening socket. axum then retries accept
# forever, so the server stays up but refuses every connection. On iOS the
# acceptor therefore serves whichever listener the trusted bootstrap installed
# last; a replacement stops accepting on the old socket only.
websocket_serve = '''    let server = axum::serve(
        listener,
        router.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        shutdown_token.cancelled().await;
    });
    Ok(tokio::spawn(async move {
        if let Err(err) = server.await {
            error!("websocket acceptor failed: {err}");
        }
        info!("websocket acceptor shutting down");
    }))
}
'''
if text.count(websocket_serve) != 1:
    raise RuntimeError('Unexpected upstream WebSocket acceptor')
websocket_body = websocket_serve.removesuffix('}\n')
text = text.replace(websocket_serve, '''    #[cfg(target_os = "ios")]
    return Ok(hyotan_serve_replaceable(listener, router, shutdown_token));
    #[cfg(not(target_os = "ios"))]
    {
''' + websocket_body + '''    }
}
''')
text += '''

#[cfg(target_os = "ios")]
static HYOTAN_WEBSOCKET_LISTENER: std::sync::OnceLock<std::sync::Mutex<Option<std::net::TcpListener>>> = std::sync::OnceLock::new();

/// Trusted bootstrap only: transfers the already bound loopback listener.
/// The same socket remains reserved until the real transport takes ownership.
#[cfg(target_os = "ios")]
pub fn hyotan_install_websocket_listener(listener: std::net::TcpListener) -> IoResult<()> {
    let address = listener.local_addr()?;
    if !address.ip().is_loopback() || address.port() == 0 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "bound loopback listener required"));
    }
    listener.set_nonblocking(true)?;
    HYOTAN_WEBSOCKET_LISTENER.set(std::sync::Mutex::new(Some(listener)))
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::AlreadyExists, "WebSocket listener already installed"))
}

async fn hyotan_websocket_listener(bind_address: SocketAddr) -> IoResult<TcpListener> {
    #[cfg(target_os = "ios")]
    if let Some(slot) = HYOTAN_WEBSOCKET_LISTENER.get() {
        let mut owned = slot.lock().map_err(|_| std::io::Error::other("WebSocket listener lock unavailable"))?;
        let listener = owned.as_ref().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::AlreadyExists, "WebSocket listener already consumed"))?;
        if listener.local_addr()? != bind_address {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "WebSocket listener address mismatch"));
        }
        // from_std registers this exact socket in the running Tokio reactor.
        return TcpListener::from_std(owned.take().expect("checked owned listener"));
    }
    TcpListener::bind(bind_address).await
}

#[cfg(target_os = "ios")]
static HYOTAN_WEBSOCKET_REPLACEMENT: std::sync::Mutex<Option<mpsc::UnboundedSender<std::net::TcpListener>>> = std::sync::Mutex::new(None);

/// Trusted bootstrap only: moves the running acceptor to a newly bound loopback
/// listener. Open WebSocket connections are not affected.
#[cfg(target_os = "ios")]
pub fn hyotan_replace_websocket_listener(listener: std::net::TcpListener) -> IoResult<()> {
    let address = listener.local_addr()?;
    if !address.ip().is_loopback() || address.port() == 0 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "bound loopback listener required"));
    }
    listener.set_nonblocking(true)?;
    let sender = HYOTAN_WEBSOCKET_REPLACEMENT.lock().map_err(|_| std::io::Error::other("WebSocket listener lock unavailable"))?;
    sender.as_ref().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotConnected, "WebSocket acceptor not running"))?
        .send(listener).map_err(|_| std::io::Error::new(std::io::ErrorKind::NotConnected, "WebSocket acceptor stopped"))
}

#[cfg(target_os = "ios")]
fn hyotan_serve_replaceable(listener: TcpListener, router: Router, shutdown_token: CancellationToken) -> JoinHandle<()> {
    let (replacement_tx, mut replacements) = mpsc::unbounded_channel::<std::net::TcpListener>();
    if let Ok(mut slot) = HYOTAN_WEBSOCKET_REPLACEMENT.lock() { *slot = Some(replacement_tx); }
    tokio::spawn(async move {
        let mut listener = Some(listener);
        let mut serving = Vec::<JoinHandle<()>>::new();
        while let Some(current) = listener.take() {
            let replaced = CancellationToken::new();
            let stop = replaced.clone();
            let shutdown = shutdown_token.clone();
            let server = axum::serve(
                current,
                router.clone().into_make_service_with_connect_info::<SocketAddr>(),
            )
            .with_graceful_shutdown(async move {
                tokio::select! {
                    _ = shutdown.cancelled() => {}
                    _ = stop.cancelled() => {}
                }
            });
            serving.retain(|task| !task.is_finished());
            serving.push(tokio::spawn(async move {
                if let Err(err) = server.await {
                    error!("websocket acceptor failed: {err}");
                }
            }));
            while listener.is_none() {
                tokio::select! {
                    _ = shutdown_token.cancelled() => break,
                    next = replacements.recv() => match next {
                        Some(next) => match TcpListener::from_std(next) {
                            Ok(next) => {
                                replaced.cancel();
                                info!("app-server websocket listening on ws://{}", next.local_addr().map(|a| a.to_string()).unwrap_or_default());
                                listener = Some(next);
                            }
                            Err(err) => error!("websocket listener replacement failed: {err}"),
                        },
                        None => break,
                    },
                }
            }
        }
        if let Ok(mut slot) = HYOTAN_WEBSOCKET_REPLACEMENT.lock() { *slot = None; }
        for task in serving {
            let _ = task.await;
        }
        info!("websocket acceptor shutting down");
    })
}
'''
write(websocket_path, text)
# Keep the root crate dependency graph unchanged: export through AppServer.
for relative, export in [
    ('codex-rs/app-server-transport/src/transport/mod.rs', 'websocket'),
    ('codex-rs/app-server-transport/src/lib.rs', 'transport'),
    ('codex-rs/app-server/src/lib.rs', 'codex_app_server_transport'),
]:
    text = original(relative)
    text += f'\n#[cfg(target_os = "ios")]\npub use {export}::hyotan_install_websocket_listener;\n'
    text += f'\n#[cfg(target_os = "ios")]\npub use {export}::hyotan_replace_websocket_listener;\n'
    write(relative, text)

# dirs-sys uses option-ext only in XDG code, which is not compiled on Apple OSes.
# Restrict that dependency rather than copying any MPL implementation.
import os
cargo_home = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
found = list((cargo_home / 'registry/src').glob('*/dirs-sys-0.5.0'))
if len(found) != 1:
    archive = ROOT / '.build/dirs-sys-0.5.0.crate'
    archive.parent.mkdir(exist_ok=True)
    if not archive.exists():
        archive.write_bytes(fetch('https://static.crates.io/crates/dirs-sys/dirs-sys-0.5.0.crate'))
    if hashlib.sha256(archive.read_bytes()).hexdigest() != 'e01a3366d27ee9890022452ee61b2b63a67e6f13f58900b651ff5665f0bb1fab':
        raise RuntimeError('dirs-sys archive checksum mismatch')
    extracted = ROOT / '.build/dirs-upstream'
    with tarfile.open(archive) as handle:
        handle.extractall(extracted, filter='data')
    found = [extracted / 'dirs-sys-0.5.0']
target = ROOT / 'Vendor/dirs-sys'
shutil.copytree(found[0], target, dirs_exist_ok=True)
manifest = (target / 'Cargo.toml').read_text().replace('[dependencies.option-ext]', '[target.\'cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))\'.dependencies.option-ext]')
(target / 'Cargo.toml').write_text(manifest)
lib = target / 'src/lib.rs'
lib.write_text(lib.read_text().replace('extern crate option_ext;', '#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]\nextern crate option_ext;'))
print('Prepared iOS file search, Apple audio duration, bounded SQLite/feedback, image header estimates, trusted filesystem installation, and Apple-only dirs-sys dependency selection.')
# Separate reproducible phase; legacy media remains unchanged until trusted install.
subprocess.run([__import__('sys').executable, str(ROOT / 'Scripts/prepare-turn-lease.py')], check=True)
# Model handlers compose after the shared turn/issuer generation. No grant installation.
subprocess.run([__import__('sys').executable, str(ROOT / 'Scripts/prepare-model-file-operations.py')], check=True)
# Role settings are immutable parent-capability snapshots, after turn/model hooks.
subprocess.run([__import__('sys').executable, str(ROOT / 'Scripts/prepare-role-reads.py')], check=True)

# Host snapshots compose after captured context and role hooks.
subprocess.run([__import__('sys').executable, str(ROOT / 'Scripts/prepare-host-skills.py')], check=True)
