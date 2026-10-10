#!/usr/bin/env python3
"""Reproducible captured turn/media preparation against the Codex pin.
Called by prepare-codex.py after its platform changes. No product install.
"""
import pathlib, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/codex-source'
REVISION = '3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
if subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'], text=True).strip() != REVISION:
    raise RuntimeError('Unexpected Codex revision for turn lease preparation')
def original(path):
    return subprocess.check_output(['git','-C',str(SOURCE),'show',f'{REVISION}:{path}'],text=True)
def put(path,text):
    (SOURCE/path).parent.mkdir(parents=True, exist_ok=True)
    rendered='// Hyotan: captured turn lease preparation.\n'+text if path.endswith('.rs') else text
    destination=SOURCE/path
    if not destination.exists() or destination.read_text()!=rendered:
        destination.write_text(rendered)
def copy_if_changed(source,destination):
    if not destination.exists() or destination.read_bytes()!=source.read_bytes():
        shutil.copyfile(source,destination)
def replace(text,needle,new,count=1):
    if text.count(needle)!=count: raise RuntimeError('Unexpected pin anchor: '+needle[:100])
    return text.replace(needle,new)

path='codex-rs/core/Cargo.toml'; text=original(path)
text=replace(text,'[dependencies]\n','[dependencies]\nhyotan-turn-lease = { path = "../../../../TurnLease" }\n')
put(path,text)
(SOURCE/'codex-rs/core/src').mkdir(parents=True, exist_ok=True)
copy_if_changed(ROOT/'NativeCodex/ios/turn_lease.rs',SOURCE/'codex-rs/core/src/hyotan_turn_lease.rs')
path='codex-rs/core/src/lib.rs';put(path,original(path)+'\npub mod hyotan_turn_lease;\n')

path='codex-rs/protocol/src/models.rs'; text=original(path)
needle='''        let mut image_index = 0;
        let mut audio_index = 0;
        Self::Message {'''
text=replace(text,needle,'''        Self::from_user_input_with_reader(items, local_image_preparation, hyotan_local_media_read, false)
    }

    /// Explicit authorized byte reader. Errors contain no requested path or OS detail.
    /// The caller owns authorization, asynchronous preload, and lease lifetime.
    pub fn from_user_input_with_local_media_reader(
        items: Vec<UserInput>,
        preparation: LocalImagePreparation,
        reader: impl FnMut(&std::path::Path) -> std::io::Result<Vec<u8>>,
    ) -> Self {
        Self::from_user_input_with_reader(items, preparation, reader, true)
    }

    fn from_user_input_with_reader(
        items: Vec<UserInput>,
        local_image_preparation: LocalImagePreparation,
        mut reader: impl FnMut(&std::path::Path) -> std::io::Result<Vec<u8>>,
        protected: bool,
    ) -> Self {
        let mut image_index = 0;
        let mut audio_index = 0;
        Self::Message {''')
# The only native read expressions in this conversion; no operation elsewhere changed.
text=replace(text,'match std::fs::read(&path) {','match reader(&path) {',2)
for kind in ('Image','Audio'):
    needle=f'''Err(err) => vec![local_media_error_placeholder(
                                &path,
                                err,
                                LocalMediaKind::{kind},
                            )],'''
    text=replace(text,needle,f'''Err(err) => vec![if protected {{
                                ContentItem::InputText {{ text: "local media read denied by turn workspace capability; use a permitted workspace file or the trusted application workflow".to_string() }}
                            }} else {{ local_media_error_placeholder(&path, err, LocalMediaKind::{kind}) }}],''')
