/// Turn-local immutable, validated role layers. Each record is tied to the exact
/// configured role and pathname, while its bytes come only from parent authority.
/// A denial is retained, not retried through native filesystem APIs.
#[derive(Debug)]
pub(crate) struct RoleSnapshot {
    entries: BTreeMap<String, (std::path::PathBuf, Result<TomlValue, ()>)>,
}
impl RoleSnapshot {
    fn layer(&self, name: &str, path: &Path) -> std::io::Result<&TomlValue> {
        match self.entries.get(name) {
            Some((identity, Ok(layer))) if identity == path => Ok(layer),
            _ => Err(hyotan_turn_lease::denied()),
        }
    }
}

pub(crate) async fn prepare_roles(turn: &crate::TurnContext) -> &RoleSnapshot {
    turn.hyotan_roles.get_or_init(|| async {
        let mut entries = BTreeMap::new();
        // No extra reads are introduced in legacy execution.
        if !matches!(turn.hyotan_lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) {
            for (name, role) in &turn.config.agent_roles {
                if let Some(path) = &role.config_file {
                    let layer = captured_role_layer(&turn.hyotan_lease, path, name).await.map_err(|_| ());
                    entries.insert(name.clone(), (path.clone(), layer));
                }
            }
        }
        RoleSnapshot { entries }
    }).await
}

async fn captured_role_layer(
    lease: &crate::hyotan_turn_lease::CapturedTurnLease,
    path: &Path, name: &str,
) -> anyhow::Result<TomlValue> {
    lease.check()?;
    let fs = lease.filesystem()?.ok_or_else(hyotan_turn_lease::denied)?;
    let uri = codex_utils_path_uri::PathUri::from_host_native_path(path)?;
    let bytes = fs.read_file(&uri, Default::default(), None).await?;
    lease.check()?;
    let contents = String::from_utf8(bytes)?;
    let base = path.parent().ok_or_else(hyotan_turn_lease::denied)?;
    let layer = parse_agent_role_file_contents(&contents, path, base, Some(name))?.config;
    deserialize_config_toml_with_base(layer.clone(), base)?;
    let layer = resolve_relative_paths_in_config_toml(layer, base)?;
    lease.check()?;
    Ok(layer)
}
