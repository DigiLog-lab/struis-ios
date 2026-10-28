import Foundation
import GRDB

/// Deletion is journalled outside the export roots. Before commit it can be rolled back;
/// after commit recovery must finish erasing the originals before AI/export can proceed.
nonisolated enum UnitDeletion {
    static let gate = NSRecursiveLock()
    struct Scope: Codable, Sendable {
        var ids: [String: Set<String>] = [:]
        var codexIds: Set<String> = []
        var codexIDs: Set<String> { get { codexIds } set { codexIds = newValue } }
        var all: Set<String> { ids.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
        mutating func add(_ entity: LedgerEntity, _ id: String) { ids[entity.rawValue, default: []].insert(id) }
        func contains(_ entity: LedgerEntity, _ id: String) -> Bool { ids[entity.rawValue]?.contains(id) == true }
    }
    struct Fact: Codable, Sendable {
        var unitId: String
        var title: String
        var deletedAt: String
        var actor: String = "user"
        var operationId: String
        var scope: Scope
        var unitID: String { unitId }
        var operationID: String { operationId }
        init(unitID: String, title: String, deletedAt: String, operationID: String, scope: Scope) {
            self.unitId = unitID; self.title = title; self.deletedAt = deletedAt
            self.operationId = operationID; self.scope = scope
        }
    }
    struct Change: Codable, Sendable {
        var path: String
        var before: Data?
        var after: Data?
    }
    struct Journal: Codable, Sendable {
        var fact: Fact
        var events: [LedgerEvent]
        var changes: [Change]
        var files: [String]
    }
    static func journalURL(_ root: URL) -> URL { root.appendingPathComponent("unit-deletion.json") }
    static func referenceKey(_ key: String?) -> Bool {
        guard let key else { return false }
        return key == "id" || key.hasSuffix("_id") || key.hasSuffix("_ids") || ["child_order", "return_stack", "evidence_refs", "relative_path", "path"].contains(key)
    }
    static let idMaps: Set<String> = ["goals", "problems", "attempts", "events", "stages"]
    static func references(_ value: LedgerJSON, key: String? = nil) -> Set<String> {
        switch value {
        case .string(let s): return referenceKey(key) ? [s] : []
        case .array(let a): return a.reduce(into: Set<String>()) { $0.formUnion(references($1, key: key)) }
        case .object(let o): return o.reduce(into: Set<String>()) { result, pair in
            if key.map(idMaps.contains) == true { result.insert(pair.key) }
            result.formUnion(references(pair.value, key: pair.key))
        }
        default: return []
        }
    }
    /// Only exact IDs/evidence references participate; titles and prose are never matched.
    static func scrub(_ value: LedgerJSON, ids: Set<String>, key: String? = nil) -> LedgerJSON {
        switch value {
        case .array(let items): return .array(items.compactMap { item in
            if referenceKey(key), let s = item.stringValue, ids.contains(s) { return nil }
            if let o = item.objectValue, let evidence = (o["evidence_refs"] ?? o["evidence"])?.arrayValue, !evidence.isEmpty,
               evidence.allSatisfy({ !references($0).isDisjoint(with: ids) }) { return nil }
            if let o = item.objectValue, o.contains(where: { key, val in
                ["id", "unit_id", "subunit_id", "problem_id", "message_id", "submission_id", "turn_id", "evidence_id"].contains(key) && val.stringValue.map(ids.contains) == true
            }) { return nil }
            return scrub(item, ids: ids, key: key)
        })
        case .object(let object):
            var cleaned = object.reduce(into: [String: LedgerJSON]()) { result, pair in
                guard key.map(idMaps.contains) != true || !ids.contains(pair.key) else { return }
                if referenceKey(pair.key), let s = pair.value.stringValue, ids.contains(s) { result[pair.key] = .null }
                else { result[pair.key] = scrub(pair.value, ids: ids, key: pair.key) }
            }
            if object["current_goal_id"]?.stringValue.map(ids.contains) == true || object["waiting_problem_id"]?.stringValue.map(ids.contains) == true {
                cleaned["next_action"] = .string("")
                cleaned["wait_reason"] = .string("")
                cleaned["waiting_for"] = .null
                cleaned["disposition"] = .string("not_learning")
            }
            return .object(cleaned)
        default: return value
        }
    }
    static func rows(_ db: Database) throws -> [LedgerEvent] {
        var result: [LedgerEvent] = []
        func add<R: LedgerRow>(_ type: R.Type) throws { result += try R.fetchAll(db).map { .upsert("deletion.sanitized", $0) } }
        try add(WorkbookUnitRecord.self); try add(WorkbookSubunitRecord.self)
        try add(WorkbookProblemRecord.self); try add(WorkbookSetRecord.self)
        try add(WorkbookCaptureRecord.self); try add(WorkbookAttemptRecord.self)
        try add(WorkbookProposalRecord.self); try add(ThreadRecord.self); try add(MessageRecord.self)
        try add(ProgressRevisionRecord.self); try add(TurnRecord.self); try add(CodexThreadRecord.self)
        try add(ThreadBranchRecord.self); try add(BranchForkAttemptRecord.self)
        try add(TimelineSkillRecord.self); try add(TimelineSkillEdgeRecord.self); try add(TimelineMapChangeRecord.self)
        try add(TimelineBatchRecord.self); try add(TimelineCardRecord.self); try add(TimelineAttemptRecord.self)
        try add(TimelineDipRecord.self); try add(TimelineLogRecord.self)
        return result
    }
    static func scope(db: Database, unitID: String) throws -> Scope {
        let snapshots = try rows(db)
        var scope = Scope(); scope.add(.workbookUnits, unitID)
        for e in snapshots where e.entity == .workbookSubunits && e.payload["unit_id"]?.stringValue == unitID { scope.add(e.entity, e.entityID) }
        for e in snapshots where [.workbookProblems, .workbookSets, .workbookAttempts].contains(e.entity) {
            if e.payload["subunit_id"]?.stringValue.map({ scope.contains(.workbookSubunits, $0) }) == true {
                scope.add(e.entity, e.entityID)
                if e.entity == .workbookAttempts, let problem = e.payload["problem_id"]?.stringValue { scope.add(.workbookProblems, problem) }
            }
        }
        let targetSubunits = snapshots.filter { scope.contains(.workbookSubunits, $0.entityID) && $0.entity == .workbookSubunits }
        for subunit in targetSubunits {
            guard let thread = subunit.payload["metadata"]?["thread_id"]?.stringValue else { continue }
            if !snapshots.contains(where: { $0.entity == .workbookSubunits && !scope.contains(.workbookSubunits, $0.entityID) && $0.payload["metadata"]?["thread_id"]?.stringValue == thread }) { scope.add(.threads, thread) }
        }
        var changed = true
        while changed {
            let before = scope.all
            for e in snapshots where e.entity == .threadBranches {
                if e.payload["stem_thread_id"]?.stringValue.map({ scope.contains(.threads, $0) }) == true || e.payload["branch_thread_id"]?.stringValue.map({ scope.contains(.threads, $0) }) == true {
                    scope.add(e.entity, e.entityID)
                    if let id = e.payload["branch_thread_id"]?.stringValue,
                       !snapshots.contains(where: { $0.entity == .workbookSubunits && !scope.contains(.workbookSubunits, $0.entityID) && $0.payload["metadata"]?["thread_id"]?.stringValue == id }) { scope.add(.threads, id) }
                }
            }
            changed = before != scope.all
        }
        for e in snapshots where e.entity == .workbookProposals && e.payload["unit_id"]?.stringValue == unitID { scope.add(e.entity, e.entityID) }
        // タイムライン: その単元の「できること」と線、その小単元に数えるカードとその解答。
        for e in snapshots where e.entity == .timelineSkills && e.payload["unit_id"]?.stringValue == unitID { scope.add(e.entity, e.entityID) }
        for e in snapshots where e.entity == .timelineSkillEdges {
            if [e.payload["skill_id"]?.stringValue, e.payload["requires_skill_id"]?.stringValue].contains(where: { $0.map { scope.contains(.timelineSkills, $0) } == true }) { scope.add(e.entity, e.entityID) }
        }
        for e in snapshots where e.entity == .timelineCards {
            if e.payload["subunit_id"]?.stringValue.map({ scope.contains(.workbookSubunits, $0) }) == true || e.payload["unit_id"]?.stringValue == unitID { scope.add(e.entity, e.entityID) }
        }
        for e in snapshots where e.entity == .timelineAttempts && e.payload["card_id"]?.stringValue.map({ scope.contains(.timelineCards, $0) }) == true { scope.add(e.entity, e.entityID) }
        // 今日の記録: その単元の一覧と、その解答の文。
        for e in snapshots where e.entity == .timelineLog {
            if e.payload["unit_id"]?.stringValue == unitID || e.payload["attempt_id"]?.stringValue.map({ scope.contains(.timelineAttempts, $0) }) == true { scope.add(e.entity, e.entityID) }
        }
        for e in snapshots where [.messages, .codexThreads, .branchForkAttempts].contains(e.entity) {
            let thread = e.payload["thread_id"]?.stringValue ?? e.payload["stem_thread_id"]?.stringValue
            if thread.map({ scope.contains(.threads, $0) }) == true { scope.add(e.entity, e.entityID) }
        }
        let attempts = snapshots.filter { $0.entity == .workbookAttempts }
        for e in snapshots where e.entity == .workbookCaptures {
            let attached = attempts.filter { $0.payload["capture_id"]?.stringValue == e.entityID }
            let target = attached.contains { scope.contains(.workbookAttempts, $0.entityID) } || e.payload["subunit_id"]?.stringValue.map({ scope.contains(.workbookSubunits, $0) }) == true || e.payload["context"]?["subunit_id"]?.stringValue.map({ scope.contains(.workbookSubunits, $0) }) == true
            // A free/unclassified photo's list of available units does not establish ownership.
            let shared = attached.contains { !scope.contains(.workbookAttempts, $0.entityID) } || references(e.payload["candidates"] ?? .null).contains { id in snapshots.contains { $0.entity == .workbookSubunits && $0.entityID == id && !scope.contains(.workbookSubunits, id) } }
            if target && !shared { scope.add(.workbookCaptures, e.entityID) }
        }
        for e in snapshots where e.entity == .turns {
            let target = e.payload["target_id"]?.stringValue
            let thread = e.payload["thread_id"]?.stringValue
            if target.map(scope.all.contains) == true || thread.map({ scope.contains(.threads, $0) }) == true || !references(e.payload["plan"] ?? .null).isDisjoint(with: scope.all) { scope.add(e.entity, e.entityID) }
        }
        for e in snapshots where scope.contains(e.entity, e.entityID) {
            if let id = e.payload["codex_thread_id"]?.stringValue { scope.codexIDs.insert(id) }
        }
        // Shared chat turns may carry their original thread ID; only dedicated mappings can erase it.
        let sharedCodex = snapshots.filter { $0.entity == .codexThreads && !scope.contains(.codexThreads, $0.entityID) }.compactMap { $0.payload["codex_thread_id"]?.stringValue }
        scope.codexIDs.subtract(sharedCodex)
        return scope
    }
    static func prepare(db: Database, root: URL, unitID: String, extraCodexIDs: Set<String>, runtimeRoots: [URL]) throws -> Journal {
        guard let unit = try WorkbookUnitRecord.fetchOne(db, key: unitID) else { throw LedgerError.notFound("単元") }
        var scope = try scope(db: db, unitID: unitID); scope.codexIDs.formUnion(extraCodexIDs)
        let snapshots = try rows(db)
        var fact = Fact(unitID: unitID, title: unit.title, deletedAt: LedgerClock.now(), operationID: UUID().uuidString, scope: scope)
        var events: [LedgerEvent] = []; var files: [String] = []
        var ids = scope.all
        // Goal ownership is established from exact evidence IDs. Shared/unknown goals are retained.
        for e in snapshots where e.entity == .learningProgress {
            for (id, goal) in e.payload["state"]?["goals"]?.objectValue ?? [:] {
                let evidence = goal["evidence"]?.arrayValue ?? []
                if !evidence.isEmpty && evidence.allSatisfy({ !references($0).isDisjoint(with: ids) }) { ids.insert(id) }
            }
        }
        var expanded = true
        while expanded {
            let old = ids
            for e in snapshots where e.entity == .learningProgress {
                for key in ["goals", "problems", "attempts", "events"] {
                    for (id, row) in e.payload["state"]?[key]?.objectValue ?? [:] {
                        // A shared/unknown child goal survives even when its parent is removed.
                        if key == "goals" { continue }
                        if ["goal_id", "problem_id", "submission_id"].contains(where: { row[$0]?.stringValue.map(ids.contains) == true }) { ids.insert(id) }
                    }
                }
            }
            expanded = old != ids
        }
        let history = try StoredLedgerEvent.fetchAll(db).compactMap(\.event)
        let affectedKeys = Set(history.filter { !references($0.payload).isDisjoint(with: ids) }.map { $0.entity.rawValue + ":" + $0.entityID })
        for event in snapshots {
            if scope.contains(event.entity, event.entityID) {
                events.append(.delete("unit.cascade_deleted", entity: event.entity, entityID: event.entityID))
                if event.entity == .messages {
                    let attachments = (event.payload["metadata"]?["attachments"]?.arrayValue ?? []) + (event.payload["metadata"]?["model_attachments"]?.arrayValue ?? [])
                    for attachment in attachments {
                        guard let path = attachment["relative_path"]?.stringValue ?? attachment["path"]?.stringValue,
                              !snapshots.contains(where: { $0.entity == .messages && !scope.contains($0.entity, $0.entityID) && references($0.payload).contains(path) }) else { continue }
                        let attachmentRoot = root.appendingPathComponent("attachments").standardizedFileURL
                        let file = attachmentRoot.appendingPathComponent(path).standardizedFileURL
                        if file.path.hasPrefix(attachmentRoot.path + "/") { files.append(file.path) }
                        if attachment["kind"]?.stringValue == ChatTurns.Attachment.pageImageKind,
                           let hash = attachment["sha256"]?.stringValue, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                           !snapshots.contains(where: { $0.entity == .messages && !scope.contains($0.entity, $0.entityID) && $0.payload.canonicalText.contains(hash) }) {
                            let cache = attachmentRoot.appendingPathComponent("runtime-page-images-v1/" + hash + ".jpg")
                            files += [cache.path, cache.appendingPathExtension("sha256").path]
                        }
                    }
                }
                if event.entity == .workbookCaptures, let path = event.payload["image_path"]?.stringValue {
                    if !snapshots.contains(where: { $0.entity == .workbookCaptures && !scope.contains($0.entity, $0.entityID) && $0.payload["image_path"]?.stringValue == path }) {
                        // まとめて撮った答案(一括採点)は、2 枚目からの写真も消す。
                        let pages = (event.payload["context"]?["page_paths"]?.arrayValue ?? []).compactMap(\.stringValue)
                        for page in Set([path] + pages) {
                            let file = root.appendingPathComponent("captures").appendingPathComponent(page).standardizedFileURL
                            guard file.path.hasPrefix(root.standardizedFileURL.path + "/captures/") else { throw LedgerError.invalid("答案の保存先が不正です") }
                            files.append(file.path)
                        }
                    }
                }
                // タイムラインの答案の写真と、モデルに見せた部分(`timeline_views/<答案>-*.jpg`)も消す (Issue #57)。
                if event.entity == .timelineAttempts {
                    let captures = root.appendingPathComponent("captures").standardizedFileURL
                    if let path = event.payload["capture_path"]?.stringValue, !path.isEmpty,
                       !snapshots.contains(where: { $0.entity == .timelineAttempts && !scope.contains($0.entity, $0.entityID) && $0.payload["capture_path"]?.stringValue == path }) {
                        let file = captures.appendingPathComponent(path).standardizedFileURL
                        guard file.path.hasPrefix(captures.path + "/") else { throw LedgerError.invalid("答案の保存先が不正です") }
                        files.append(file.path)
                    }
                    let views = captures.appendingPathComponent(TimelineCaptureImage.viewDirectory, isDirectory: true)
                    for url in (try? FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix(event.entityID + "-") {
                        files.append(url.standardizedFileURL.path)
                    }
                }
            } else if !references(event.payload).isDisjoint(with: ids) || affectedKeys.contains(event.entity.rawValue + ":" + event.entityID) {
                var payload = scrub(event.payload, ids: ids)
                if event.entity == .workbookCaptures, var object = payload.objectValue {
                    let remaining = snapshots.filter { $0.entity == .workbookAttempts && !scope.contains($0.entity, $0.entityID) && $0.payload["capture_id"]?.stringValue == event.entityID }
                    let primaryRemoved = event.payload["subunit_id"]?.stringValue.map({ scope.contains(.workbookSubunits, $0) }) == true
                    if primaryRemoved {
                        object["subunit_id"] = remaining.first?.payload["subunit_id"] ?? .null
                        object["set_id"] = remaining.first?.payload["set_id"] ?? .null
                        if remaining.isEmpty { object["status"] = .string("triage") }
                    }
                    let correct = remaining.filter { $0.payload["verdict"]?.stringValue == "correct" }.count
                    let result: LedgerJSON = .object(["correct": .number(Double(correct)), "total": .number(Double(remaining.count)), "score": .number(remaining.isEmpty ? 0 : Double(correct) / Double(remaining.count)), "passed": .bool(!remaining.isEmpty && correct == remaining.count)])
                    var summary = (payload["summary"] ?? .null).objectValue ?? [:]
                    if !remaining.isEmpty { summary["result"] = result }
                    if primaryRemoved {
                        // The old stage/window/outcome described the deleted primary unit.
                        summary = remaining.isEmpty ? [:] : ["result": result]
                    }
                    object["summary"] = .object(summary)
                    payload = .object(object)
                }
                events.append(LedgerEvent(kind: "unit.references_removed", entity: event.entity, entityID: event.entityID, payload: payload))
            }
        }
        // Invalidate every in-flight progress snapshot even when this workbook has no chat goals.
        let latest = try ProgressRevisionRecord.order(Column("revision").desc).fetchOne(db)
        let revision = (latest?.revision ?? 0) + 1
        var state = scrub(latest?.state ?? LedgerJSON(any: LearningProgress.emptyState().json.anyValue), ids: ids).objectValue ?? [:]
        state["revision"] = .number(Double(revision))
        events.append(.upsert("unit.progress_invalidated", ProgressRevisionRecord(revision: revision, state: .object(state), messageId: nil, turnId: nil, savedAt: fact.deletedAt)))
        fact.scope.ids["progress_ids"] = ids.subtracting(scope.all)
        let factJSON = LedgerEvent.encode(fact)
        var marker = factJSON.objectValue ?? [:]; marker["deleted"] = .bool(true)
        events.append(LedgerEvent(kind: "unit.deleted", entity: .workbookUnits, entityID: unitID, payload: .object(marker)))
        var changes: [Change] = []
        let memory = root.appendingPathComponent("memory/tutor_desk")
        let evidenceIDs = ids.union(ids.map { "attempt:" + $0 }).union(ids.map { "chat_message:" + $0 })
        let memoryRoots = [memory] + runtimeRoots
        for memoryRoot in memoryRoots {
        if let enumerator = FileManager.default.enumerator(at: memoryRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in enumerator where ["yaml", "json"].contains(url.pathExtension) {
                guard memoryRoot == memory || url.path.contains("/tutor_desk/") else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, !url.lastPathComponent.hasPrefix("deletions") else { continue }
                let data = try Data(contentsOf: url)
                let original: LedgerJSON
                if url.pathExtension == "yaml" { original = LedgerJSON(any: try EngineYAML.load(String(decoding: data, as: UTF8.self)).anyValue) }
                else { original = try JSONDecoder().decode(LedgerJSON.self, from: data) }
                guard !references(original).isDisjoint(with: evidenceIDs) else { continue }
                let source = original["source"] ?? original
                let refs = (original["evidence_refs"] ?? original["evidence"])?.arrayValue ?? []
                let dedicated = !references(source).isDisjoint(with: scope.ids[LedgerEntity.threads.rawValue] ?? [])
                    || (!refs.isEmpty && refs.allSatisfy { !references($0).isDisjoint(with: evidenceIDs) })
                let cleaned = scrub(original, ids: evidenceIDs)
                let after = dedicated ? nil : try JSONEncoder().encode(cleaned) // JSON is valid YAML; preserves unknown/shared records.
                changes.append(Change(path: url.path, before: data, after: after))
            }
        }
        }
        let factsURL = memory.appendingPathComponent("current/deletions.yaml")
        let oldFacts = try? Data(contentsOf: factsURL)
        var facts = oldFacts.flatMap { try? JSONDecoder().decode([LedgerJSON].self, from: $0) } ?? []
        // Memory carries facts only, never tombstone internals or erased content.
        facts.insert(.object(["unit_id": .string(fact.unitID), "title": .string(fact.title), "deleted_at": .string(fact.deletedAt), "actor": .string("user"), "operation_id": .string(fact.operationID)]), at: 0)
        changes.append(Change(path: factsURL.path, before: oldFacts, after: try JSONEncoder().encode(facts)))
        // Erase dedicated guest workspaces, rollouts and migration copies. Shared originals remain.
        for runtime in runtimeRoots {
            if let enumerator = FileManager.default.enumerator(at: runtime, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    if scope.codexIDs.contains(where: { url.path.contains($0) }) || scope.ids[LedgerEntity.turns.rawValue, default: []].contains(where: { url.pathComponents.contains($0) }) { files.append(url.path) }
                }
            }
        }
        if root.standardizedFileURL == StruisPaths.root.standardizedFileURL {
            let temp = FileManager.default.temporaryDirectory
            for url in (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("struis-ledger-") && url.pathExtension == "zip" { files.append(url.path) }
        }
        return Journal(fact: fact, events: events, changes: changes, files: Array(Set(files)))
    }
    static func write(_ change: Change, restoring: Bool = false) throws {
        let url = URL(fileURLWithPath: change.path)
        if let data = restoring ? change.before : change.after {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func committed(_ journal: Journal, queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in try StoredLedgerEvent.filter(Column("kind") == "unit.deleted" && Column("entity_id") == journal.fact.unitID).fetchAll(db).contains { $0.event?.payload["operation_id"]?.stringValue == journal.fact.operationID } }
    }
    static func compact(_ queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
    static func recover(queue: DatabaseQueue, root: URL, runtimeRoots: [URL]) throws {
        let url = journalURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        if try committed(journal, queue: queue) {
            for change in journal.changes { try write(change) }
            for path in journal.files where FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            for runtime in runtimeRoots { try eraseIndexes(runtime, ids: journal.fact.scope.codexIDs) }
            try compact(queue)
        } else {
            for change in journal.changes.reversed() { try write(change, restoring: true) }
        }
        try FileManager.default.removeItem(at: url)
    }
    static func eraseIndexes(_ root: URL, ids: Set<String>) throws {
        guard !ids.isEmpty, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { continue }
            if url.lastPathComponent == "history.jsonl" {
                let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
                let kept = lines.filter { line in
                    guard let json = LedgerJSON.parse(String(line)), let id = json["session_id"]?.stringValue else { return true }
                    return !ids.contains(id)
                }
                try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
            } else if url.pathExtension == "sqlite" || url.pathExtension == "sqlite3" {
                let database = try DatabaseQueue(path: url.path)
                try database.write { db in
                    try db.execute(sql: "PRAGMA secure_delete=ON")
                    let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                    for table in tables {
                        let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
                        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(safe)\")").compactMap { $0["name"] as String? }
                        for column in columns where ["thread_id", "session_id"].contains(column) || (table == "threads" && column == "id") {
                            for id in ids { try db.execute(sql: "DELETE FROM \"\(safe)\" WHERE \"\(column)\"=?", arguments: [id]) }
                        }
                    }
                }
                try compact(database)
            }
        }
    }
}
