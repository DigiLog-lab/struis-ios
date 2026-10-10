#!/usr/bin/env python3
"""Verify pinned listener generation and exact extracted hooks on real Linux TCP/Tokio.

This does not run AppServer or produce an Apple SDK/link/runtime result.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('memory_check', HERE / 'check-codex-memory-preparation.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
WEBSOCKET = 'codex-rs/app-server-transport/src/transport/websocket.rs'
EXPORTS = {
    'codex-rs/app-server-transport/src/transport/mod.rs': 'websocket',
    'codex-rs/app-server-transport/src/lib.rs': 'transport',
    'codex-rs/app-server/src/lib.rs': 'codex_app_server_transport',
}
BIND = '    let listener = TcpListener::bind(bind_address).await?;'
REPLACEMENT = '    let listener = hyotan_websocket_listener(bind_address).await?;'
MARKER = '\n\n#[cfg(target_os = "ios")]\nstatic HYOTAN_WEBSOCKET_LISTENER:'


def extract_function(text, name):
    start = text.index('fn ' + name + '(')
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]


def main():
    with tempfile.TemporaryDirectory(prefix='hyotan-owned-port-') as temporary:
        temporary = Path(temporary)
        root = temporary / 'NativeRuntime'
        scripts = root / 'Scripts'; scripts.mkdir(parents=True)
        for name in ('prepare-codex.py', 'prepare-turn-lease.py',
                     'prepare-model-file-operations.py', 'prepare-role-reads.py', 'fetch.py'):
            shutil.copyfile(HERE / name, scripts / name)
        ios = root / 'NativeCodex/ios'
        ios.mkdir(parents=True)
        for name in ('file_search.rs', 'turn_lease.rs', 'turn_lease_appserver_tests.rs',
                     'model_operations.rs', 'role_snapshot.rs', 'role_snapshot_tests.rs'):
            shutil.copyfile(memory.ROOT / 'NativeCodex/ios' / name, ios / name)
        integration = root / 'TurnLeaseIntegration'
        integration.mkdir(parents=True)
        shutil.copyfile(memory.ROOT / 'TurnLeaseIntegration/appserver.Cargo.lock',
                        integration / 'appserver.Cargo.lock')
        source = root / 'Vendor/codex-source'; source.parent.mkdir(parents=True)
        memory.run(['git', 'clone', '--shared', '--no-checkout', memory.SOURCE, source])
        memory.run(['git', '-C', source, 'checkout', memory.PIN, '--', 'codex-rs/core/src', 'codex-rs/file-search', 'codex-rs/utils/audio', memory.SQLITE, memory.FEEDBACK, memory.HISTORY, 'codex-rs/exec-server/src/environment.rs', 'codex-rs/exec-server/src/lib.rs', WEBSOCKET, *EXPORTS])
        env = dict(os.environ)
        cache = temporary / 'cargo-cache'; env['CARGO_HOME'] = str(cache)
        cached = Path(os.environ.get('CARGO_HOME', Path.home() / '.cargo'))
        choices = list((cached / 'registry/src').glob('*/dirs-sys-0.5.0'))
        upstream = memory.ROOT / '.build/dirs-upstream/dirs-sys-0.5.0'
        if not upstream.is_dir():
            memory.require(len(choices) == 1, 'Original dirs-sys cache required')
            upstream = choices[0]
        shutil.copytree(upstream, cache / 'registry/src/check/dirs-sys-0.5.0')
        memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=env)
        first = memory.snapshot(source)
        memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=env)
        memory.require(first == memory.snapshot(source), 'Complete generated source hashes differ on second run')
        generated = (source / WEBSOCKET).read_text().removeprefix(memory.HEADER)
        original, hook = generated.split(MARKER, 1)
        hook = MARKER + hook
        memory.require(original.rstrip().replace(REPLACEMENT, BIND) == memory.original(WEBSOCKET).rstrip(), 'WebSocket changes exceed one listener factory and appended hook')
        memory.require(generated.count(REPLACEMENT) == 1, 'Actual acceptor must consume owned listener')
        for relative, export in EXPORTS.items():
            addition = f'\n#[cfg(target_os = "ios")]\npub use {export}::hyotan_install_websocket_listener;\n'
            if relative == 'codex-rs/app-server/src/lib.rs':
                addition += '\n#[cfg(target_os = "ios")]\npub use codex_core::hyotan_turn_lease;\n'
            result = (source / relative).read_text().removeprefix(memory.HEADER)
            memory.require(result.removesuffix(addition) == memory.original(relative), 'Export changes upstream outside cfg-iOS addition')
        native = (memory.ROOT / 'NativeCodex/src/lib.rs').read_text()
        reserve = extract_function(native, 'reserve_websocket_listener')
        memory.require('TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))' in reserve, 'Native bootstrap must own actual socket')
        worker = (memory.ROOT / 'Worker/RuntimeWorker.swift').read_text()
        memory.require('hyotan_codex_start(0, $0)' in worker and 'let port = hyotan_codex_port()' in worker and 'guard port != 0' in worker, 'Trusted reply must use actual bound port')
        memory.require('UInt16.random' not in worker, 'Random port selection remains')
        memory.require('BOUND_PORT.store(bind_address.port(), Ordering::Release)' in native and 'BOUND_PORT.load(Ordering::Acquire)' in native, 'Atomic actual port publication missing')
        memory.require('pub extern "C" fn hyotan_codex_port() -> u16' in native, 'Trusted port FFI missing')
        print('PASS pinned generation twice: all source hashes identical; acceptor factory and transport exports and trusted cfg-iOS lease bridge only')
        print('PASS trusted native reservation, actual-port atomic FFI and Swift startup reply wiring')

        # Compile EXACT extracted hook functions. Only their platform cfg selector
        # is mapped to a probe feature; std/Tokio implementations are real.
        probe = temporary / 'probe'; (probe / 'src').mkdir(parents=True)
        lock = tomllib.loads((memory.ROOT / 'NativeCodex/Cargo.lock').read_text())
        tokio = next(package['version'] for package in lock['package'] if package['name'] == 'tokio')
        (probe / 'Cargo.toml').write_text(f'''[package]
name="hyotan-owned-listener-probe"
version="0.0.0"
edition="2024"
[features]
ios-hook=[]
[dependencies]
tokio={{version="={tokio}", features=["rt", "net", "io-util", "macros", "time"]}}
''')
        imports = '''use std::net::{SocketAddr,Ipv4Addr};
use std::io::Result as IoResult;
use tokio::net::{TcpListener,TcpStream};
use tokio::io::{AsyncReadExt,AsyncWriteExt};
use std::os::fd::AsRawFd;
use crate as codex_app_server;
'''
        tests = r'''
#[tokio::main(flavor="current_thread")]
async fn main() -> IoResult<()> {
 fn assert_send<T: Send>(_: T) {}
 assert_send(hyotan_websocket_listener(SocketAddr::from((Ipv4Addr::LOCALHOST,0))));
 let mode=std::env::args().nth(1).unwrap();
 if mode=="uninstalled" {
   let listener=hyotan_websocket_listener(SocketAddr::from((Ipv4Addr::LOCALHOST,0))).await?;
   assert!(listener.local_addr()?.port()>0);
   assert!(std::net::TcpListener::bind(listener.local_addr()?).is_err());
   println!("PASS real Tokio uninstalled factory binds ephemeral listener");return Ok(());
 }
 #[cfg(feature="ios-hook")]
 {
   let address=reserve_websocket_listener(0)?;
   assert_ne!(address.port(),0);
   let original_fd=HYOTAN_WEBSOCKET_LISTENER.get().unwrap().lock().unwrap().as_ref().unwrap().as_raw_fd();
   let rival=std::net::TcpListener::bind(address).unwrap_err();
   assert_eq!(rival.kind(),std::io::ErrorKind::AddrInUse);
   let mismatch=hyotan_websocket_listener(SocketAddr::from((Ipv4Addr::LOCALHOST,0))).await.unwrap_err();
   assert_eq!(mismatch.kind(),std::io::ErrorKind::InvalidInput);
   assert!(std::net::TcpListener::bind(address).is_err());
   let listener=hyotan_websocket_listener(address).await?;
   assert_eq!(listener.as_raw_fd(),original_fd);
   assert_eq!(listener.local_addr()?,address);
   assert!(std::net::TcpListener::bind(address).is_err());
   let server=async { let (mut socket,_)=listener.accept().await?;let mut bytes=[0u8;5];socket.read_exact(&mut bytes).await?;assert_eq!(&bytes,b"owned");socket.write_all(b"same-fd").await?;Ok::<_,std::io::Error>(()) };
   let client=async { let mut socket=TcpStream::connect(address).await?;socket.write_all(b"owned").await?;let mut bytes=[0u8;7];socket.read_exact(&mut bytes).await?;assert_eq!(&bytes,b"same-fd");Ok::<_,std::io::Error>(()) };
   tokio::time::timeout(std::time::Duration::from_secs(5),async {tokio::try_join!(server,client)}).await??;
   let again=hyotan_websocket_listener(address).await.unwrap_err();assert_eq!(again.kind(),std::io::ErrorKind::AlreadyExists);
   let extra=std::net::TcpListener::bind((Ipv4Addr::LOCALHOST,0))?;
   assert_eq!(hyotan_install_websocket_listener(extra).unwrap_err().kind(),std::io::ErrorKind::AlreadyExists);
   let standard=listener.into_std()?;
   assert_eq!(standard.as_raw_fd(),original_fd);
   assert_eq!(standard.local_addr()?,address);
   assert_eq!(standard.accept().unwrap_err().kind(),std::io::ErrorKind::WouldBlock);
   println!("PASS actual listener port0 ownership, rival bind denied, exact FD/local address retained, real TCP exchange, nonblocking conversion, mismatch/second-install/second-consume fail closed");
 }
 Ok(())
}
'''
        (probe / 'src/main.rs').write_text(imports + hook.replace('target_os = "ios"', 'feature = "ios-hook"') + '\n#[cfg(feature="ios-hook")]\n' + reserve + '\n' + tests)
        cargo = shutil.which('cargo'); memory.require(cargo is not None, 'cargo required for actual Tokio probe')
        for feature, mode in [(True,'installed'),(True,'uninstalled'),(False,'uninstalled')]:
            command = [cargo,'run','--offline','--manifest-path',probe / 'Cargo.toml']
            if feature: command += ['--features','ios-hook']
            command += ['--',mode]
            output = memory.run(command)
            print(output.strip())
        print('LIMIT Linux exact-hook/socket verification only; actual Apple AppServer/PDF/cold-resume and worker restart remain for Cloud')


if __name__ == '__main__':
    main()
