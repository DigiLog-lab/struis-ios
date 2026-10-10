use hyotan_operation_harness::{
    Access, FileAccess, FileHandle, Harness, MAX_FILE_BYTES, MAX_HANDLE_CHUNK,
    MAX_HANDLES_PER_GRANT, MAX_TOTAL_HANDLES, OpenOptions, Scope,
};
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
    s: Scope,
}
impl Fixture {
    fn new() -> Self {
        let base = std::env::temp_dir().join(format!(
            "hyotan-handles-{}-{}",
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
            s: Scope {
                owner: "parent".into(),
                generation: 9,
            },
        }
    }
    fn cap(&self, access: Access) -> hyotan_operation_harness::Capability {
        self.h.grant(&self.work, self.s.clone(), access).unwrap()
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
fn deny<T>(r: io::Result<T>) {
    let e = match r {
        Ok(_) => panic!("unexpected success"),
        Err(e) => e,
    };
    assert_eq!(e.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(e.to_string(), "operation denied");
}
fn options(access: FileAccess) -> OpenOptions {
    OpenOptions {
        access,
        create: false,
        exclusive: false,
        truncate: false,
        append: false,
    }
}
#[test]
fn japanese_random_access_exclusive_truncate_append() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let p = Path::new("日本語.txt");
    let mut opts = options(FileAccess::ReadWrite);
    opts.create = true;
    opts.exclusive = true;
    let fd = f.h.open_handle(c, &f.s, p, opts).unwrap();
    assert_eq!(f.h.write_at(c, &f.s, fd, 0, b"abcdef").unwrap(), 6);
    assert_eq!(f.h.read_at(c, &f.s, fd, 2, 3).unwrap(), b"cde");
    f.h.write_at(c, &f.s, fd, 2, b"XY").unwrap();
    assert_eq!(f.h.read_at(c, &f.s, fd, 0, 6).unwrap(), b"abXYef");
    let exists = f.h.open_handle(c, &f.s, p, opts).unwrap_err();
    assert_eq!(exists.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(exists.to_string(), "operation failed");
    f.h.truncate_handle(c, &f.s, fd, 3).unwrap();
    assert_eq!(f.h.stat_handle(c, &f.s, fd).unwrap().bytes, 3);
    f.h.close_handle(c, &f.s, fd).unwrap();
    let mut append = options(FileAccess::WriteOnly);
    append.append = true;
    let fd = f.h.open_handle(c, &f.s, p, append).unwrap();
    f.h.write_at(c, &f.s, fd, 0, b"tail").unwrap();
    assert_eq!(fs::read(f.work.join(p)).unwrap(), b"abXtail");
    deny(f.h.read_at(c, &f.s, fd, 0, 1));
    f.h.close_handle(c, &f.s, fd).unwrap();
    let mut truncate = options(FileAccess::WriteOnly);
    truncate.truncate = true;
    let fd = f.h.open_handle(c, &f.s, p, truncate).unwrap();
    assert_eq!(f.h.stat_handle(c, &f.s, fd).unwrap().bytes, 0);
    f.h.close_handle(c, &f.s, fd).unwrap();
    f.unchanged();
}
#[test]
fn file_modes_and_readonly_grants() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"original").unwrap();
    let ro = f.cap(Access::ReadOnly);
    let fd =
        f.h.open_handle(ro, &f.s, Path::new("ok"), OpenOptions::read_only())
            .unwrap();
    assert_eq!(f.h.read_at(ro, &f.s, fd, 0, 8).unwrap(), b"original");
    deny(f.h.write_at(ro, &f.s, fd, 0, b"bad"));
    deny(f.h.truncate_handle(ro, &f.s, fd, 0));
    for access in [FileAccess::WriteOnly, FileAccess::ReadWrite] {
        deny(f.h.open_handle(ro, &f.s, Path::new("ok"), options(access)));
    }
    for option in [
        OpenOptions {
            create: true,
            ..OpenOptions::read_only()
        },
        OpenOptions {
            truncate: true,
            ..OpenOptions::read_only()
        },
        OpenOptions {
            append: true,
            ..OpenOptions::read_only()
        },
        OpenOptions {
            exclusive: true,
            ..OpenOptions::read_only()
        },
    ] {
        deny(f.h.open_handle(ro, &f.s, Path::new("ok"), option));
    }
    let rw = f.cap(Access::ReadWrite);
    let fd =
        f.h.open_handle(rw, &f.s, Path::new("ok"), OpenOptions::read_only())
            .unwrap();
    deny(f.h.write_at(rw, &f.s, fd, 0, b"bad"));
    deny(f.h.truncate_handle(rw, &f.s, fd, 0));
    assert_eq!(fs::read(f.work.join("ok")).unwrap(), b"original");
    f.unchanged();
}
#[test]
fn closed_revoked_wrong_scope_capability_foreign_handles() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"ok").unwrap();
    let c = f.cap(Access::ReadWrite);
    let other_cap = f.cap(Access::ReadWrite);
    let fd =
        f.h.open_handle(c, &f.s, Path::new("ok"), options(FileAccess::ReadWrite))
            .unwrap();
    for s in [
        Scope {
            owner: "child".into(),
            generation: 9,
        },
        Scope {
            owner: "parent".into(),
            generation: 10,
        },
    ] {
        deny(f.h.read_at(c, &s, fd, 0, 2));
        deny(f.h.write_at(c, &s, fd, 0, b"bad"));
        deny(f.h.stat_handle(c, &s, fd));
        deny(f.h.truncate_handle(c, &s, fd, 0));
        deny(f.h.close_handle(c, &s, fd));
    }
    deny(f.h.read_at(other_cap, &f.s, fd, 0, 2));
    deny(f.h.write_at(other_cap, &f.s, fd, 0, b"bad"));
    deny(f.h.close_handle(other_cap, &f.s, fd));
    let foreign = Harness::default();
    let foreign_cap = foreign
        .grant(&f.work, f.s.clone(), Access::ReadWrite)
        .unwrap();
    let foreign_fd = foreign
        .open_handle(foreign_cap, &f.s, Path::new("ok"), OpenOptions::read_only())
        .unwrap();
    assert_ne!(fd, foreign_fd);
    deny(f.h.read_at(c, &f.s, foreign_fd, 0, 2));
    deny(foreign.read_at(foreign_cap, &f.s, fd, 0, 2));
    f.h.close_handle(c, &f.s, fd).unwrap();
    deny(f.h.read_at(c, &f.s, fd, 0, 2));
    deny(f.h.close_handle(c, &f.s, fd));
    let next =
        f.h.open_handle(c, &f.s, Path::new("ok"), options(FileAccess::ReadWrite))
            .unwrap();
    assert_ne!(fd, next);
    f.h.revoke(c, &f.s).unwrap();
    deny(f.h.read_at(c, &f.s, next, 0, 2));
    deny(f.h.write_at(c, &f.s, next, 0, b"bad"));
    deny(f.h.stat_handle(c, &f.s, next));
    deny(f.h.truncate_handle(c, &f.s, next, 0));
    deny(f.h.close_handle(c, &f.s, next));
    assert_eq!(fs::read(f.work.join("ok")).unwrap(), b"ok");
    f.unchanged();
}
#[test]
fn opened_object_survives_path_replacement_and_alias_checks() {
    let f = Fixture::new();
    fs::write(f.work.join("original"), b"allowed").unwrap();
    let c = f.cap(Access::ReadWrite);
    let fd =
        f.h.open_handle(
            c,
            &f.s,
            Path::new("original"),
            options(FileAccess::ReadWrite),
        )
        .unwrap();
    fs::rename(f.work.join("original"), f.work.join("renamed")).unwrap();
    symlink(f.private.join("canary"), f.work.join("original")).unwrap();
    assert_eq!(f.h.read_at(c, &f.s, fd, 0, 7).unwrap(), b"allowed");
    f.h.write_at(c, &f.s, fd, 0, b"changed").unwrap();
    assert_eq!(fs::read(f.work.join("renamed")).unwrap(), b"changed");
    deny(f.h.open_handle(
        c,
        &f.s,
        Path::new("original"),
        options(FileAccess::ReadWrite),
    ));
    fs::hard_link(f.work.join("renamed"), f.work.join("alias")).unwrap();
    deny(f.h.read_at(c, &f.s, fd, 0, 7));
    deny(f.h.write_at(c, &f.s, fd, 0, b"bad"));
    deny(f.h.stat_handle(c, &f.s, fd));
    f.h.close_handle(c, &f.s, fd).unwrap();
    f.unchanged();
}
#[test]
fn escapes_special_files_and_limits() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    symlink(&f.private, f.work.join("ancestor")).unwrap();
    fs::hard_link(f.private.join("canary"), f.work.join("hard")).unwrap();
    let fifo = std::ffi::CString::new(f.work.join("fifo").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    for path in [
        "../private/canary",
        "/private/canary",
        "bad\0path",
        "ancestor/canary",
        "hard",
        "fifo",
    ] {
        deny(f.h.open_handle(c, &f.s, Path::new(path), options(FileAccess::ReadWrite)));
    }
    let mut create = options(FileAccess::ReadWrite);
    create.create = true;
    let fd = f.h.open_handle(c, &f.s, Path::new("ok"), create).unwrap();
    deny(f.h.read_at(c, &f.s, fd, u64::MAX, 1));
    deny(f.h.read_at(c, &f.s, fd, 0, MAX_HANDLE_CHUNK + 1));
    deny(f.h.write_at(c, &f.s, fd, MAX_FILE_BYTES as u64, b"x"));
    deny(f.h.truncate_handle(c, &f.s, fd, MAX_FILE_BYTES as u64 + 1));
    f.h.write_at(c, &f.s, fd, MAX_FILE_BYTES as u64 - 1, b"x")
        .unwrap();
    assert_eq!(
        f.h.stat_handle(c, &f.s, fd).unwrap().bytes,
        MAX_FILE_BYTES as u64
    );
    let mut append = options(FileAccess::WriteOnly);
    append.append = true;
    let append_fd = f.h.open_handle(c, &f.s, Path::new("ok"), append).unwrap();
    deny(f.h.write_at(c, &f.s, append_fd, 0, b"x"));
    f.h.truncate_handle(c, &f.s, fd, 0).unwrap();
    let missing =
        f.h.open_handle(c, &f.s, Path::new("missing"), OpenOptions::read_only())
            .unwrap_err();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    f.unchanged();
}
#[test]
fn handle_budgets_and_revoke_releases_capacity() {
    let f = Fixture::new();
    fs::write(f.work.join("ok"), b"ok").unwrap();
    let mut grants = Vec::new();
    let mut handles: Vec<FileHandle> = Vec::new();
    for _ in 0..MAX_TOTAL_HANDLES / MAX_HANDLES_PER_GRANT {
        let c = f.cap(Access::ReadWrite);
        for _ in 0..MAX_HANDLES_PER_GRANT {
            handles.push(
                f.h.open_handle(c, &f.s, Path::new("ok"), OpenOptions::read_only())
                    .unwrap(),
            );
        }
        deny(f.h.open_handle(c, &f.s, Path::new("ok"), OpenOptions::read_only()));
        grants.push(c);
    }
    let extra = f.cap(Access::ReadWrite);
    deny(f.h.open_handle(extra, &f.s, Path::new("ok"), OpenOptions::read_only()));
    f.h.revoke(grants[0], &f.s).unwrap();
    let fd =
        f.h.open_handle(extra, &f.s, Path::new("ok"), OpenOptions::read_only())
            .unwrap();
    deny(f.h.read_at(grants[0], &f.s, handles[0], 0, 1));
    f.h.close_handle(extra, &f.s, fd).unwrap();
    f.unchanged();
}

#[test]
fn read_only_create_requires_mutable_grant_but_handle_stays_read_only() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let fd =
        f.h.open_handle(
            c,
            &f.s,
            Path::new("created"),
            OpenOptions {
                create: true,
                exclusive: true,
                ..OpenOptions::read_only()
            },
        )
        .unwrap();
    assert!(f.h.read_at(c, &f.s, fd, 0, 1).unwrap().is_empty());
    deny(f.h.write_at(c, &f.s, fd, 0, b"bad"));
    assert!(f.work.join("created").exists());
    f.h.close_handle(c, &f.s, fd).unwrap();
    f.unchanged();
}
