#[path = "../../NativeCodex/ios/turn_lease.rs"]
mod route;
use codex_file_system::ExecutorFileSystem;
use codex_protocol::{
    models::{ImageDetail, LocalImagePreparation, ResponseInputItem},
    user_input::UserInput,
};
use hyotan_appserver_operation_harness::CapabilityFileSystem;
use hyotan_operation_harness::{Access, Harness, Scope};
use hyotan_turn_lease::CapturedLease;
use std::sync::Arc;

#[test]
fn actual_factory_captured_reader_canary_revoke_next_turn_and_bytes() {
    let temp =
        std::env::temp_dir().join(format!("hyotan-turn-lease-fixture-{}", std::process::id()));
    std::fs::create_dir_all(temp.join("workspace")).unwrap();
    let workspace = temp.join("workspace");
    let private = temp.join("private.wav");
    std::fs::write(&private, b"PRIVATE_CANARY_NEVER_RETURN").unwrap();
    std::fs::write(
        workspace.join("日本語.wav"),
        include_bytes!("fixtures/sample.wav"),
    )
    .unwrap();
    std::fs::write(
        workspace.join("image.png"),
        include_bytes!("fixtures/pixel.png"),
    )
    .unwrap();
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&private, workspace.join("link.wav")).unwrap();
    }
    std::fs::hard_link(&private, workspace.join("hard.wav")).unwrap();
    let legacy = route::CapturedTurnLease::capture("synthetic-thread", "legacy-before-install");
    let legacy_media = futures::executor::block_on(route::prepare_local_media(
        &legacy,
        vec![UserInput::LocalAudio {
            path: workspace.join("日本語.wav"),
        }],
    ));
    assert!(
        serde_json::to_string(&legacy_media)
            .unwrap()
            .contains("data:audio/wav")
    );
    let root = workspace.clone();
    route::install(Arc::new(move |request| {
        let thread = request.thread.as_str();
        let turn = request.turn.as_str();
        if thread != "synthetic-thread" || !matches!(turn, "a" | "b") {
            return Err(hyotan_turn_lease::denied());
        }
        let generation = if turn == "a" { 1 } else { 2 };
        let scope = Scope {
            owner: format!("{thread}/{turn}"),
            generation,
        };
        let harness = Arc::new(Harness::default());
        let cap = harness.grant(&root, scope.clone(), Access::ReadOnly)?;
        let fs: Arc<dyn ExecutorFileSystem> = Arc::new(CapabilityFileSystem::new_protected(
            harness.clone(),
            cap,
            scope.clone(),
            root.clone(),
            request.sandbox.clone(),
        )?);
        Ok(Arc::new(CapturedLease::new(
            route::Identity {
                thread: thread.into(),
                turn: turn.into(),
                generation,
            },
            fs,
            Arc::new(move || harness.revoke(cap, &scope)),
        )?))
    }))
    .unwrap_or_else(|_| panic!("install once"));
    let capture = |turn: &str| {
        use codex_file_system::*;
        use codex_protocol::permissions::{FileSystemAccessMode, NetworkSandboxPolicy};
        let cwd = codex_utils_path_uri::PathUri::from_host_native_path(&workspace).unwrap();
        let mut sandbox = FileSystemSandboxContext::from_permission_profile_with_cwd(
            codex_protocol::models::PermissionProfile::Disabled,
            cwd.clone(),
        );
        sandbox.permissions = ExecPermissionProfile::Managed {
            file_system: ExecManagedFileSystemPermissions::Restricted {
                entries: vec![ExecFileSystemSandboxEntry {
                    path: ExecFileSystemPath::Path { path: cwd },
                    access: FileSystemAccessMode::Read,
                    missing_path_behavior: None,
                }],
                glob_scan_max_depth: None,
            },
            network: NetworkSandboxPolicy::Restricted,
        };
        route::CapturedTurnLease::capture_resolved(Some(route::CaptureRequest {
            thread: "synthetic-thread".into(),
            turn: turn.into(),
            sandbox,
            environment_id: "local".into(),
            session_source: codex_protocol::protocol::SessionSource::Exec,
            parent_thread: None,
        }))
    };
    assert!(
        route::CapturedTurnLease::capture("synthetic-thread", "a")
            .check()
            .is_err()
    );
    let a = capture("a");
    let retained = a.clone();
    let prepare = |lease: &route::CapturedTurnLease, path: std::path::PathBuf| {
        futures::executor::block_on(route::prepare_local_media(
            lease,
            vec![UserInput::LocalAudio { path }],
        ))
    };
    let valid = serde_json::to_string(&prepare(&a, workspace.join("日本語.wav"))).unwrap();
    assert!(valid.contains(
        "data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA=="
    ));
    for path in [
        private.clone(),
        workspace.join("link.wav"),
        workspace.join("hard.wav"),
        workspace.join("../private.wav"),
    ] {
        let result = serde_json::to_string(&prepare(&a, path)).unwrap();
        assert!(result.contains("trusted application workflow"));
        assert!(!result.contains("PRIVATE_CANARY"));
        assert!(!result.contains("private.wav"));
        assert!(!result.contains(&temp.to_string_lossy().to_string()));
    }
    let image = futures::executor::block_on(route::prepare_local_media(
        &a,
        vec![UserInput::LocalImage {
            path: workspace.join("image.png"),
            detail: Some(ImageDetail::Original),
        }],
    ));
    let image = serde_json::to_string(&image).unwrap();
    assert!(image.contains("data:application/octet-stream;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="));
    assert!(image.contains("original"));
    let cached = a.filesystem().unwrap().unwrap();
    a.revoke().unwrap();
    let uri =
        codex_utils_path_uri::PathUri::from_host_native_path(workspace.join("日本語.wav")).unwrap();
    assert!(futures::executor::block_on(cached.read_file(&uri, Default::default(), None)).is_err());
    assert!(
        serde_json::to_string(&prepare(&retained, workspace.join("日本語.wav")))
            .unwrap()
            .contains("read denied")
    );
    let b = capture("b");
    assert!(
        serde_json::to_string(&prepare(&b, workspace.join("日本語.wav")))
            .unwrap()
            .contains("data:audio/wav")
    );
    let missing = capture("unknown");
    assert!(
        serde_json::to_string(&prepare(&missing, workspace.join("日本語.wav")))
            .unwrap()
            .contains("read denied")
    );
    assert!(
        !b.sanitize("/synthetic-private/secret".into())
            .contains("secret")
    );
    drop(route::LeaseGuard(b.clone()));
    assert!(
        serde_json::to_string(&prepare(&b, workspace.join("日本語.wav")))
            .unwrap()
            .contains("read denied")
    );
    assert_eq!(
        std::fs::read(&private).unwrap(),
        b"PRIVATE_CANARY_NEVER_RETURN"
    );
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn protocol_callback_failure_sanitized_without_native_reopen() {
    let result = ResponseInputItem::from_user_input_with_local_media_reader(
        vec![UserInput::LocalAudio {
            path: "/synthetic-private/secret.wav".into(),
        }],
        LocalImagePreparation::Defer,
        |_| Err(std::io::Error::other("sensitive internal error")),
    );
    let json = serde_json::to_string(&result).unwrap();
    assert!(json.contains("read denied"));
    assert!(!json.contains("secret.wav"));
    assert!(!json.contains("sensitive"));
}

