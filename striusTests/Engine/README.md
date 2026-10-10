# Engine vector tests

`strius/Engine/` is the pure-Swift port of the backend "machine" modules
(`learning_progress.py`, the text parts of `codex_runtime.py`, the label/text
helpers of `codex_app_server.py`, `tutor_memory.py`). Correctness is proven by
replaying vectors dumped from the Python implementation:

| Fixture (`striusTests/Fixtures/engine-vectors/`) | Swift module | Test class |
|---|---|---|
| `learning_progress.json` | `LearningProgress.swift` | `LearningProgressVectorTests` |
| `learner_text.json` | `LearnerText.swift` (+ `TutorMemory.extractEmbeddedMemoryUpdate`) | `LearnerTextVectorTests` |
| `turn_progress.json` | `TurnProgress.swift` (`TurnProgress`, `AgentText`) | `TurnProgressVectorTests` |
| `tutor_memory.json` | `TutorMemory.swift` | `TutorMemoryVectorTests` |

`EngineJSON.swift` holds the shared order-preserving JSON value/parser/serializer
(`EngineJSON`, `EngineObject`) and the Python-compatible text/time helpers
(`EnginePyText`, `EnginePyTime`). `EngineIsolationProbeTests` is a compile-time
check that every entry point is callable from a `nonisolated` context.

## 入力の由来

これらの合成JSONは抽出元commitで固定されたPython実装との比較入力です。既存の792件の期待値を変更せず保持しています。通常のテストにはPython backendや生成スクリプトは必要ありません。更新は元実装との対応を確認して行ってください。

## Running

Inside the app:

```sh
xcodebuild test -project strius.xcodeproj -scheme strius \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:striusTests/LearningProgressVectorTests \
  -only-testing:striusTests/LearnerTextVectorTests \
  -only-testing:striusTests/TurnProgressVectorTests \
  -only-testing:striusTests/TutorMemoryVectorTests \
  -parallel-testing-enabled NO
```

The test files load fixtures from the test bundle (`engine-vectors/<name>.json`,
or the bundle root) and fall back to `../Fixtures/engine-vectors/` relative to the
test source, so the same files also run under `swift test` in a SwiftPM package
whose library target is named `StruisEngine` (see the `#if canImport(StruisEngine)`
import switch).

## Comparison rules

* JSON outputs are compared after canonicalization (sorted keys, `1 == 1.0`,
  booleans distinct from numbers). Key order of Python dicts is still reproduced
  by the port (insertion order), because `context_for_turn` / `public_trace`
  expose it in lists.
* Every explicit Python `ValueError` message must match byte-for-byte (the repair
  loop feeds it back to the model). pydantic validation failures only need to fail.
* YAML files are compared as parsed values, not text; generated ids (`uuid4`) are
  normalized to `<uuid>` and the supersede links are checked structurally.
* `turn_contract` / `<struis_current_view>` payloads are compared as parsed JSON.
