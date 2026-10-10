use hyotan_operation_harness::{
    Access, DescriptorLimits, FileAccess, Harness, MAX_FILE_BYTES, MAX_HANDLE_CHUNK, OpenOptions,
    Scope,
};
use std::{
    fs::{self, File},
    io,
    os::unix::fs::{MetadataExt, symlink},
    path::Path,
};
fn denied<T>(r: io::Result<T>) {
    assert_eq!(
        r.err().expect("must deny").kind(),
        io::ErrorKind::PermissionDenied
    );
}
fn opts() -> OpenOptions {
    OpenOptions {
        access: FileAccess::ReadWrite,
        create: false,
        exclusive: false,
        truncate: false,
        append: false,
    }
}
#[test]
fn sparse_four_gib_streaming_separate_bulk_limits_retained_identity_and_revocation() {
    let base = std::env::temp_dir().join(format!("hyotan-large-policy-{}", std::process::id()));
    fs::create_dir_all(base.join("work")).unwrap();
    fs::create_dir_all(base.join("private")).unwrap();
    let work = base.join("work");
    let canary = base.join("private/canary");
    fs::write(&canary, b"untouched").unwrap();
    let extent = 4u64 * 1024 * 1024 * 1024;
    let file = work.join("日本語.bin");
    File::create(&file).unwrap().set_len(extent).unwrap();
    let h = Harness::default();
    let s = Scope {
        owner: "trusted".into(),
        generation: 7,
    };
    let default = h.grant(&work, s.clone(), Access::ReadWrite).unwrap();
    denied(h.open_handle(
        default,
        &s,
        Path::new("日本語.bin"),
        OpenOptions::read_only(),
    ));
    let compatible = h
        .open_read_stream_handle(default, &s, Path::new("日本語.bin"))
        .unwrap();
    assert_eq!(
        h.read_at(default, &s, compatible, extent - 2, 16).unwrap(),
        [0, 0]
    );
    assert_eq!(
        h.read_range(default, &s, Path::new("日本語.bin"), extent - 2, 16)
            .unwrap(),
        [0, 0]
    );
    h.close_handle(default, &s, compatible).unwrap();
    let limits = DescriptorLimits::new(extent, extent).unwrap();
    let cap = h
        .grant_with_descriptor_limits(&work, s.clone(), Access::ReadWrite, limits)
        .unwrap();
    let fd = h
        .open_stream_handle(cap, &s, Path::new("日本語.bin"), opts())
        .unwrap();
    h.truncate_handle(cap, &s, fd, 0).unwrap();
    h.truncate_handle(cap, &s, fd, extent).unwrap();
    assert_eq!(h.stat_handle(cap, &s, fd).unwrap().bytes, extent);
    for off in [2u64 * 1024 * 1024 * 1024 + 3, extent - 4] {
        assert_eq!(h.write_at(cap, &s, fd, off, b"a\0\xffz").unwrap(), 4);
        assert_eq!(
            h.read_at(cap, &s, fd, off, 16).unwrap().get(..4).unwrap(),
            b"a\0\xffz"
        );
    }
    assert!(
        h.read_at(cap, &s, fd, extent, MAX_HANDLE_CHUNK)
            .unwrap()
            .is_empty()
    );
    denied(h.read_at(cap, &s, fd, extent + 1, 1));
    denied(h.write_at(cap, &s, fd, extent, b"x"));
    denied(h.truncate_handle(cap, &s, fd, extent + 1));
    denied(h.read_at(cap, &s, fd, 0, MAX_HANDLE_CHUNK + 1));
    denied(h.read_at(cap, &s, fd, u64::MAX, 1));
    denied(h.read(cap, &s, Path::new("日本語.bin")));
    denied(h.copy(
        cap,
        &s,
        Path::new("日本語.bin"),
        Path::new("copy.bin"),
        false,
    ));
    assert!(
        fs::metadata(&file).unwrap().blocks() * 512 < 1024 * 1024,
        "must remain sparse"
    );
    fs::rename(&file, work.join("original.bin")).unwrap();
    fs::write(&file, b"replacement").unwrap();
    assert_eq!(h.read_at(cap, &s, fd, extent - 4, 4).unwrap(), b"a\0\xffz");
    let other = Scope {
        owner: "foreign".into(),
        generation: 7,
    };
    denied(h.read_at(cap, &other, fd, 0, 1));
    let stale = Scope {
        owner: s.owner.clone(),
        generation: 8,
    };
    denied(h.read_at(cap, &stale, fd, 0, 1));
    symlink(&canary, work.join("link")).unwrap();
    denied(h.open_read_stream_handle(cap, &s, Path::new("link")));
    denied(h.open_read_stream_handle(cap, &s, Path::new("../private/canary")));
    fs::hard_link(&canary, work.join("hard")).unwrap();
    denied(h.open_read_stream_handle(cap, &s, Path::new("hard")));
    h.revoke(cap, &s).unwrap();
    denied(h.read_at(cap, &s, fd, 0, 1));
    let fresh = h
        .grant_with_descriptor_limits(&work, s.clone(), Access::ReadWrite, limits)
        .unwrap();
    let fresh_fd = h
        .open_read_stream_handle(fresh, &s, Path::new("日本語.bin"))
        .unwrap();
    assert_eq!(
        h.read_at(fresh, &s, fresh_fd, 0, 32).unwrap(),
        b"replacement"
    );
    denied(h.read_at(fresh, &s, fd, 0, 1));
    assert_eq!(fs::read(&canary).unwrap(), b"untouched");
    let owned = h
        .grant_from_owned_directory_with_descriptor_limits(
            File::open(&work).unwrap(),
            s.clone(),
            Access::ReadOnly,
            limits,
        )
        .unwrap();
    let owned_fd = h
        .open_read_stream_handle(owned, &s, Path::new("original.bin"))
        .unwrap();
    assert_eq!(
        h.read_at(owned, &s, owned_fd, extent - 4, 4).unwrap(),
        b"a\0\xffz"
    );
    denied(h.write_at(owned, &s, owned_fd, 0, b"x"));
    fs::remove_dir_all(base).unwrap();
}
#[test]
fn asymmetric_limits_signed_offsets_and_defaults() {
    denied(DescriptorLimits::new(0, 1));
    denied(DescriptorLimits::new(1, 0));
    denied(DescriptorLimits::new(u64::MAX, 1));
    denied(DescriptorLimits::new(1, u64::MAX));
    let defaults = DescriptorLimits::default();
    assert_eq!(defaults.read_extent(), libc::off_t::MAX as u64);
    assert_eq!(defaults.write_extent(), MAX_FILE_BYTES as u64);
    let base =
        std::env::temp_dir().join(format!("hyotan-asymmetric-policy-{}", std::process::id()));
    fs::create_dir_all(&base).unwrap();
    fs::write(base.join("f"), [0; 32]).unwrap();
    let h = Harness::default();
    let s = Scope {
        owner: "trusted".into(),
        generation: 1,
    };
    let c = h
        .grant_with_descriptor_limits(
            &base,
            s.clone(),
            Access::ReadWrite,
            DescriptorLimits::new(16, 64).unwrap(),
        )
        .unwrap();
    let f = h.open_stream_handle(c, &s, Path::new("f"), opts()).unwrap();
    assert_eq!(h.read_at(c, &s, f, 15, 32).unwrap(), [0]);
    assert!(h.read_at(c, &s, f, 16, 32).unwrap().is_empty());
    denied(h.read_at(c, &s, f, 17, 1));
    assert_eq!(h.write_at(c, &s, f, 63, b"z").unwrap(), 1);
    denied(h.write_at(c, &s, f, 64, b"z"));
    denied(h.open_read_stream_handle(c, &s, Path::new("f")));
    denied(h.read_range(c, &s, Path::new("f"), 0, 1));
    h.truncate_handle(c, &s, f, 16).unwrap();
    assert!(
        h.read_range(c, &s, Path::new("f"), 16, 32)
            .unwrap()
            .is_empty()
    );
    denied(h.read_range(c, &s, Path::new("f"), 17, 1));
    fs::remove_dir_all(base).unwrap();
}
