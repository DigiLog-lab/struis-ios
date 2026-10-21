# Overnight CI experiment — 2026-10-22 JST

## Goal
User target: mean merge decision latency about 10 minutes per change. Measure from requested verification to required checks ready, including queue, checkout, native cache, build, Simulator startup, test execution and retries. Also report test-only timings separately. The queued waves of this experiment are an artificial experiment scheduling delay and must not be presented as the production merge latency.

## Fixed source
Repository DigiLog-lab/struis-ios. Start commit 8f11d6f5bd43e6461d93b95182c2b4e77f775093, original application source d3fe8a59acffe7fe21f87941e6f9863047813e8e (PR #39). Prior experiment succeeded: five methods, 20 passes, 366.20 -> 245.70 seconds mean command wall. This is not the whole gate. The tested optimizations only touch ReplyTail and three SplitGrading test cases. Other UI tests are unchanged.

## Initial matrix
Runner xcode-27, maximum two concurrent matrix jobs, no cache writes, no secrets, no app distribution. Four configurations, two repetitions each:
1. baseline: original waits/setup, standard app warmup, one test worker.
2. optimized: controlled reply tails and practice-ready fixture, standard app warmup, one test worker.
3. optimized-mock-warm: same as optimized; warmup launches with STRUIS_DEVICE_RUNTIME=0, STRUIS_DEVICE_TURNS=mock and -skip-onboarding (matching UITestSupport).
4. optimized-two-workers: same as optimized; standard warmup; two Xcode test workers on the same VM.

Every matrix job builds once, verifies variant injection, runs all units, then all UI methods eligible under the existing Xcode Cloud gate exclusion manifest. Two experiment-only injection probes are excluded from the UI inventory and the applicable probe is run separately. Record all excluded and skipped tests; no claim that external/physical integrations were verified.

Each job is capped at 85 minutes, warm/build step 25, measurements 60. Individual xcodebuild wall budget is 45 minutes for the UI suite. Always upload logs/results when feasible. Python summary validation rejects empty/missing inventories. Preflight validates source discovery before launching macOS jobs.

## Selection analysis
Audit existing path mappings against all tracked Swift production files and 20 recent source commits. Save current and conservative selection counts; unmapped production paths expand the conservative shadow proposal to all eligible tests. Do NOT use this shadow audit to skip any tests in the initial measurements. This is not a semantic dependency graph and does not establish safety of omissions.

## Continuation
Check jobs hourly during this night. If still active, leave valid measurements running. If a harness defect blocks measurements, inspect completed logs, correct only experiment files, preserve failed evidence and use a bounded follow-up experiment (at most one extra full matrix; prefer just necessary configurations/repetitions). Do not repeatedly rerun an application failure to obtain green. Do not start additional macOS work after 06:00 JST, and do not keep the monitor recurring beyond this morning.

Analyze 4 configurations: setup breakdown, command times, passed/skipped/failed counts, missing tests, test body times, mean/min/max for both trials, and aggregate runner minutes. Two trials are preliminary timing evidence, not a statistical flake-rate estimate. Repeated identical method failures are functional evidence to inspect. Single isolated failures remain unresolved.

For ten-minute proposals, distinguish measured end-to-end configurations, projections, and unimplemented ideas. Full suite wall lower bounds, conservative selected suites, shared build artifacts and content-based test receipts may be evaluated as follow-up candidates; never claim a projection is a timed gate. No production CI, main, PR #39 head, release/upload, secrets, or required-check policies should change as part of this experiment.

## Durable output
Commit observations, run IDs, raw summary data and the final recommendation to docs/ci-experiments/ on experiment/ci-overnight-20261022. Docs-only commits do not trigger the experiment. Keep original and failed measurements. Morning report should recommend a concrete everyday gate configuration, state whether ten minutes was achieved, and identify measured remaining bottlenecks and any coverage tradeoffs.
