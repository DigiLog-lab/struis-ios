#[path="../../NativeCodex/ios/turn_lease.rs"] mod hyotan_turn_lease;
#[path="../../NativeCodex/ios/model_operations.rs"] mod route;
use std::sync::Arc;
use codex_file_system::{ExecutorFileSystem,FileSystemSandboxContext,ReadFileOptions};
use codex_apply_patch::{ApplyPatchFileUpdateMode,ApplyPatchOptions,MaybeApplyPatchVerified};
use codex_utils_path_uri::PathUri;
use hyotan_operation_harness::{Harness,Scope,Access};
use hyotan_appserver_operation_harness::CapabilityFileSystem;
use hyotan_turn_lease::{CapturedTurnLease,Identity};
fn uri(p:impl AsRef<std::path::Path>)->PathUri {PathUri::from_host_native_path(p).unwrap()}
#[test]
fn real_patch_preflight_runtime_canary_policy_revoke_next() {
 futures::executor::block_on(async {
  let temp=std::env::temp_dir().join(format!("hyotan-model-patch-{}",std::process::id()));
  let root=temp.join("workspace");std::fs::create_dir_all(&root).unwrap();
  let private=temp.join("private-canary");std::fs::write(&private,b"PRIVATE_NEVER_READ_OR_WRITE\n").unwrap();
  std::fs::write(root.join("normal"),b"before\n").unwrap();
  std::os::unix::fs::symlink(&private,root.join("link")).unwrap();std::fs::hard_link(&private,root.join("hard")).unwrap();
  let issue=|generation| {
   let harness=Arc::new(Harness::default());let scope=Scope{owner:"synthetic-model-turn".into(),generation};
   let cap=harness.grant(&root,scope.clone(),Access::ReadWrite).unwrap();
   let fs:Arc<dyn ExecutorFileSystem>=Arc::new(CapabilityFileSystem::new(harness.clone(),cap,scope.clone(),root.clone()).unwrap());
   let lease=CapturedTurnLease::Bound(Arc::new(::hyotan_turn_lease::CapturedLease::new(Identity{thread:"synthetic-thread".into(),turn:format!("turn-{generation}"),generation},fs.clone(),Arc::new(move||harness.revoke(cap,&scope))).unwrap()));(lease,fs)
  };
  let (a,legacy)=issue(1);let fs=route::filesystem(&a,legacy.clone()).unwrap();let cwd=uri(&root);
  let context=FileSystemSandboxContext::from_permission_profile_with_cwd(codex_protocol::models::PermissionProfile::Disabled,cwd.clone());
  let sandbox=route::sandbox(&a,Some(context.clone())).unwrap();
  let patch="*** Begin Patch\n*** Update File: normal\n@@\n-before\n+after\n*** End Patch";
  let verified=codex_apply_patch::verify_apply_patch_args_with_mode(codex_apply_patch::parse_patch(patch).unwrap(),&cwd,ApplyPatchFileUpdateMode::NormalizeToLf,fs.as_ref(),sandbox.as_ref()).await;
  assert!(matches!(verified,MaybeApplyPatchVerified::Body(_)),"permitted real preflight");
  let mut stdout=vec![];let mut stderr=vec![];
  codex_apply_patch::apply_patch_with_options(patch,ApplyPatchOptions{update_file_mode:ApplyPatchFileUpdateMode::NormalizeToLf,follow_symlinks:false},&cwd,&mut stdout,&mut stderr,fs.as_ref(),sandbox.as_ref()).await.unwrap();
  assert_eq!(std::fs::read(root.join("normal")).unwrap(),b"after\n");
  for path in [private.to_string_lossy().to_string(),"../private-canary".into(),"link".into(),"hard".into()] {
   let patch=format!("*** Begin Patch\n*** Update File: {path}\n@@\n-PRIVATE_NEVER_READ_OR_WRITE\n+BREACH\n*** End Patch");
   let result=codex_apply_patch::verify_apply_patch_args_with_mode(codex_apply_patch::parse_patch(&patch).unwrap(),&cwd,ApplyPatchFileUpdateMode::NormalizeToLf,fs.as_ref(),sandbox.as_ref()).await;
   assert!(!matches!(result,MaybeApplyPatchVerified::Body(_)),"private preflight must fail");
   let model_result=a.sanitize(format!("{result:?}"));assert_eq!(model_result,::hyotan_turn_lease::DENIAL);assert!(!model_result.contains("private-canary"));
   let result=codex_apply_patch::apply_patch_with_options(&patch,ApplyPatchOptions{update_file_mode:ApplyPatchFileUpdateMode::NormalizeToLf,follow_symlinks:false},&cwd,&mut vec![],&mut vec![],fs.as_ref(),sandbox.as_ref()).await;
   assert!(result.is_err(),"runtime cannot bypass preflight boundary");
  }
  use codex_file_system::{ExecPermissionProfile,ExecManagedFileSystemPermissions,ExecFileSystemSandboxEntry,ExecFileSystemPath};
  use codex_protocol::permissions::{FileSystemAccessMode,NetworkSandboxPolicy};
  let mut read_only=context.clone();read_only.permissions=ExecPermissionProfile::Managed{file_system:ExecManagedFileSystemPermissions::Restricted{entries:vec![ExecFileSystemSandboxEntry{path:ExecFileSystemPath::Path{path:cwd.clone()},access:FileSystemAccessMode::Read,missing_path_behavior:None}],glob_scan_max_depth:None},network:NetworkSandboxPolicy::Restricted};
  let denied_write="*** Begin Patch\n*** Add File: denied-write\n+data\n*** End Patch";
  assert!(codex_apply_patch::apply_patch_with_options(denied_write,ApplyPatchOptions{update_file_mode:ApplyPatchFileUpdateMode::NormalizeToLf,follow_symlinks:false},&cwd,&mut vec![],&mut vec![],fs.as_ref(),Some(&read_only)).await.is_err());
  assert!(!root.join("denied-write").exists());assert!(route::sandbox(&a,None).is_err());assert!(route::native_process(&a).is_err());
  let old=a.clone();a.revoke();assert!(route::filesystem(&old,legacy.clone()).is_err());assert!(fs.read_file(&uri(root.join("normal")),ReadFileOptions::default(),sandbox.as_ref()).await.is_err());
  let (b,next)=issue(2);assert_eq!(route::filesystem(&b,next).unwrap().read_file(&uri(root.join("normal")),ReadFileOptions::default(),Some(&context)).await.unwrap(),b"after\n");
  assert!(route::filesystem(&CapturedTurnLease::Denied,legacy.clone()).is_err());
  let uninstalled=CapturedTurnLease::Legacy;assert!(Arc::ptr_eq(&route::filesystem(&uninstalled,legacy.clone()).unwrap(),&legacy));assert!(route::native_process(&uninstalled).is_ok());
  assert_eq!(std::fs::read(&private).unwrap(),b"PRIVATE_NEVER_READ_OR_WRITE\n");std::fs::remove_dir_all(temp).unwrap();
 });
}
