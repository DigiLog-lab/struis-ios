//! Dedicated filtered AppServer test process only; no product issuer installation.
use super::*;
use base64::Engine as _;
use codex_core::hyotan_turn_lease as lease_route;
use codex_file_system::*;
use codex_utils_path_uri::PathUri;
use hyotan_appserver_operation_harness::CapabilityFileSystem;
use hyotan_operation_harness::{Access, Harness, Scope};
use hyotan_turn_lease::CapturedLease;
use std::assert_eq;
use std::sync::{
    Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use tokio::sync::Notify;

struct PendingReadFs {
    inner: CapabilityFileSystem,
    block_read: AtomicBool,
    entered: Arc<Notify>,
    release: Arc<Notify>,
}
impl ExecutorFileSystem for PendingReadFs {
    fn canonicalize<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, PathUri> {
        self.inner.canonicalize(path, sandbox)
    }
    fn read_file<'a>(
        &'a self,
        path: &'a PathUri,
        options: ReadFileOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            if self.block_read.swap(false, Ordering::AcqRel) {
                self.entered.notify_one();
                self.release.notified().await;
            }
            let result = self.inner.read_file(path, options, sandbox).await;
            eprintln!("HYOTAN_ISSUER_READ {}", if result.is_ok() { 0 } else { 1 });
            result
        })
    }
    fn read_file_stream<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileSystemReadStream> {
        self.inner.read_file_stream(path, sandbox)
    }
    fn write_file<'a>(
        &'a self,
        path: &'a PathUri,
        contents: Vec<u8>,
        options: WriteFileOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        self.inner.write_file(path, contents, options, sandbox)
    }
    fn create_directory<'a>(
        &'a self,
        path: &'a PathUri,
        options: CreateDirectoryOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        self.inner.create_directory(path, options, sandbox)
    }
    fn get_metadata<'a>(
        &'a self,
        path: &'a PathUri,
        options: GetMetadataOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, FileMetadata> {
        self.inner.get_metadata(path, options, sandbox)
    }
    fn read_directory<'a>(
        &'a self,
        path: &'a PathUri,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<ReadDirectoryEntry>> {
        self.inner.read_directory(path, sandbox)
    }
    fn walk<'a>(
        &'a self,
        path: &'a PathUri,
        options: WalkOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, WalkOutcome> {
        self.inner.walk(path, options, sandbox)
    }
    fn remove<'a>(
        &'a self,
        path: &'a PathUri,
        options: RemoveOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        self.inner.remove(path, options, sandbox)
    }
    fn copy<'a>(
        &'a self,
        source: &'a PathUri,
        destination: &'a PathUri,
        options: CopyOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, ()> {
        self.inner.copy(source, destination, options, sandbox)
    }
}

