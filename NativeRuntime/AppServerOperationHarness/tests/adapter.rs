use codex_file_system::*;
use codex_utils_path_uri::PathUri;
use futures::{StreamExt, executor::block_on};
use hyotan_appserver_operation_harness::CapabilityFileSystem;
use hyotan_operation_harness::{Access, Harness, Scope};
use std::{io, path::PathBuf, sync::Arc};
struct Fixture {
    base: PathBuf,
    root: PathBuf,
    private: PathBuf,
    h: Arc<Harness>,
    scope: Scope,
    cap: hyotan_operation_harness::Capability,
    fs: CapabilityFileSystem,
}
impl Fixture {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let base = std::env::temp_dir().join(format!(
            "hyotan-adapter-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let root = base.join("workspace");
        std::fs::create_dir_all(&root).unwrap();
        let private = base.join("private-canary");
        std::fs::write(&private, b"private").unwrap();
        let h = Arc::new(Harness::default());
        let scope = Scope {
            owner: "trusted-owner".into(),
            generation: 7,
        };
        let cap = h.grant(&root, scope.clone(), Access::ReadWrite).unwrap();
        let fs = CapabilityFileSystem::new(h.clone(), cap, scope.clone(), root.clone()).unwrap();
        Self {
            base,
            root,
            private,
            h,
            scope,
            cap,
            fs,
        }
    }
    fn p(&self, p: &str) -> PathUri {
        PathUri::from_host_native_path(self.root.join(p)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.base).unwrap();
    }
}
fn denied<T: std::fmt::Debug>(r: io::Result<T>, op: &str) {
    let e = r.unwrap_err();
    assert_eq!(e.kind(), io::ErrorKind::PermissionDenied);
    assert!(e.to_string().contains(op));
    assert!(e.to_string().contains("permitted workspace"));
    assert!(!e.to_string().contains("private-canary"));
}
#[test]
fn real_trait_roundtrip_and_private_denials() {
    block_on(async {
        let f = Fixture::new();
        let fs: &dyn ExecutorFileSystem = &f.fs;
        let p = f.p("日本語.txt");
        fs.write_file(
            &p,
            "計算結果".as_bytes().to_vec(),
            WriteFileOptions::default(),
            None,
        )
        .await
        .unwrap();
        assert_eq!(
            fs.read_file_text(&p, ReadFileOptions::default(), None)
                .await
                .unwrap(),
            "計算結果"
        );
        assert_eq!(fs.canonicalize(&p, None).await.unwrap(), p);
        let meta = fs
            .get_metadata(&p, GetMetadataOptions::default(), None)
            .await
            .unwrap();
        assert!(meta.is_file);
        assert_eq!(meta.size, 12);
        let root = f.p("");
        assert!(
            fs.get_metadata(&root, GetMetadataOptions::default(), None)
                .await
                .unwrap()
                .is_directory
        );
        assert_eq!(
            fs.read_directory(&root, None).await.unwrap()[0].file_name,
            "日本語.txt"
        );
        let private = PathUri::from_host_native_path(&f.private).unwrap();
        denied(
            fs.read_file(&private, ReadFileOptions::default(), None)
                .await,
            "read",
        );
        denied(
            fs.write_file(
                &private,
                b"attack".to_vec(),
                WriteFileOptions::default(),
                None,
            )
            .await,
            "write",
        );
        std::os::unix::fs::symlink(&f.private, f.root.join("symlink")).unwrap();
        denied(
            fs.read_file(&f.p("symlink"), ReadFileOptions::default(), None)
                .await,
            "read",
        );
        std::fs::hard_link(&f.private, f.root.join("hardlink")).unwrap();
        denied(
            fs.read_file(&f.p("hardlink"), ReadFileOptions::default(), None)
                .await,
            "read",
        );
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}
#[test]
fn stream_revalidates_cancellation_and_chunk_bounds() {
    block_on(async {
        let f = Fixture::new();
        let p = f.p("large");
        let bytes = vec![42; FILE_READ_CHUNK_SIZE + 17];
        f.fs.write_file(&p, bytes.clone(), WriteFileOptions::default(), None)
            .await
            .unwrap();
        let mut s = f.fs.read_file_stream(&p, None).await.unwrap();
        assert_eq!(s.next().await.unwrap().unwrap().len(), FILE_READ_CHUNK_SIZE);
        assert_eq!(s.next().await.unwrap().unwrap().len(), 17);
        assert!(s.next().await.is_none());
        let mut s = f.fs.read_file_stream(&p, None).await.unwrap();
        s.next().await.unwrap().unwrap();
        f.h.revoke(f.cap, &f.scope).unwrap();
        denied(s.next().await.unwrap(), "read stream");
        assert!(s.next().await.is_none());
        denied(
            f.fs.read_file(&p, ReadFileOptions::default(), None).await,
            "read",
        );
    });
}
#[test]
fn stream_keeps_issued_object_after_atomic_path_replacement() {
    block_on(async {
        let f = Fixture::new();
        let p = f.p("日本語.stream");
        let original = vec![41; FILE_READ_CHUNK_SIZE + 17];
        std::fs::write(f.root.join("日本語.stream"), &original).unwrap();
        let mut stream = f.fs.read_file_stream(&p, None).await.unwrap();
        assert_eq!(
            stream.next().await.unwrap().unwrap().as_ref(),
            &original[..FILE_READ_CHUNK_SIZE]
        );
        std::fs::write(f.root.join("replacement"), vec![99; original.len()]).unwrap();
        f.h.rename(
            f.cap,
            &f.scope,
            std::path::Path::new("replacement"),
            std::path::Path::new("日本語.stream"),
        )
        .unwrap();
        assert_eq!(
            stream.next().await.unwrap().unwrap().as_ref(),
            &original[FILE_READ_CHUNK_SIZE..]
        );
        assert!(stream.next().await.is_none());
        assert_eq!(
            f.fs.read_file(&p, ReadFileOptions::default(), None)
                .await
                .unwrap(),
            vec![99; original.len()]
        );
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}
#[test]
fn stream_rejects_hardlink_added_to_issued_object_and_releases_early_drop() {
    block_on(async {
        let f = Fixture::new();
        let p = f.p("source");
        std::fs::write(f.root.join("source"), vec![41; FILE_READ_CHUNK_SIZE + 17]).unwrap();
        let mut stream = f.fs.read_file_stream(&p, None).await.unwrap();
        stream.next().await.unwrap().unwrap();
        std::fs::hard_link(f.root.join("source"), f.root.join("additional-link")).unwrap();
        denied(stream.next().await.unwrap(), "read stream");
        assert!(stream.next().await.is_none());
        std::fs::remove_file(f.root.join("additional-link")).unwrap();
        // Each dropped stream must release its slot rather than exhaust the
        // trusted per-grant limit after repeated cancelled consumers.
        for _ in 0..hyotan_operation_harness::MAX_HANDLES_PER_GRANT + 1 {
            let stream = f.fs.read_file_stream(&p, None).await.unwrap();
            drop(stream);
        }
        let mut held = Vec::new();
        for _ in 0..hyotan_operation_harness::MAX_HANDLES_PER_GRANT {
            held.push(f.fs.read_file_stream(&p, None).await.unwrap());
        }
        assert!(f.fs.read_file_stream(&p, None).await.is_err());
        held.pop();
        let stream = f.fs.read_file_stream(&p, None).await.unwrap();
        drop(stream);
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}
#[test]
fn retained_stream_preserves_large_file_reads_with_bounded_chunks() {
    block_on(async {
        let f = Fixture::new();
        let size = hyotan_operation_harness::MAX_FILE_BYTES as u64 + 17;
        let file = std::fs::File::create(f.root.join("large-sparse")).unwrap();
        file.set_len(size).unwrap();
        let mut stream =
            f.fs.read_file_stream(&f.p("large-sparse"), None)
                .await
                .unwrap();
        let mut total = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.unwrap();
            assert!(chunk.len() <= FILE_READ_CHUNK_SIZE);
            assert!(chunk.iter().all(|b| *b == 0));
            total += chunk.len() as u64;
        }
        assert_eq!(total, size);
        // Whole-file reads retain their separate bounded-allocation policy.
        denied(
            f.fs.read_file(&f.p("large-sparse"), ReadFileOptions::default(), None)
                .await,
            "read",
        );
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}
#[test]
fn binding_wrong_owner_generation_and_read_only() {
    block_on(async {
        let f = Fixture::new();
        let mut wrong = f.scope.clone();
        wrong.owner = "other".into();
        assert!(CapabilityFileSystem::new(f.h.clone(), f.cap, wrong, f.root.clone()).is_err());
        let mut wrong = f.scope.clone();
        wrong.generation += 1;
        assert!(CapabilityFileSystem::new(f.h.clone(), f.cap, wrong, f.root.clone()).is_err());
        let cap =
            f.h.grant(&f.root, f.scope.clone(), Access::ReadOnly)
                .unwrap();
        let fs =
            CapabilityFileSystem::new(f.h.clone(), cap, f.scope.clone(), f.root.clone()).unwrap();
        denied(
            fs.write_file(&f.p("blocked"), vec![1], WriteFileOptions::default(), None)
                .await,
            "write",
        );
    });
}
#[test]
fn bounded_walk_copy_remove_and_option_rejections() {
    block_on(async {
        let f = Fixture::new();
        let dir = f.p("dir");
        f.fs.create_directory(
            &dir,
            CreateDirectoryOptions {
                recursive: false,
                follow_symlinks: false,
            },
            None,
        )
        .await
        .unwrap();
        f.fs.write_file(&f.p("dir/a"), vec![1], WriteFileOptions::default(), None)
            .await
            .unwrap();
        f.fs.write_file(&f.p("b"), vec![2], WriteFileOptions::default(), None)
            .await
            .unwrap();
        let opts = WalkOptions {
            max_depth: 4,
            max_directories: 4,
            max_entries: 1,
            follow_directory_symlinks: false,
            prune_hidden_directories: false,
        };
        let walk = f.fs.walk(&f.p(""), opts, None).await.unwrap();
        assert!(walk.truncated);
        assert_eq!(walk.entries.len(), 1);
        let walk =
            f.fs.walk(
                &f.p(""),
                WalkOptions {
                    max_entries: 20,
                    ..opts
                },
                None,
            )
            .await
            .unwrap();
        assert_eq!(walk.entries.len(), 3);
        assert!(!walk.truncated);
        f.fs.copy(
            &f.p("b"),
            &f.p("copied"),
            CopyOptions { recursive: false },
            None,
        )
        .await
        .unwrap();
        assert_eq!(
            f.fs.read_file(&f.p("copied"), ReadFileOptions::default(), None)
                .await
                .unwrap(),
            vec![2]
        );
        f.fs.remove(
            &f.p("copied"),
            RemoveOptions {
                recursive: false,
                force: false,
                follow_symlinks: false,
            },
            None,
        )
        .await
        .unwrap();
        denied(
            f.fs.create_directory(
                &f.p("nested/path"),
                CreateDirectoryOptions {
                    recursive: true,
                    follow_symlinks: false,
                },
                None,
            )
            .await,
            "unsupported",
        );
        denied(
            f.fs.remove(
                &f.p("missing"),
                RemoveOptions {
                    recursive: false,
                    force: true,
                    follow_symlinks: false,
                },
                None,
            )
            .await,
            "unsupported",
        );
        denied(
            f.fs.walk(
                &f.p(""),
                WalkOptions {
                    follow_directory_symlinks: true,
                    ..opts
                },
                None,
            )
            .await,
            "unsupported",
        );
    });
}
#[test]
fn supplied_sandbox_restricts_without_widening() {
    block_on(async {
        use codex_protocol::permissions::{FileSystemAccessMode, NetworkSandboxPolicy};
        let f = Fixture::new();
        let p = f.p("allowed");
        f.fs.write_file(&p, vec![3], WriteFileOptions::default(), None)
            .await
            .unwrap();
        let mut sandbox = FileSystemSandboxContext::from_permission_profile_with_cwd(
            codex_protocol::models::PermissionProfile::Disabled,
            f.p(""),
        );
        sandbox.permissions = ExecPermissionProfile::Managed {
            file_system: ExecManagedFileSystemPermissions::Restricted {
                entries: vec![ExecFileSystemSandboxEntry {
                    path: ExecFileSystemPath::Path { path: f.p("") },
                    access: FileSystemAccessMode::Read,
                    missing_path_behavior: None,
                }],
                glob_scan_max_depth: None,
            },
            network: NetworkSandboxPolicy::Restricted,
        };
        assert_eq!(
            f.fs.read_file(&p, ReadFileOptions::default(), Some(&sandbox))
                .await
                .unwrap(),
            vec![3]
        );
        denied(
            f.fs.write_file(&p, vec![4], WriteFileOptions::default(), Some(&sandbox))
                .await,
            "write",
        );
        let private = PathUri::from_host_native_path(&f.private).unwrap();
        let unrestricted = FileSystemSandboxContext::from_permission_profile_with_cwd(
            codex_protocol::models::PermissionProfile::Disabled,
            f.p(""),
        );
        denied(
            f.fs.read_file(&private, ReadFileOptions::default(), Some(&unrestricted))
                .await,
            "read",
        );
        sandbox.permissions = ExecPermissionProfile::Managed {
            file_system: ExecManagedFileSystemPermissions::Restricted {
                entries: vec![ExecFileSystemSandboxEntry {
                    path: ExecFileSystemPath::GlobPattern {
                        pattern: "**".into(),
                    },
                    access: FileSystemAccessMode::Read,
                    missing_path_behavior: None,
                }],
                glob_scan_max_depth: None,
            },
            network: NetworkSandboxPolicy::Restricted,
        };
        denied(
            f.fs.read_file(&p, ReadFileOptions::default(), Some(&sandbox))
                .await,
            "read",
        );
    });
}
#[test]
fn root_rename_keeps_descriptor_and_missing_preserves_kind() {
    block_on(async {
        let f = Fixture::new();
        denied(
            f.fs.read_file(
                &PathUri::parse("file:///workspace-outside/file").unwrap(),
                ReadFileOptions::default(),
                None,
            )
            .await,
            "read",
        );
        assert_eq!(
            f.fs.get_metadata(&f.p("missing"), GetMetadataOptions::default(), None)
                .await
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        let old = f.base.join("old-workspace");
        std::fs::rename(&f.root, &old).unwrap();
        std::os::unix::fs::symlink(&f.base, &f.root).unwrap();
        f.fs.write_file(
            &f.p("authorized"),
            b"safe".to_vec(),
            WriteFileOptions::default(),
            None,
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read(old.join("authorized")).unwrap(), b"safe");
        assert!(!f.base.join("authorized").exists());
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}

#[test]
fn immutable_turn_policy_is_mandatory_even_without_call_sandbox() {
    block_on(async {
        use codex_protocol::permissions::{FileSystemAccessMode, NetworkSandboxPolicy};
        let f = Fixture::new();
        let path = f.p("日本語.txt");
        f.fs.write_file(&path, vec![7], Default::default(), None).await.unwrap();
        let mut policy = FileSystemSandboxContext::from_permission_profile_with_cwd(
            codex_protocol::models::PermissionProfile::Disabled, f.p(""));
        policy.permissions = ExecPermissionProfile::Managed {
            file_system: ExecManagedFileSystemPermissions::Restricted {
                entries: vec![ExecFileSystemSandboxEntry {
                    path: ExecFileSystemPath::Path { path: f.p("") },
                    access: FileSystemAccessMode::Read, missing_path_behavior: None,
                }], glob_scan_max_depth: None,
            }, network: NetworkSandboxPolicy::Restricted,
        };
        let fs = CapabilityFileSystem::new_protected(f.h.clone(), f.cap,
            f.scope.clone(), f.root.clone(), policy.clone()).unwrap();
        assert_eq!(fs.read_file(&path, Default::default(), None).await.unwrap(), vec![7]);
        denied(fs.write_file(&path, vec![8], Default::default(), None).await, "write");
        let wider = FileSystemSandboxContext::from_permission_profile_with_cwd(
            codex_protocol::models::PermissionProfile::Disabled, f.p(""));
        denied(fs.write_file(&path, vec![8], Default::default(), Some(&wider)).await, "write");
        policy.permissions = ExecPermissionProfile::Managed {
            file_system: ExecManagedFileSystemPermissions::Restricted {
                entries: vec![], glob_scan_max_depth: None,
            }, network: NetworkSandboxPolicy::Restricted,
        };
        denied(fs.read_file(&path, Default::default(), Some(&policy)).await, "read");
        f.h.revoke(f.cap, &f.scope).unwrap();
        denied(fs.read_file(&path, Default::default(), None).await, "read");
        assert_eq!(std::fs::read(f.root.join("日本語.txt")).unwrap(), vec![7]);
        assert_eq!(std::fs::read(&f.private).unwrap(), b"private");
    });
}