text+='''
#[cfg(test)]
mod hyotan_authorized_media_tests {
    use super::*;
    #[test]
    fn denied_reader_never_native_reopens_or_reveals_path() {
        let path = std::path::PathBuf::from("/synthetic-private/canary.wav");
        let mut calls = 0;
        let item = ResponseInputItem::from_user_input_with_local_media_reader(
            vec![UserInput::LocalAudio { path }], LocalImagePreparation::Defer,
            |_| { calls += 1; Err(std::io::Error::other("private internal error")) });
        let json = serde_json::to_string(&item).unwrap();
        assert_eq!(calls,1);
        assert!(json.contains("trusted application workflow"));
        assert!(!json.contains("synthetic-private"));
        assert!(!json.contains("private internal error"));
    }
    #[test]
    fn authorized_reader_supplies_actual_image_bytes_and_preserves_detail() {
        let bytes = b"authorized-image-byte-payload".to_vec();
        let item = ResponseInputItem::from_user_input_with_local_media_reader(
            vec![UserInput::LocalImage { path: "workspace/a.png".into(), detail: Some(ImageDetail::Original) }],
            LocalImagePreparation::Defer, |_| Ok(bytes.clone()));
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("data:application/octet-stream;base64,"));
        assert!(json.contains("original"));
        assert!(!json.contains("could not read"));
    }
}
'''
text+="""

/// Hyotan: canonical workspace root, set once by the trusted iOS bootstrap. Codex runs in
/// the app process there; local media outside it is refused.
pub static HYOTAN_LOCAL_MEDIA_ROOT: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();

/// Without a turn lease, local media is read here. On iOS with a root installed, the file is
/// opened first and the path of the file actually opened (F_GETPATH) must lie under the root,
/// so a symlink or a swap after any check cannot redirect the read outside the workspace.
fn hyotan_local_media_read(path: &std::path::Path) -> std::io::Result<Vec<u8>> {
    #[cfg(target_os = "ios")]
    if let Some(root) = HYOTAN_LOCAL_MEDIA_ROOT.get() {
        use std::io::Read;
        use std::os::fd::AsRawFd;
        use std::os::unix::ffi::OsStrExt;
        unsafe extern "C" {
            fn fcntl(fd: i32, cmd: i32, ...) -> i32;
        }
        const F_GETPATH: i32 = 50;
        let denied = || std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        let mut file = std::fs::File::open(path)?;
        let mut buffer = [0u8; 1024];
        if unsafe { fcntl(file.as_raw_fd(), F_GETPATH, buffer.as_mut_ptr()) } != 0 {
            return Err(denied());
        }
        let end = buffer.iter().position(|byte| *byte == 0).ok_or_else(denied)?;
        let actual = std::path::Path::new(std::ffi::OsStr::from_bytes(&buffer[..end]));
        if actual == root.as_path() || !actual.starts_with(root) {
            return Err(denied());
        }
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        return Ok(bytes);
    }
    std::fs::read(path)
}
"""
put(path,text)

path='codex-rs/core/src/session/turn_context.rs';text=original(path)
text=replace(text,'pub struct TurnContext {','pub struct TurnContext {\n    pub(crate) hyotan_lease: crate::hyotan_turn_lease::CapturedTurnLease,')
text=replace(text,'            sub_id: self.sub_id.clone(),','            hyotan_lease: self.hyotan_lease.clone(),\n            sub_id: self.sub_id.clone(),')
text=replace(text,'        TurnContext {\n            sub_id,','        TurnContext {\n            hyotan_lease: crate::hyotan_turn_lease::CapturedTurnLease::capture_resolved(\n                environments.primary().filter(|environment| !environment.environment.is_remote()).map(|environment| crate::hyotan_turn_lease::CaptureRequest {\n                    thread: thread_id.to_string(), turn: sub_id.clone(),\n                    sandbox: environment.sandbox_context(None),\n                    environment_id: environment.selection.environment_id.clone(),\n                    session_source: session_source.clone(),\n                    parent_thread: session_configuration.parent_thread_id.map(|id| id.to_string()),\n                })),\n            sub_id,')
put(path,text)
# Review constructs a distinct turn; inherited configuration is not a grant.
path='codex-rs/core/src/session/review.rs';text=original(path)
put(path,replace(text,'    let review_turn_context = TurnContext {','    let review_turn_context = TurnContext {\n        hyotan_lease: crate::hyotan_turn_lease::CapturedTurnLease::capture(&sess.thread_id().to_string(), &review_turn_id),'))
path='codex-rs/core/src/session/mod.rs';text=original(path)
needle='''    pub(crate) fn response_item_from_user_input(&self, input: Vec<UserInput>) -> ResponseItem {
        let mut item = ResponseItem::from(ResponseInputItem::from_user_input(
            input,
            LocalImagePreparation::Defer,
        ));'''
