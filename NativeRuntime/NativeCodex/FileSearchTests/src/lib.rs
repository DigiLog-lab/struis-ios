#[path = "../../ios/file_search.rs"]
mod search;
#[cfg(test)]
mod tests {
    use super::search::*;
    use std::{fs, sync::{Arc, Mutex, Condvar}};
    #[test]
    fn searches_real_files_with_unicode_indices_and_exclusions() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("日本語.txt"), "value").unwrap();
        fs::write(dir.path().join("日本語.tmp"), "ignored").unwrap();
        let options = FileSearchOptions { compute_indices: true, exclude: vec!["*.tmp".into()], ..Default::default() };
        let results = run("日語", vec![dir.path().into()], options, None).unwrap();
        assert_eq!(results.total_match_count, 1);
        assert_eq!(results.matches[0].indices, Some(vec![0, 2]));
        assert_eq!(results.matches[0].full_path(), dir.path().join("日本語.txt"));
    }
    struct Reporter { value: Mutex<Option<FileSearchSnapshot>>, changed: Condvar }
    impl SessionReporter for Reporter {
        fn on_update(&self, snapshot: &FileSearchSnapshot) { *self.value.lock().unwrap() = Some(snapshot.clone()); }
        fn on_complete(&self) { self.changed.notify_all(); }
    }
    #[test]
    fn session_reports_updated_query_and_real_scan_count() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("hello.rs"), "value").unwrap();
        let reporter = Arc::new(Reporter { value: Mutex::new(None), changed: Condvar::new() });
        let session = create_session(vec![dir.path().into()], FileSearchOptions::default(), reporter.clone(), None).unwrap();
        session.update_query("hlrs");
        let (result, _) = reporter.changed.wait_timeout_while(reporter.value.lock().unwrap(), std::time::Duration::from_secs(5), |v| v.is_none()).unwrap();
        let result = result.as_ref().expect("search completed");
        assert_eq!(result.query, "hlrs");
        assert_eq!(result.scanned_file_count, 1);
        assert_eq!(result.matches[0].path.to_str(), Some("hello.rs"));
    }
}
