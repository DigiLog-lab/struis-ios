// Copyright 2026 Hyotan contributors. Apache-2.0.
// Command adapter using ripgrep's MIT-licensed regex/searcher/ignore engines.
use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::FromRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use grep_searcher::{Searcher, SearcherBuilder, Sink, SinkMatch, BinaryDetection};

static RUNNING: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);
#[unsafe(no_mangle)]
pub extern "C" fn hyotan_rg_interrupt() -> bool {
    if RUNNING.load(Ordering::Relaxed) { CANCEL.store(true, Ordering::Relaxed); true } else { false }
}
#[derive(Default)]
struct Options {
    number: bool, insensitive: bool, smart: bool, fixed: bool, invert: bool,
    word: bool, files: bool, list: bool, count: bool, hidden: bool,
    no_ignore: bool, quiet: bool, filename: Option<bool>, patterns: Vec<String>,
    globs: Vec<String>, paths: Vec<PathBuf>,
}
struct Output<'a> { writer: &'a mut dyn Write, options: &'a Options, path: &'a str, filename: bool, found: u64 }
impl Sink for Output<'_> {
    type Error = io::Error;
    fn matched(&mut self, _: &Searcher, mat: &SinkMatch<'_>) -> io::Result<bool> {
        if CANCEL.load(Ordering::Relaxed) { return Ok(false); }
        self.found += 1;
        if self.options.quiet || self.options.list { return Ok(false); }
        if !self.options.count {
            if self.filename { write!(self.writer, "{}:", self.path)?; }
            if self.options.number { write!(self.writer, "{}:", mat.line_number().unwrap_or(1))?; }
            self.writer.write_all(mat.bytes())?;
            if !mat.bytes().ends_with(b"\n") { writeln!(self.writer)?; }
        }
        Ok(true)
    }
}
fn run(args: Vec<String>, input: File, terminal_input: bool, out: &mut File, err: &mut File) -> Result<i32, Box<dyn std::error::Error>> {
    let mut options = Options::default();
    let mut args = args.into_iter(); let mut positional = false;
    while let Some(arg) = args.next() {
        if positional {
            if options.patterns.is_empty() && !options.files { options.patterns.push(arg); }
            else { options.paths.push(arg.into()); }
            continue;
        }
        match arg.as_str() {
            "--" => positional = true,
            "--help" => { writeln!(out, "rg: ripgrep engine for Hyotan\nUsage: rg [OPTIONS] PATTERN [PATH ...]\nSupported: -n -i -S -F -v -w -l -c -q -H --no-filename -e PATTERN -g GLOB --files --hidden --no-ignore\nUse - as PATH for standard input. Unsupported options return status 2.")?; return Ok(0); },
            "--version" => { writeln!(out, "rg (Hyotan adapter; grep-regex 0.1.14, grep-searcher 0.1.17)")?; return Ok(0); },
            "--files" => options.files = true,
            "--hidden" => options.hidden = true,
            "--no-ignore" => options.no_ignore = true,
            "--no-filename" => options.filename = Some(false),
            "--line-number" => options.number = true,
            "--ignore-case" => options.insensitive = true,
            "--fixed-strings" => options.fixed = true,
            "-e" | "--regexp" => options.patterns.push(args.next().ok_or("missing pattern")?),
            "-g" | "--glob" => options.globs.push(args.next().ok_or("missing glob")?),
            _ if arg.starts_with('-') && arg != "-" => {
                for flag in arg[1..].chars() {
                    match flag {
                        'n' => options.number = true, 'i' => options.insensitive = true,
                        'S' => options.smart = true, 'F' => options.fixed = true,
                        'v' => options.invert = true, 'w' => options.word = true,
                        'l' => options.list = true, 'c' => options.count = true,
                        'q' => options.quiet = true, 'H' => options.filename = Some(true),
                        _ => return Err(format!("unsupported option: {arg}; see rg --help").into()),
                    }
                }
            },
            _ if options.patterns.is_empty() && !options.files => options.patterns.push(arg),
            _ => options.paths.push(arg.into()),
        }
    }
    if !options.files && options.patterns.is_empty() { return Err("a pattern is required".into()); }
    if options.paths.is_empty() { options.paths.push(if terminal_input { "." } else { "-" }.into()); }
    let matcher = grep_regex::RegexMatcherBuilder::new().case_insensitive(options.insensitive).case_smart(options.smart).fixed_strings(options.fixed).word(options.word).build_many(&options.patterns)?;
    let multiple = options.paths.len() > 1 || options.paths.iter().any(|p| p.is_dir());
    let mut paths = Vec::new(); let mut failed = false;
    for root in &options.paths {
        if root.to_str() == Some("-") { paths.push(root.clone()); continue; }
        let mut walk = ignore::WalkBuilder::new(root);
        walk.hidden(!options.hidden).standard_filters(!options.no_ignore).follow_links(false);
        // standard_filters also sets hidden; explicitly preserve --hidden.
        walk.hidden(!options.hidden);
        let mut overrides = ignore::overrides::OverrideBuilder::new(std::env::current_dir()?);
        for glob in &options.globs { overrides.add(glob)?; }
        walk.overrides(overrides.build()?);
        for entry in walk.build() {
            if CANCEL.load(Ordering::Relaxed) { return Ok(130); }
            match entry {
                Ok(entry) if entry.file_type().is_some_and(|t| t.is_file()) => paths.push(entry.into_path()),
                Ok(_) => {},
                Err(error) => { writeln!(err, "rg: {error}")?; failed = true; },
            }
        }
    }
    let mut any = false;
    for path in paths {
        if CANCEL.load(Ordering::Relaxed) { return Ok(130); }
        let name = path.to_string_lossy();
        if options.files { writeln!(out, "{name}")?; any = true; continue; }
        let filename = options.filename.unwrap_or(multiple);
        let mut sink = Output { writer: out, options: &options, path: &name, filename, found: 0 };
        let mut searcher = SearcherBuilder::new().line_number(true).invert_match(options.invert).binary_detection(BinaryDetection::quit(0)).build();
        let result = if name == "-" { searcher.search_reader(&matcher, &input, &mut sink) } else { searcher.search_path(&matcher, &path, &mut sink) };
        if let Err(error) = result { writeln!(err, "rg: {name}: {error}")?; failed = true; }
        let found = sink.found;
        any |= found > 0;
        if !options.quiet {
            if options.list && found > 0 { writeln!(out, "{name}")?; }
            else if options.count { if filename { write!(out, "{name}:")?; } writeln!(out, "{found}")?; }
        }
        if options.quiet && any { break; }
    }
    Ok(if CANCEL.load(Ordering::Relaxed) { 130 } else if failed { 2 } else if any { 0 } else { 1 })
}
/// The caller passes duplicated descriptors; this call takes ownership of them.
/// argv must contain argc valid NUL-terminated strings for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hyotan_rg_run(argc: i32, argv: *const *const c_char, stdin: i32, stdout: i32, stderr: i32, terminal_input: bool) -> i32 {
    let input = unsafe { File::from_raw_fd(stdin) };
    let mut out = unsafe { File::from_raw_fd(stdout) };
    let mut err = unsafe { File::from_raw_fd(stderr) };
    if RUNNING.swap(true, Ordering::Relaxed) { let _ = writeln!(err, "rg: another search is running"); return 2; }
    CANCEL.store(false, Ordering::Relaxed);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let args = (1..argc).map(|i| unsafe { CStr::from_ptr(*argv.add(i as usize)) }.to_string_lossy().into_owned()).collect();
        run(args, input, terminal_input, &mut out, &mut err)
    }));
    RUNNING.store(false, Ordering::Relaxed);
    match result { Ok(Ok(code)) => code, Ok(Err(error)) => { let _ = writeln!(err, "rg: {error}"); 2 }, Err(_) => { let _ = writeln!(err, "rg: internal error"); 2 } }
}