new='''    pub(crate) async fn response_item_from_user_input(&self, turn_context: &TurnContext, input: Vec<UserInput>) -> ResponseItem {
        let prepared = crate::hyotan_turn_lease::prepare_local_media(&turn_context.hyotan_lease, input).await;
        let mut item = ResponseItem::from(prepared);'''
text=replace(text,needle,new)
text=replace(text,'use codex_protocol::models::LocalImagePreparation;\n','')
text=replace(text,'use codex_protocol::models::ResponseInputItem;\n','')
text=replace(text,'self.response_item_from_user_input(input.to_vec());','self.response_item_from_user_input(turn_context, input.to_vec()).await;')
session_text=text
# Admission sees the exact generated ID before the actual Session queue.
path='codex-rs/core/src/codex_thread.rs';text=original(path)
put(path,replace(text,'self.io.submit_turn_input(request, mode).await',
    'self.io.submit_admitted_turn_input(self.session.thread_id(), request, mode).await'))
path='codex-rs/core/src/session/mod.rs';text=session_text
text=replace(text, '    pub(crate) async fn submit_turn_input(\n        &self,\n        mut request: TurnInputRequest,\n        mode: TurnInputMode,\n    ) -> CodexResult<TurnInputSubmission> {', """    // Child/review internal inputs retain baseline routing and never inherit
    // a public RPC admission permit. They need separate explicit issuance.
    pub(crate) async fn submit_turn_input(
        &self,
        request: TurnInputRequest,
        mode: TurnInputMode,
    ) -> CodexResult<TurnInputSubmission> {
        self.submit_turn_input_inner(None, request, mode).await
    }

    pub(crate) async fn submit_admitted_turn_input(
        &self,
        thread_id: ThreadId,
        request: TurnInputRequest,
        mode: TurnInputMode,
    ) -> CodexResult<TurnInputSubmission> {
        self.submit_turn_input_inner(Some(thread_id), request, mode).await
    }

    async fn submit_turn_input_inner(
        &self,
        thread_id: Option<ThreadId>,
        mut request: TurnInputRequest,
        mode: TurnInputMode,
    ) -> CodexResult<TurnInputSubmission> {""")
text=replace(text,'        let id = new_submission_id();\n        let (reply_tx, reply_rx) = oneshot::channel();',
    '        let id = new_submission_id();\n        if let Some(thread_id) = thread_id {\n            crate::hyotan_turn_lease::admit_submission(&thread_id.to_string(), &id)\n                .map_err(|_| CodexErr::InvalidRequest(hyotan_turn_lease::DENIAL.to_owned()))?;\n        }\n        let (reply_tx, reply_rx) = oneshot::channel();')
put(path,text.removeprefix('// Hyotan: captured turn lease preparation.\n'))
path='codex-rs/core/src/prompt_debug.rs';text=original(path)
put(path,replace(text,'sess.response_item_from_user_input(input);','sess.response_item_from_user_input(turn_context.as_ref(), input).await;'))

path='codex-rs/core/src/tasks/mod.rs';text=original(path)
text=replace(text,'        let sub_id = task.turn_context.sub_id.clone();','        self.revoke_hyotan_turn_lease(task.turn_context.as_ref()).await;\n        let sub_id = task.turn_context.sub_id.clone();')
text=replace(text,'        turn_context\n            .turn_metadata_state\n            .cancel_git_enrichment_task();', '        self.revoke_hyotan_turn_lease(turn_context.as_ref()).await;\n        turn_context\n            .turn_metadata_state\n            .cancel_git_enrichment_task();')
text=replace(text, '    pub async fn on_task_finished(', '''    async fn revoke_hyotan_turn_lease(&self, turn_context: &TurnContext) {
        if turn_context.hyotan_lease.revoke().is_err() {
            let err = codex_protocol::error::CodexErr::Fatal(hyotan_turn_lease::DENIAL.to_owned());
            self.emit_turn_error_lifecycle(turn_context, err.to_codex_protocol_error()).await;
            self.track_turn_codex_error(turn_context, &err);
            self.send_event(turn_context, EventMsg::Error(err.to_error_event(None))).await;
        }
    }

    pub async fn on_task_finished(''')