#[test]
fn explicit_and_drop_cleanup_failure_is_observable_and_never_confirms_success() {
    let root = std::env::temp_dir().join(format!("hyotan-failed-cleanup-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let harness = Arc::new(Harness::default());
    let scope = Scope {
        owner: "trusted-failure-test".into(),
        generation: 99,
    };
    let cap = harness
        .grant(&root, scope.clone(), Access::ReadOnly)
        .unwrap();
    let fs: Arc<dyn ExecutorFileSystem> = Arc::new(
        CapabilityFileSystem::new(harness.clone(), cap, scope.clone(), root.clone()).unwrap(),
    );
    let failed = route::CapturedTurnLease::Bound(Arc::new(
        CapturedLease::new(
            route::Identity {
                thread: "t-failed".into(),
                turn: "a".into(),
                generation: 99,
            },
            fs,
            Arc::new(|| Err(std::io::Error::other("private internal details"))),
        )
        .unwrap(),
    ));
    let before = route::cleanup_failure_count();
    assert_eq!(
        failed.revoke().unwrap_err().to_string(),
        hyotan_turn_lease::DENIAL
    );
    assert!(failed.check().is_err());
    assert!(route::cleanup_failure_count() > before);
    let before = route::cleanup_failure_count();
    drop(route::LeaseGuard(failed.clone()));
    assert!(route::cleanup_failure_count() > before);
    assert!(failed.filesystem().is_err());
    // Callback failure does not prove cached raw FS authority was invalidated.
    // Trusted host cleanup is still necessary and explicitly confirmed here.
    harness.revoke(cap, &scope).unwrap();
    std::fs::remove_dir(root).unwrap();
}
