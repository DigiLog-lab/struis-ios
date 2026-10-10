use hyotan_operation_harness::{Access, Harness, Scope};
use std::os::unix::fs::symlink;
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static SERIAL: AtomicUsize = AtomicUsize::new(0);
struct Fixture {
    base: PathBuf,
    work: PathBuf,
    private: PathBuf,
    h: Harness,
    scope: Scope,
}
impl Fixture {
    fn new() -> Self {
        let base = std::env::temp_dir().join(format!(
            "hyotan-harness-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        let work = base.join("work");
        let private = base.join("private");
        fs::create_dir_all(&work).unwrap();
        fs::create_dir(&private).unwrap();
        fs::write(private.join("canary"), b"private canary").unwrap();
        Self {
            base,
            work,
            private,
            h: Harness::default(),
            scope: Scope {
                owner: "turn-parent".into(),
                generation: 7,
            },
        }
    }
    fn cap(&self, access: Access) -> hyotan_operation_harness::Capability {
        self.h
            .grant(&self.work, self.scope.clone(), access)
            .unwrap()
    }
    fn unchanged(&self) {
        assert_eq!(
            fs::read(self.private.join("canary")).unwrap(),
            b"private canary"
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.base).unwrap();
    }
}
fn denied<T>(r: io::Result<T>) {
    let e = match r {
        Err(e) => e,
        Ok(_) => panic!("operation allowed"),
    };
    assert_eq!(e.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(e.to_string(), "operation denied");
}
#[test]
fn normal_japanese_and_recursive_operations() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let h = &f.h;
    let s = &f.scope;
    h.mkdir(c, s, Path::new("資料")).unwrap();
    h.write(c, s, Path::new("資料/日本語.txt"), "正常です".as_bytes())
        .unwrap();
    assert_eq!(
        h.read(c, s, Path::new("資料/日本語.txt")).unwrap(),
        "正常です".as_bytes()
    );
    assert!(h.metadata(c, s, Path::new("資料")).unwrap().directory);
    assert_eq!(
        h.list(c, s, Some(Path::new("資料"))).unwrap(),
        vec![std::ffi::OsString::from("日本語.txt")]
    );
    assert_eq!(h.list(c, s, None).unwrap().len(), 1);
    assert_eq!(h.list(c, s, None).unwrap().len(), 1);
    h.copy(c, s, Path::new("資料"), Path::new("copy"), true)
        .unwrap();
    assert_eq!(
        h.read(c, s, Path::new("copy/日本語.txt")).unwrap(),
        "正常です".as_bytes()
    );
    denied(h.copy(c, s, Path::new("資料"), Path::new("資料/self"), true));
    h.remove(c, s, Path::new("copy"), true).unwrap();
    h.remove(c, s, Path::new("資料/日本語.txt"), false).unwrap();
    h.remove(c, s, Path::new("資料"), false).unwrap();
    assert!(h.list(c, s, None).unwrap().is_empty());
    f.unchanged();
}
#[test]
fn path_and_link_escapes() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let h = &f.h;
    let s = &f.scope;
    for p in [
        "../private/canary",
        "/private/canary",
        "x/../../private/canary",
        "bad\0name",
        "",
    ] {
        denied(h.read(c, s, Path::new(p)));
        denied(h.write(c, s, Path::new(p), b"bad"));
        denied(h.metadata(c, s, Path::new(p)));
        denied(h.remove(c, s, Path::new(p), true));
    }
    symlink(f.private.join("canary"), f.work.join("leaf")).unwrap();
    symlink(&f.private, f.work.join("ancestor")).unwrap();
    fs::hard_link(f.private.join("canary"), f.work.join("hard")).unwrap();
    for p in ["leaf", "ancestor/canary", "hard"] {
        denied(h.read(c, s, Path::new(p)));
        denied(h.write(c, s, Path::new(p), b"bad"));
        denied(h.metadata(c, s, Path::new(p)));
        denied(h.remove(c, s, Path::new(p), true));
        denied(h.copy(c, s, Path::new(p), Path::new("copied"), false));
    }
    denied(h.mkdir(c, s, Path::new("ancestor/new")));
    denied(h.copy(c, s, Path::new("hard"), Path::new("ancestor/new"), false));
    denied(h.list(c, s, Some(Path::new("ancestor"))));
    f.unchanged();
}
#[test]
fn readonly_and_scope_and_revocation() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"ok").unwrap();
    let c = f.cap(Access::ReadOnly);
    let h = &f.h;
    let s = &f.scope;
    assert_eq!(h.read(c, s, Path::new("ok")).unwrap(), b"ok");
    denied(h.write(c, s, Path::new("ok"), b"bad"));
    denied(h.mkdir(c, s, Path::new("dir")));
    denied(h.remove(c, s, Path::new("ok"), false));
    denied(h.copy(c, s, Path::new("ok"), Path::new("copy"), false));
    for wrong in [
        Scope {
            owner: "child".into(),
            generation: 7,
        },
        Scope {
            owner: s.owner.clone(),
            generation: 8,
        },
    ] {
        denied(h.read(c, &wrong, Path::new("ok")));
        denied(h.revoke(c, &wrong));
    }
    let other = Harness::default();
    let foreign = other.grant(&f.work, s.clone(), Access::ReadWrite).unwrap();
    denied(h.read(foreign, s, Path::new("ok")));
    denied(other.read(c, s, Path::new("ok")));
    h.revoke(c, s).unwrap();
    denied(h.read(c, s, Path::new("ok")));
    denied(h.write(c, s, Path::new("ok"), b"bad"));
    denied(h.revoke(c, s));
    assert_eq!(fs::read(f.work.join("ok")).unwrap(), b"ok");
    f.unchanged();
}
#[test]
fn root_name_replaced_after_grant() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"old workspace").unwrap();
    let c = f.cap(Access::ReadWrite);
    let moved = f.base.join("original");
    fs::rename(&f.work, &moved).unwrap();
    symlink(&f.private, &f.work).unwrap();
    assert_eq!(
        f.h.read(c, &f.scope, Path::new("ok")).unwrap(),
        b"old workspace"
    );
    assert_eq!(
        f.h.read(c, &f.scope, Path::new("canary"))
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    f.h.write(c, &f.scope, Path::new("ok"), b"workspace changed")
        .unwrap();
    assert_eq!(fs::read(moved.join("ok")).unwrap(), b"workspace changed");
    f.unchanged();
}
#[test]
fn recursive_operations_refuse_links() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    fs::create_dir(f.work.join("tree")).unwrap();
    symlink(&f.private, f.work.join("tree/link")).unwrap();
    denied(f.h.copy(c, &f.scope, Path::new("tree"), Path::new("copy"), true));
    denied(f.h.remove(c, &f.scope, Path::new("tree"), true));
    f.unchanged();
}
#[test]
fn trusted_bootstrap_refuses_symlink_roots_and_ancestors() {
    let f = Fixture::new();
    let alias = f.base.join("alias");
    symlink(&f.work, &alias).unwrap();
    denied(f.h.grant(&alias, f.scope.clone(), Access::ReadWrite));
    denied(f.h.grant(&alias.join("child"), f.scope.clone(), Access::ReadWrite));
}
#[test]
fn live_ancestor_swaps_never_touch_canary() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let dir = f.work.join("dir");
    let parked = f.work.join("parked");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("canary"), b"workspace").unwrap();
    std::thread::scope(|threads| {
        threads.spawn(|| {
            for _ in 0..2000 {
                fs::rename(&dir, &parked).unwrap();
                symlink(&f.private, &dir).unwrap();
                fs::remove_file(&dir).unwrap();
                fs::rename(&parked, &dir).unwrap();
            }
        });
        for _ in 0..2000 {
            if let Ok(bytes) = f.h.read(c, &f.scope, Path::new("dir/canary")) {
                assert_ne!(bytes, b"private canary");
            }
            let _ =
                f.h.write(c, &f.scope, Path::new("dir/canary"), b"allowed workspace");
        }
    });
    f.unchanged();
}
#[test]
fn resource_limits_are_real_operation_failures() {
    use hyotan_operation_harness::{MAX_FILE_BYTES, MAX_LIST_ENTRIES, MAX_RECURSIVE_DEPTH};
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let large = fs::File::create(f.work.join("large")).unwrap();
    large.set_len(MAX_FILE_BYTES as u64 + 1).unwrap();
    denied(f.h.read(c, &f.scope, Path::new("large")));
    denied(f.h.copy(c, &f.scope, Path::new("large"), Path::new("copy"), false));
    assert!(!f.work.join("copy").exists());
    denied(f.h.write(c, &f.scope, Path::new("new"), &vec![0; MAX_FILE_BYTES + 1]));
    assert!(!f.work.join("new").exists());
    fs::create_dir(f.work.join("many")).unwrap();
    for i in 0..=MAX_LIST_ENTRIES {
        fs::write(f.work.join("many").join(i.to_string()), b"").unwrap();
    }
    denied(f.h.list(c, &f.scope, Some(Path::new("many"))));
    fs::create_dir(f.work.join("deep")).unwrap();
    let mut dir = f.work.join("deep");
    for _ in 0..=MAX_RECURSIVE_DEPTH {
        dir = dir.join("d");
        fs::create_dir(&dir).unwrap();
    }
    fs::write(dir.join("file"), b"ok").unwrap();
    denied(f.h.copy(c, &f.scope, Path::new("deep"), Path::new("deepcopy"), true));
    denied(f.h.remove(c, &f.scope, Path::new("deep"), true));
    f.unchanged();
}
#[test]
fn owned_directory_bootstrap_and_chunk_revocation() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"abcdef").unwrap();
    let c =
        f.h.grant_from_owned_directory(
            fs::File::open(&f.work).unwrap(),
            f.scope.clone(),
            Access::ReadOnly,
        )
        .unwrap();
    assert!(f.h.metadata_root(c, &f.scope).unwrap().directory);
    assert_eq!(
        f.h.read_range(c, &f.scope, Path::new("ok"), 2, 2).unwrap(),
        b"cd"
    );
    f.h.revoke(c, &f.scope).unwrap();
    denied(f.h.read_range(c, &f.scope, Path::new("ok"), 4, 2));
    denied(f.h.metadata_root(c, &f.scope));
    denied(f.h.grant_from_owned_directory(
        fs::File::open(f.work.join("ok")).unwrap(),
        f.scope.clone(),
        Access::ReadOnly,
    ));
    f.unchanged();
}
#[test]
fn sanitized_structural_failures_and_copy_byte_budget() {
    use hyotan_operation_harness::MAX_FILE_BYTES;
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let missing = f.h.metadata(c, &f.scope, Path::new("missing")).unwrap_err();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    assert_eq!(missing.to_string(), "operation failed");
    f.h.mkdir(c, &f.scope, Path::new("tree")).unwrap();
    let duplicate = f.h.mkdir(c, &f.scope, Path::new("tree")).unwrap_err();
    assert_eq!(duplicate.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(duplicate.to_string(), "operation failed");
    for n in 0..5 {
        fs::File::create(f.work.join("tree").join(n.to_string()))
            .unwrap()
            .set_len(MAX_FILE_BYTES as u64)
            .unwrap();
    }
    denied(f.h.copy(c, &f.scope, Path::new("tree"), Path::new("copy"), true));
    f.unchanged();
}
#[test]
fn recursive_entry_budget() {
    use hyotan_operation_harness::MAX_RECURSIVE_ENTRIES;
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    fs::create_dir(f.work.join("tree")).unwrap();
    for sub in ["a", "b"] {
        fs::create_dir(f.work.join("tree").join(sub)).unwrap();
        for n in 0..MAX_RECURSIVE_ENTRIES / 2 {
            fs::write(f.work.join("tree").join(sub).join(n.to_string()), b"").unwrap();
        }
    }
    denied(f.h.remove(c, &f.scope, Path::new("tree"), true));
    f.unchanged();
}