# Guard survives until the spawned future is dropped, including panic/abort.
text=replace(text,'                let ctx_for_finish = Arc::clone(&ctx);','                let _hyotan_lease_guard = crate::hyotan_turn_lease::LeaseGuard(ctx.hyotan_lease.clone());\n                let ctx_for_finish = Arc::clone(&ctx);')
put(path,text)

path='codex-rs/core/src/tools/handlers/view_image.rs';text=original(path)
text=replace(text,'        let fs = turn_environment.environment.get_filesystem();','''        let fs = turn.hyotan_lease.filesystem().map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?
            .unwrap_or_else(|| turn_environment.environment.get_filesystem());
        turn.hyotan_lease.check().map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;''')
for needle in ['''FunctionCallError::RespondToModel(format!(
                "unable to resolve image path `{path}` against environment cwd `{}`: {err}",
                turn_environment.cwd(),
            ))''','''FunctionCallError::RespondToModel(format!(
                    "unable to locate image at `{model_visible_path}`: {error}"
                ))''','''FunctionCallError::RespondToModel(format!(
                    "unable to read image at `{model_visible_path}`: {error}"
                ))''']:
    text=replace(text,needle,needle.replace('RespondToModel(format!(', 'RespondToModel(turn.hyotan_lease.sanitize(format!(').replace('))',')))'))
text=replace(text,'        // Reject non-images before their bytes can reach code mode','        turn.hyotan_lease.check().map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;\n        // Reject non-images before their bytes can reach code mode')
text=replace(text,'''FunctionCallError::RespondToModel(format!(
                "image path `{model_visible_path}` is not a file"
            ))''','''FunctionCallError::RespondToModel(turn.hyotan_lease.sanitize(format!(
                "image path `{model_visible_path}` is not a file"
            )))''')
put(path,text)
# Trusted Rust embedding bridge, exposed only for the embedded platform.
# prepare-codex just regenerated this file's existing transport adaptation.
path='codex-rs/app-server/src/lib.rs'
hook='\n#[cfg(target_os = "ios")]\npub use codex_core::hyotan_turn_lease;\n'
text=(SOURCE/path).read_text().removesuffix(hook)
if (SOURCE/path).read_text()!=text+hook: (SOURCE/path).write_text(text+hook)
print('Prepared captured turn leases and explicit authorized local-media conversion; factory remains uninstalled.')