struct Permit {
    generation: u64,
    block: bool,
    fail_revoke: bool,
}
struct Issuer {
    factory_calls: AtomicUsize,
    rejection_stage: AtomicUsize,
    pending: Mutex<BTreeMap<(String, String), Permit>>,
    captured: Mutex<Vec<Arc<lease_route::TurnLease>>>,
    entered: Arc<Notify>,
    release: Arc<Notify>,
    root: std::path::PathBuf,
}
impl Issuer {
    fn admission(
        self: &Arc<Self>,
        thread: String,
        permit: Permit,
    ) -> Arc<lease_route::SubmissionAdmission> {
        let issuer = self.clone();
        let once = Mutex::new(Some(permit));
        Arc::new(move |actual_thread, submission| {
            if actual_thread != thread || submission.is_empty() {
                issuer.rejection_stage.store(3, Ordering::Relaxed);
                return Err(hyotan_turn_lease::denied());
            }
            let permit = once
                .lock()
                .unwrap()
                .take()
                .ok_or_else(hyotan_turn_lease::denied)?;
            let mut pending = issuer.pending.lock().unwrap();
            if !pending.is_empty() {
                return Err(hyotan_turn_lease::denied());
            }
            pending.insert((actual_thread.to_owned(), submission.to_owned()), permit);
            Ok(())
        })
    }
}
async fn completion(
    h: &mut TracingHarness,
    id: &str,
) -> codex_app_server_protocol::TurnCompletedNotification {
    if let Some(position) = h.completed.iter().position(|n| n.turn.id == id) {
        return h.completed.remove(position).expect("recorded terminal");
    }
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            let envelope = h.outgoing_rx.recv().await.expect("channel");
            if let crate::outgoing_message::OutgoingEnvelope::ToConnection {
                connection_id,
                message,
                ..
            } = envelope
            {
                if connection_id != TEST_CONNECTION_ID {
                    continue;
                }
                if let crate::outgoing_message::OutgoingMessage::AppServerNotification(n) = message
                {
                    if let codex_app_server_protocol::ServerNotification::TurnCompleted(n) =
                        n.notification
                    {
                        if n.turn.id == id {
                            return n;
                        }
                    }
                }
            }
        }
    })
    .await
    .expect("terminal notification deadline")
}
async fn protected_harness(
    root: &Path,
) -> Result<(TracingHarness, core_test_support::responses::ResponseMock)> {
    let server = wiremock::MockServer::start().await;
    let image_args = serde_json::to_string(&serde_json::json!({"path":root.join("日本語.png")}))?;
    let body = core_test_support::responses::sse(vec![
        core_test_support::responses::ev_response_created("hyotan-image"),
        core_test_support::responses::ev_function_call(
            "hyotan-image-call",
            "view_image",
            &image_args,
        ),
        core_test_support::responses::ev_completed("hyotan-image"),
    ]);
    let done = core_test_support::responses::sse(vec![
        core_test_support::responses::ev_assistant_message("hyotan-done", "Done"),
        core_test_support::responses::ev_completed("hyotan-done"),
    ]);
    let requests = core_test_support::responses::mount_sse_sequence(
        &server,
        vec![body, done.clone(), done.clone(), done],
    )
    .await;
    let home = TempDir::new()?;
    let _ = build_test_config(home.path(), &server.uri()).await?;
    let path = home.path().join("config.toml");
    let existing = std::fs::read_to_string(&path)?.replace("sandbox_mode = \"read-only\"\n", "");
    // Exact path policy, independent of model cwd, excludes the Codex home.
    let key = serde_json::to_string(&root.to_string_lossy())?;
    std::fs::write(
        &path,
        format!(
            "default_permissions = \"hyotan-read\"\n{existing}\n[permissions.hyotan-read.filesystem]\n{key} = \"read\"\n"
        ),
    )?;
    // Persist trusted mock metadata: thread/start reloads the Config, so an
    // in-memory override alone would be lost before actual Session creation.
    let mut catalog = codex_models_manager::bundled_models_response()?;
    let mut model = catalog
        .models
        .iter()
        .find(|m| m.slug == "gpt-5.5")
        .expect("pinned audio-capable test model template")
        .clone();
    model.slug = "mock-model".into();
    model
        .input_modalities
        .push(codex_protocol::openai_models::InputModality::Audio);
    catalog.models = vec![model];
    let catalog_path = home.path().join("mock-audio-models.json");
    std::fs::write(&catalog_path, serde_json::to_vec(&catalog)?)?;
    let catalog_key = serde_json::to_string(&catalog_path.to_string_lossy())?;
    let config_text = std::fs::read_to_string(&path)?;
    std::fs::write(
        &path,
        format!("model_catalog_json = {catalog_key}\n{config_text}"),
    )?;
    let config = Arc::new(
        ConfigBuilder::default()
            .codex_home(home.path().to_owned())
            .build()
            .await?,
    );

    let executable = std::env::current_exe()?;
    let sandbox_alias = home.path().join("codex-linux-sandbox");
    std::os::unix::fs::symlink(&executable, &sandbox_alias)?;
    let runtime_paths =
        codex_exec_server::ExecServerRuntimePaths::new(executable, Some(sandbox_alias))?;
    let environment_manager =
        Arc::new(EnvironmentManager::create_for_tests_with_local(None, runtime_paths).await);
    let (processor, outgoing_rx) =
        build_test_processor_with_environment(config, environment_manager).await;
    let tracing = init_test_tracing();
    let mut h = TracingHarness {
        _server: server,
        _codex_home: home,
        processor,
        outgoing_rx,
        session: Arc::new(ConnectionSessionState::new()),
        tracing,
        completed: Default::default(),
    };
    let _: InitializeResponse = h
        .request(
            ClientRequest::Initialize {
                request_id: RequestId::Integer(1),
                params: InitializeParams {
                    client_info: ClientInfo {
                        name: "hyotan-issuer-test".into(),
                        title: None,
                        version: "1".into(),
                    },
                    capabilities: Some(InitializeCapabilities {
                        experimental_api: true,
                        ..Default::default()
                    }),
                },
            },
            None,
        )
        .await;
    // Mirror real AppServer lib.rs transport finalization after process_request.
    h.processor
        .connection_initialized(TEST_CONNECTION_ID, h.session.request_attestation())
        .await;
    Ok((h, requests))
}
async fn start(
    h: &mut TracingHarness,
    issuer: &Arc<Issuer>,
    thread: &str,
    request_id: i64,
    permit: Permit,
) -> TurnStartResponse {
    let block = permit.block;
    let admission = issuer.admission(thread.to_owned(), permit);
    lease_route::with_submission_admission(
        admission,
        h.request(
            ClientRequest::TurnStart {
                request_id: RequestId::Integer(request_id),
                params: TurnStartParams {
                    thread_id: thread.into(),
                    input: if block {
                        vec![UserInput::Text {
                            text: "Inspect the workspace image".into(),
                            text_elements: Vec::new(),
                        }]
                    } else {
                        vec![UserInput::LocalAudio {
                            path: issuer.root.join("日本語.wav"),
                        }]
                    },
                    cwd: Some(issuer.root.clone()),
                    ..Default::default()
                },
            },
            None,
        ),
    )
    .await
}

