// Included only by the isolated filtered actual AppServer test process.
async fn captured_host_skill_sources(root: &Path, private: &Path) -> Result<()> {
    use codex_skills_extension::catalog::{
        SkillAuthority, SkillPackageId, SkillResourceId, SkillSourceKind,
    };
    use codex_skills_extension::provider::SkillReadRequest;
    use codex_skills_extension::{
        HostSkillProvider, HostSkillsLoadInput, HostSkillsService, SkillProvider,
    };
    use codex_utils_absolute_path::AbsolutePathBuf;
    let home = TempDir::new()?;
    let config = build_test_config(home.path(), "http://127.0.0.1:1").await?;
    let home_abs = AbsolutePathBuf::from_absolute_path(home.path().to_path_buf())?;
    let root_abs = AbsolutePathBuf::from_absolute_path(root.to_path_buf())?;
    let user_root = root.join("user-skills");
    let user_path = user_root.join("allowed/SKILL.md");
    std::fs::create_dir_all(user_path.parent().unwrap())?;
    std::fs::write(
        &user_path,
        "---\nname: user-allowed\ndescription: permitted custom skill\n---\nAUTHORIZED_USER_SKILL_BYTES",
    )?;
    std::fs::create_dir_all(user_root.join("linked"))?;
    std::os::unix::fs::symlink(private, user_root.join("linked/SKILL.md"))?;
    std::fs::create_dir_all(user_root.join("hard"))?;
    std::fs::hard_link(private, user_root.join("hard/SKILL.md"))?;
    let service = HostSkillsService::new(home_abs.clone(), true);
    service.set_extra_roots(vec![AbsolutePathBuf::from_absolute_path(user_root)?]);
    let input = HostSkillsLoadInput::new(root_abs, vec![], config.config_layer_stack.clone());
    let mut policy = FileSystemSandboxContext::from_permission_profile_with_cwd(
        codex_protocol::models::PermissionProfile::Disabled,
        PathUri::from_host_native_path(root.to_path_buf())?,
    );
    policy.permissions = ExecPermissionProfile::Managed {
        file_system: ExecManagedFileSystemPermissions::Restricted {
            entries: vec![ExecFileSystemSandboxEntry {
                path: ExecFileSystemPath::Path {
                    path: PathUri::from_host_native_path(root.to_path_buf())?,
                },
                access: codex_protocol::permissions::FileSystemAccessMode::Read,
                missing_path_behavior: None,
            }],
            glob_scan_max_depth: None,
        },
        network: codex_protocol::permissions::NetworkSandboxPolicy::Restricted,
    };
    let make = |generation| -> Result<(Arc<lease_route::TurnLease>, Arc<PendingReadFs>)> {
        let harness = Arc::new(Harness::default());
        let scope = Scope {
            owner: "trusted-skill-test".into(),
            generation,
        };
        let cap = harness.grant_from_owned_directory(
            std::fs::File::open(root)?,
            scope.clone(),
            Access::ReadOnly,
        )?;
        let source = Arc::new(PendingReadFs {
            inner: CapabilityFileSystem::new_protected(
                harness.clone(),
                cap,
                scope.clone(),
                root.to_path_buf(),
                policy.clone(),
            )?,
            block_read: AtomicBool::new(false),
            block_path: user_path.clone(),
            entered: Arc::new(Notify::new()),
            release: Arc::new(Notify::new()),
        });
        let lease = Arc::new(CapturedLease::new(
            lease_route::Identity {
                thread: "skills-thread".into(),
                turn: format!("skill-{generation}"),
                generation,
            },
            source.clone() as Arc<dyn ExecutorFileSystem>,
            Arc::new(move || harness.revoke(cap, &scope)),
        )?);
        Ok((lease, source))
    };
    let (lease, source) = make(1)?;
    assert!(
        source
            .inner
            .read_file(
                &PathUri::from_host_native_path(user_path.clone())?,
                Default::default(),
                Some(&policy)
            )
            .await?
            .starts_with(b"---")
    );
    let walk = source
        .inner
        .walk(
            &PathUri::from_host_native_path(root.join("user-skills"))?,
            WalkOptions {
                max_depth: 6,
                max_directories: 2000,
                max_entries: 20000,
                follow_directory_symlinks: false,
                prune_hidden_directories: true,
            },
            Some(&policy),
        )
        .await?;
    eprintln!(
        "HYOTAN_SKILL_DISCOVERY entries={} errors={}",
        walk.entries.len(),
        walk.errors.len()
    );
    let held = lease.clone();
    let check: codex_skills_extension::hyotan_skill_filesystem::Check =
        Arc::new(move || held.check());
    let mut narrow = policy.clone();
    narrow.permissions = ExecPermissionProfile::Managed {
        file_system: ExecManagedFileSystemPermissions::Restricted {
            entries: vec![ExecFileSystemSandboxEntry {
                path: ExecFileSystemPath::Path {
                    path: PathUri::from_host_native_path(
                        user_path.parent().unwrap().to_path_buf(),
                    )?,
                },
                access: codex_protocol::permissions::FileSystemAccessMode::Read,
                missing_path_behavior: None,
            }],
            glob_scan_max_depth: None,
        },
        network: codex_protocol::permissions::NetworkSandboxPolicy::Restricted,
    };
    let limited = codex_skills_extension::hyotan_skill_filesystem::SkillFileSystem::workspace(
        lease.authority()?,
        narrow,
        check.clone(),
    );
    assert!(
        limited
            .read_file(
                &PathUri::from_host_native_path(user_path.clone())?,
                Default::default(),
                None
            )
            .await
            .is_ok()
    );
    let inside_capability = PathUri::from_host_native_path(root.join("日本語.wav"))?;
    assert!(
        limited
            .read_file(&inside_capability, Default::default(), None)
            .await
            .is_err()
    );
    assert!(
        limited
            .read_file(&inside_capability, Default::default(), Some(&policy))
            .await
            .is_err()
    );
    let snapshot = Arc::new(
        service
            .snapshot_for_captured_turn(&input, lease.authority()?, policy.clone(), check)
            .await?,
    );
    let allowed = snapshot
        .outcome()
        .skills
        .iter()
        .find(|skill| skill.name == "user-allowed")
        .unwrap_or_else(|| {
            panic!(
                "permitted user skill discovery: loaded={} errors={}",
                snapshot.outcome().skills.len(),
                snapshot.outcome().errors.len()
            )
        })
        .clone();
    assert!(snapshot.outcome().skills.iter().all(|skill| {
        !skill
            .path_to_skills_md
            .as_path()
            .ends_with("linked/SKILL.md")
            && !skill.path_to_skills_md.as_path().ends_with("hard/SKILL.md")
    }));
    assert!(
        snapshot
            .read_skill_text(&allowed)
            .await?
            .contains("AUTHORIZED_USER_SKILL_BYTES")
    );
    let builtin = snapshot
        .outcome()
        .skills
        .iter()
        .find(|skill| skill.scope == codex_protocol::protocol::SkillScope::System)
        .expect("compiled builtin remains permitted")
        .clone();
    let bundled_before = snapshot.read_skill_text(&builtin).await?;
    // Disk cache is trusted maintenance, not model read authority. Its replacement
    // cannot change the byte source already classified as immutable embedded ingress.
    std::fs::write(
        builtin.path_to_skills_md.as_path(),
        "PRIVATE_CANARY_CACHE_REPLACEMENT",
    )?;
    assert_eq!(snapshot.read_skill_text(&builtin).await?, bundled_before);
    let mut forged = allowed.clone();
    forged.path_to_skills_md = AbsolutePathBuf::from_absolute_path(private.to_path_buf())?;
    let error = snapshot
        .read_skill_text(&forged)
        .await
        .unwrap_err()
        .to_string();
    assert_eq!(
        error,
        codex_skills_extension::hyotan_skill_filesystem::DENIAL
    );
    assert!(!error.contains(&private.to_string_lossy().to_string()));
    let provider = HostSkillProvider::new();
    let request = |snapshot: Arc<codex_skills_extension::HostSkillsSnapshot>| SkillReadRequest {
        _lifetime: std::marker::PhantomData,
        authority: SkillAuthority::new(SkillSourceKind::Host, "host"),
        package: SkillPackageId(allowed.path_to_skills_md.to_string_lossy().into_owned()),
        resource: SkillResourceId::new(allowed.path_to_skills_md.to_string_lossy().into_owned()),
        resolved_executor_roots: vec![],
        sandbox: None,
        host_snapshot: Some(snapshot),
        mcp_resources: None,
    };
    assert!(
        provider
            .read(request(snapshot.clone()))
            .await?
            .contents
            .contains("AUTHORIZED_USER_SKILL_BYTES")
    );
    assert_eq!(
        snapshot
            .load_skill_prompts(std::slice::from_ref(&allowed))
            .await
            .injected
            .len(),
        1
    );
    source.block_read.store(true, Ordering::Release);
    let pending_snapshot = snapshot.clone();
    let pending_skill = allowed.clone();
    let pending =
        tokio::spawn(async move { pending_snapshot.read_skill_text(&pending_skill).await });
    tokio::time::timeout(std::time::Duration::from_secs(5), source.entered.notified()).await?;
    lease.revoke()?;
    source.release.notify_one();
    assert!(pending.await?.is_err());
    assert!(snapshot.read_skill_text(&builtin).await.is_err());
    assert!(provider.read(request(snapshot.clone())).await.is_err());
    let prompts = snapshot
        .load_skill_prompts(&[allowed.clone(), builtin.clone()])
        .await;
    assert!(prompts.fragments.is_empty() && prompts.injected.is_empty());
    assert_eq!(
        prompts.warnings,
        vec![codex_skills_extension::hyotan_skill_filesystem::DENIAL]
    );
    let denied = codex_skills_extension::HostSkillsSnapshot::protected_empty(Arc::new(|| {
        Err(hyotan_turn_lease::denied())
    }));
    assert!(denied.read_skill_text(&builtin).await.is_err());
    let (fresh, _) = make(2)?;
    let held = fresh.clone();
    let next = service
        .snapshot_for_captured_turn(
            &input,
            fresh.authority()?,
            policy,
            Arc::new(move || held.check()),
        )
        .await?;
    let new_skill = next
        .outcome()
        .skills
        .iter()
        .find(|skill| skill.name == "user-allowed")
        .unwrap();
    assert!(
        next.read_skill_text(new_skill)
            .await?
            .contains("AUTHORIZED_USER_SKILL_BYTES")
    );
    assert!(snapshot.read_skill_text(&allowed).await.is_err());
    fresh.revoke()?;
    assert_eq!(std::fs::read(private)?, b"PRIVATE_CANARY");
    std::fs::remove_dir_all(root.join("user-skills"))?;
    Ok(())
}