# Dedicated actual MessageProcessor unit-test fixture; only filtered test process
# installs the issuer. Production/default factories remain uninstalled.
path='codex-rs/app-server/Cargo.toml';text=original(path)
text=replace(text,'[dev-dependencies]\n','[dev-dependencies]\nhyotan-turn-lease = { path = "../../../../TurnLease" }\nhyotan-operation-harness = { path = "../../../../OperationHarness" }\nhyotan-appserver-operation-harness = { path = "../../../../AppServerOperationHarness" }\ncodex-file-system = { workspace = true }\ncodex-utils-path-uri = { workspace = true }\n')
put(path,text)
path='codex-rs/app-server/src/message_processor_tracing_tests.rs'
text=original(path)
text=replace(text, "async fn build_test_processor(\n    config: Arc<Config>,\n) -> (", """async fn build_test_processor(config: Arc<Config>) -> (
    Arc<MessageProcessor>,
    mpsc::Receiver<crate::outgoing_message::OutgoingEnvelope>,
) {
    build_test_processor_with_environment(config, Arc::new(EnvironmentManager::default_for_tests())).await
}

async fn build_test_processor_with_environment(
    config: Arc<Config>,
    environment_manager: Arc<EnvironmentManager>,
) -> (""")
text=replace(text, 'environment_manager: Arc::new(EnvironmentManager::default_for_tests()),', 'environment_manager,')
text=replace(text, "    tracing: &'static TestTracing,", "    tracing: &'static TestTracing,\n    completed: std::collections::VecDeque<codex_app_server_protocol::TurnCompletedNotification>,")
text=replace(text, '            tracing,\n        };', '            tracing,\n            completed: Default::default(),\n        };')
text=replace(text, 'read_response(&mut self.outgoing_rx, request_id).await', 'read_response(&mut self.outgoing_rx, &mut self.completed, request_id).await')
text=replace(text, '    request_id: i64,\n) -> T {', '    completed: &mut std::collections::VecDeque<codex_app_server_protocol::TurnCompletedNotification>,\n    request_id: i64,\n) -> T {')
text=replace(text, '        let crate::outgoing_message::OutgoingMessage::Response(response) = message else {', """        if let crate::outgoing_message::OutgoingMessage::AppServerNotification(n) = &message {
            if let codex_app_server_protocol::ServerNotification::TurnCompleted(n) = &n.notification {
                assert!(completed.len() < 16, "synthetic terminal notification bound");
                completed.push_back(n.clone());
            }
        }
        let crate::outgoing_message::OutgoingMessage::Response(response) = message else {""")
text=replace(text, '.expect("timed out waiting for response")', '.unwrap_or_else(|_| panic!("synthetic RPC response deadline request={request_id}"))')
text=replace(text, '        let crate::outgoing_message::OutgoingMessage::Response(response) = message else {', '''        if let crate::outgoing_message::OutgoingMessage::Error(error) = &message {
            if error.id == RequestId::Integer(request_id) {
                // This unit harness uses synthetic config and a local mock
                // provider without auth. Surface RPC errors instead of a false
                // transport timeout; no external/private model payloads exist.
                panic!("synthetic RPC request {request_id} failed: {}", error.error.message);
            }
        }
        let crate::outgoing_message::OutgoingMessage::Response(response) = message else {''')
put(path,text+'\n#[path = "message_processor_tracing_tests/hyotan_captured_turn_tests.rs"]\nmod hyotan_captured_turn_tests;\n')
(SOURCE/'codex-rs/app-server/src/message_processor_tracing_tests').mkdir(parents=True,exist_ok=True)
copy_if_changed(ROOT/'NativeCodex/ios/turn_lease_appserver_tests.rs', SOURCE/'codex-rs/app-server/src/message_processor_tracing_tests/hyotan_captured_turn_tests.rs')

# Dedicated test workspace lock includes only existing pinned runtime dependency
# families plus the three local harness crates. NativeCodex's product lock is
# independent; no product dependency resolution is changed here.
copy_if_changed(ROOT/'TurnLeaseIntegration/appserver.Cargo.lock', SOURCE/'codex-rs/Cargo.lock')

# AppServer's outer serialization/spawn queue is an explicit trust boundary.
# Only an admitted TurnStart carries its immutable host callback across it.
path='codex-rs/app-server/src/message_processor.rs';text=original(path)
text=replace(text, '        let serialization_scope = codex_request.serialization_scope();', """        let hyotan_admission = if matches!(&codex_request, ClientRequest::TurnStart { .. }) {
            codex_core::hyotan_turn_lease::current_submission_admission()
        } else { None };
        let serialization_scope = codex_request.serialization_scope();""")
text=replace(text, '        let request = QueuedInitializedRequest::new(\n            rpc_gate,\n            async move {', '        let request = QueuedInitializedRequest::new(\n            rpc_gate,\n            codex_core::hyotan_turn_lease::with_optional_submission_admission(hyotan_admission, async move {')
text=replace(text, '            }\n            .instrument(span),\n        );', '            })\n            .instrument(span),\n        );')
put(path,text)