fn run_issuer_test(future: impl Future<Output = Result<()>> + Send + 'static) -> Result<()> {
    // Real listeners exercise pinned block_in_place cache operations, so use
    // the real AppServer runtime model instead of the tracing-only runtime.
    let handle = std::thread::Builder::new()
        .name("hyotan-captured-turn-rpc".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_stack_size(8 * 1024 * 1024)
                .enable_all()
                .build()?;
            runtime.block_on(Box::pin(future))
        })?;
    handle
        .join()
        .map_err(|_| anyhow::anyhow!("issuer test thread panicked"))?
}

#[test]
#[serial(app_server_tracing)]
#[ignore = "trusted issuer installs once; dedicated filtered process only"]
fn hyotan_captured_turn_actual_rpc_ingress_interrupt_completion_and_failure() -> Result<()> {
    run_issuer_test(async {
        let fixture = TempDir::new()?;
        let root = fixture.path().join("workspace");
        std::fs::create_dir(&root)?;
        let private = fixture.path().join("private-canary.wav");
        std::fs::write(&private, b"PRIVATE_CANARY")?;
        std::fs::write(root.join("日本語.wav"),b"RIFF\x26\0\0\0WAVEfmt \x10\0\0\0\x01\0\x01\0\x40\x1f\0\0\x80\x3e\0\0\x02\0\x10\0data\x02\0\0\0\0\0")?;
        std::fs::write(root.join("日本語.png"),base64::engine::general_purpose::STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")?)?;
        let issuer = Arc::new(Issuer {
            factory_calls: AtomicUsize::new(0),
            rejection_stage: AtomicUsize::new(0),
            pending: Mutex::new(BTreeMap::new()),
            captured: Mutex::new(Vec::new()),
            entered: Arc::new(Notify::new()),
            release: Arc::new(Notify::new()),
            root: root.clone(),
        });
        let captured_issuer = issuer.clone();
        lease_route::install(Arc::new(move |request| {
            captured_issuer
                .factory_calls
                .fetch_add(1, Ordering::Relaxed);
            if request.parent_thread.is_some()
                || !matches!(request.session_source, SessionSource::VSCode)
                || request.environment_id.is_empty()
            {
                captured_issuer.rejection_stage.store(1, Ordering::Relaxed);
                return Err(hyotan_turn_lease::denied());
            }
            let permit = captured_issuer
                .pending
                .lock()
                .unwrap()
                .remove(&(request.thread.clone(), request.turn.clone()))
                .ok_or_else(|| {
                    captured_issuer.rejection_stage.store(2, Ordering::Relaxed);
                    hyotan_turn_lease::denied()
                })?;
            let scope = Scope {
                owner: format!("trusted-test/{}", request.thread),
                generation: permit.generation,
            };
            let harness = Arc::new(Harness::default());
            let capability = harness.grant_from_owned_directory(
                std::fs::File::open(&captured_issuer.root)?,
                scope.clone(),
                Access::ReadOnly,
            )?;
            let fs: Arc<dyn ExecutorFileSystem> = Arc::new(PendingReadFs {
                inner: CapabilityFileSystem::new_protected(
                    harness.clone(),
                    capability,
                    scope.clone(),
                    captured_issuer.root.clone(),
                    request.sandbox.clone(),
                )?,
                block_read: AtomicBool::new(permit.block),
                entered: captured_issuer.entered.clone(),
                release: captured_issuer.release.clone(),
            });
            let lease = Arc::new(CapturedLease::new(
                lease_route::Identity {
                    thread: request.thread.clone(),
                    turn: request.turn.clone(),
                    generation: permit.generation,
                },
                fs,
                Arc::new(move || {
                    if permit.fail_revoke {
                        return Err(std::io::Error::other("synthetic private detail"));
                    }
                    harness.revoke(capability, &scope)
                }),
            )?);
            captured_issuer.captured.lock().unwrap().push(lease.clone());
            Ok(lease)
        }))
        .unwrap_or_else(|_| panic!("isolated test process requires uninstalled factory"));
        let (mut h, request_mock) = protected_harness(&root).await?;
        let thread_response: ThreadStartResponse = h
            .request(
                ClientRequest::ThreadStart {
                    request_id: RequestId::Integer(2),
                    params: ThreadStartParams {
                        ephemeral: Some(true),
                        cwd: Some(root.to_string_lossy().into_owned()),
                        ..Default::default()
                    },
                },
                None,
            )
            .await;
        read_thread_started_notification(&mut h.outgoing_rx).await;
        let thread = thread_response.thread.id;
        // Startup/default contexts never consume a future permit or issue a grant.
        assert!(issuer.pending.lock().unwrap().is_empty());
        assert!(issuer.captured.lock().unwrap().is_empty());
        let response = start(
            &mut h,
            &issuer,
            &thread,
            3,
            Permit {
                generation: 1,
                block: true,
                fail_revoke: false,
            },
        )
        .await;
        tokio::time::timeout(std::time::Duration::from_secs(5), issuer.entered.notified())
            .await
            .unwrap_or_else(|_|panic!("actual protected ingress deadline; factoryCalls={} rejectionStage={} pending={} captured={}",issuer.factory_calls.load(Ordering::Relaxed),issuer.rejection_stage.load(Ordering::Relaxed),issuer.pending.lock().unwrap().len(),issuer.captured.lock().unwrap().len()));
        let retained = issuer.captured.lock().unwrap()[0].clone();
        assert_eq!(retained.identity().turn, response.turn.id);
        let cached = retained.authority()?;
        let uri = PathUri::from_host_native_path(root.join("日本語.wav"))?;
        let _: codex_app_server_protocol::TurnInterruptResponse = h
            .request(
                ClientRequest::TurnInterrupt {
                    request_id: RequestId::Integer(4),
                    params: codex_app_server_protocol::TurnInterruptParams {
                        thread_id: thread.clone(),
                        turn_id: response.turn.id.clone(),
                    },
                },
                None,
            )
            .await;
        let done = completion(&mut h, &response.turn.id).await;
        assert_eq!(
            done.turn.status,
            codex_app_server_protocol::TurnStatus::Interrupted
        );
        assert!(retained.check().is_err());
        // Release the held test reader to prove retained authority is revoked too.
        issuer.release.notify_one();
        assert!(
            cached
                .read_file(&uri, Default::default(), None)
                .await
                .is_err()
        );
        let next = start(
            &mut h,
            &issuer,
            &thread,
            5,
            Permit {
                generation: 2,
                block: false,
                fail_revoke: false,
            },
        )
        .await;
        let done = completion(&mut h, &next.turn.id).await;
        assert_eq!(
            done.turn.status,
            codex_app_server_protocol::TurnStatus::Completed
        );
        assert!(issuer.captured.lock().unwrap()[1].check().is_err());
        assert!(!retained.matches(&thread, &next.turn.id));
        let authorized_audio = base64::engine::general_purpose::STANDARD
            .encode(std::fs::read(root.join("日本語.wav"))?);
        let authorized_requests = request_mock.requests();
        assert!(
            authorized_requests
                .iter()
                .any(|request| request.body_json().to_string().contains(&authorized_audio)),
            "actual model ingress must receive authorized bytes; requests={} denied={}",
            authorized_requests.len(),
            authorized_requests
                .iter()
                .filter(|r| r
                    .body_json()
                    .to_string()
                    .contains("trusted application workflow"))
                .count()
        );

        // An actual unadmitted RPC cannot consume another turn's permit or mint
        // authority merely by supplying this trusted workspace as its cwd.
        let unknown: TurnStartResponse = h
            .request(
                ClientRequest::TurnStart {
                    request_id: RequestId::Integer(7),
                    params: TurnStartParams {
                        thread_id: thread.clone(),
                        input: vec![UserInput::LocalAudio {
                            path: private.clone(),
                        }],
                        cwd: Some(root.clone()),
                        ..Default::default()
                    },
                },
                None,
            )
            .await;
        let done = completion(&mut h, &unknown.turn.id).await;
        assert_eq!(
            done.turn.status,
            codex_app_server_protocol::TurnStatus::Completed
        );
        assert_eq!(issuer.captured.lock().unwrap().len(), 2);
        let requests = request_mock.requests();
        assert!(requests.iter().any(|request| {
            request
                .body_json()
                .to_string()
                .contains("trusted application workflow")
        }));
        let private_encoded = base64::engine::general_purpose::STANDARD.encode(b"PRIVATE_CANARY");
        assert!(!requests.iter().any(|request| {
            let json = request.body_json().to_string();
            json.contains("PRIVATE_CANARY") || json.contains(&private_encoded)
        }));
        assert!(
            lease_route::CapturedTurnLease::capture(&thread, &next.turn.id)
                .check()
                .is_err()
        );
        let failures = lease_route::cleanup_failure_count();
        let failed = start(
            &mut h,
            &issuer,
            &thread,
            6,
            Permit {
                generation: 3,
                block: false,
                fail_revoke: true,
            },
        )
        .await;
        let done = completion(&mut h, &failed.turn.id).await;
        assert_eq!(
            done.turn.status,
            codex_app_server_protocol::TurnStatus::Failed
        );
        assert!(done.turn.error.is_some());
        let rendered = serde_json::to_string(&done)?;
        assert!(!rendered.contains("synthetic private detail"));
        assert!(lease_route::cleanup_failure_count() > failures);
        assert!(issuer.captured.lock().unwrap()[2].check().is_err());
        assert_eq!(std::fs::read(&private)?, b"PRIVATE_CANARY");
        h.shutdown().await;
        Ok(())
    })
}
