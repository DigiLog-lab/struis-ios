#[cfg(test)]
mod hyotan_role_snapshot_tests {
    use super::*;
    use crate::hyotan_turn_lease::CapturedTurnLease;
    use codex_file_system::ExecutorFileSystem;
    use hyotan_appserver_operation_harness::CapabilityFileSystem;
    use hyotan_operation_harness::{Access, Harness, Scope};
    use std::sync::Arc;

    #[tokio::test]
    async fn captured_parent_role_snapshots_preserve_overrides_notes_and_deny_private_links() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("workspace");
        std::fs::create_dir(&root).unwrap();
        let private = temp.path().join("private-canary.toml");
        const PRIVATE: &str = "model = 'PRIVATE_CANARY_NEVER_EXPOSE'\n";
        std::fs::write(&private, PRIVATE).unwrap();
        let path = root.join("custom.toml");
        std::fs::write(&path, "model = 'authorized-custom'\nmodel_reasoning_effort = 'high'\ndeveloper_instructions = 'Authorized role instruction'\n").unwrap();
        std::os::unix::fs::symlink(&private, root.join("link.toml")).unwrap();
        std::fs::hard_link(&private, root.join("hard.toml")).unwrap();
        let issue = |generation| {
            let harness = Arc::new(Harness::default());
            let scope = Scope { owner: "synthetic-parent".into(), generation };
            let capability = harness.grant(&root, scope.clone(), Access::ReadOnly).unwrap();
            let fs: Arc<dyn ExecutorFileSystem> = Arc::new(CapabilityFileSystem::new(harness.clone(), capability, scope.clone(), root.clone()).unwrap());
            CapturedTurnLease::Bound(Arc::new(hyotan_turn_lease::CapturedLease::new(
                hyotan_turn_lease::Identity { thread: "synthetic-parent".into(), turn: format!("turn-{generation}"), generation },
                fs, Arc::new(move || harness.revoke(capability, &scope)),
            ).unwrap()))
        };
        let lease = issue(1);
        let layer = captured_role_layer(&lease, &path, "custom").await.unwrap();
        let snapshot = RoleSnapshot { entries: BTreeMap::from([("custom".into(), (path.clone(), Ok(layer)))]) };
        let mut config = crate::config::ConfigBuilder::default()
            .codex_home(temp.path().join("trusted-codex-home"))
            .fallback_cwd(Some(root.clone())).build().await.unwrap();
        config.agent_roles.insert("custom".into(), AgentRoleConfig {
            description: Some("Authorized role".into()), config_file: Some(path.clone()), nickname_candidates: None,
        });
        let spec = spawn_tool_spec::build_captured(&config.agent_roles, &lease, Some(&snapshot));
        assert!(spec.contains("`authorized-custom`"));
        assert!(spec.contains("`high`"));
        assert!(spec.contains("cannot be changed"));
        // Immutable bytes used by the tool description also determine the child.
        std::fs::write(&path, "model = 'changed-after-snapshot'\n").unwrap();
        apply_role_to_config_captured(&mut config, Some("custom"), &lease, Some(&snapshot)).await.unwrap();
        assert_eq!(config.model.as_deref(), Some("authorized-custom"));
        assert_eq!(config.developer_instructions.as_deref(), Some("Authorized role instruction"));
        assert_eq!(config.model_reasoning_effort, Some(ReasoningEffort::High));
        assert!(snapshot.layer("other", &path).is_err());
        assert!(snapshot.layer("custom", &private).is_err());
        for forbidden in [&private, &root.join("link.toml"), &root.join("hard.toml")] {
            assert!(captured_role_layer(&lease, forbidden, "forbidden").await.is_err());
        }
        assert!(captured_role_layer(&CapturedTurnLease::Denied, &path, "custom").await.is_err());
        assert_eq!(apply_role_to_config_captured(&mut config, Some("default"), &CapturedTurnLease::Denied, Some(&snapshot)).await.unwrap_err(), hyotan_turn_lease::DENIAL);
        assert_eq!(spawn_tool_spec::build_captured(&config.agent_roles, &lease, None), hyotan_turn_lease::DENIAL);
        // No raw fallback even if a readable host file has valid TOML.
        let missing = RoleSnapshot { entries: BTreeMap::new() };
        assert!(apply_role_to_config_captured(&mut config, Some("custom"), &lease, Some(&missing)).await.is_err());
        apply_role_to_config_captured(&mut config, Some("explorer"), &lease, Some(&snapshot)).await.unwrap();
        apply_role_to_config_captured(&mut config, Some("worker"), &lease, Some(&snapshot)).await.unwrap();
        lease.revoke().unwrap();
        assert!(apply_role_to_config_captured(&mut config, Some("custom"), &lease, Some(&snapshot)).await.is_err());
        assert!(apply_role_to_config_captured(&mut config, Some("worker"), &lease, Some(&snapshot)).await.is_err());
        assert_eq!(spawn_tool_spec::build_captured(&config.agent_roles, &lease, Some(&snapshot)), hyotan_turn_lease::DENIAL);
        let next = issue(2);
        let denied_snapshot = RoleSnapshot { entries: BTreeMap::from([("custom".into(), (path.clone(), Err(())))]) };
        let denied_spec = spawn_tool_spec::build_captured(&config.agent_roles, &next, Some(&denied_snapshot));
        assert!(denied_spec.contains(hyotan_turn_lease::DENIAL));
        assert!(!denied_spec.contains("PRIVATE_CANARY"));
        assert_eq!(apply_role_to_config_captured(&mut config, Some("custom"), &next, Some(&denied_snapshot)).await.unwrap_err(), hyotan_turn_lease::DENIAL);
        // Uninstalled legacy execution keeps reading and applying configured roles.
        apply_role_to_config(&mut config, Some("custom")).await.unwrap();
        assert_eq!(config.model.as_deref(), Some("changed-after-snapshot"));
        assert!(captured_role_layer(&next, &path, "custom").await.is_ok());
        assert_eq!(std::fs::read_to_string(&private).unwrap(), PRIVATE);
    }
}
