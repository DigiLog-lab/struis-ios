# Selected CI: two bounded follow-ups (2026-10-22)

The current user request authorizes testing selection and reuse hypotheses against a mean 600-second merge-decision target. No normal workflow, main, PR #39, app source, or secrets are changed.

The completed signed direct selected configuration took 599 and 630 seconds from workflow creation to job completion: mean 614.5 seconds. The unsigned trial failed a real Unit assertion (`ClaudeAppAttestTests/testReinstalledDeviceRegistersANewKeyWhenTheStoredKeyIsUnusable`); its 372 pass / 29 skip / 1 fail result is retained and it is not rerun until green. Signing causality has not been established.

The quality experiment detected both deliberate defects at their expected Unit assertions, then passed all 398 Unit cases plus nine scroll UI cases and the experiment probe. Its equivalent source edit in an already prepared VM took 536.969 seconds to internal validation and 552.621 seconds to GitHub job completion. This excludes the VM's earlier allocation, first build, first boot, and fixture preparation; it is one warm-worker simulation, not a new-commit GitHub merge check.

Two jobs will run, at most two macOS VMs concurrently:

1. **Cold logic-only scope:** signed normal build, no mock warmup, all 398 Unit cases, explicitly zero UI. The source scenario is a grading-boundary logic change with UI/input/persistence contracts unchanged. This tests execution cost only; automatic proof that an arbitrary change satisfies the scope is not implemented. Exact Unit pass/skip inventory and unexpected UI rejection remain required.
2. **Warm worker repeat:** same compilation-cache settings, one initial build and the two existing baseline Unit cases to prepare the app, then the same equivalent one-line ChatStore source edit, incremental rebuild, all 398 Unit cases plus the exact nine scroll UI cases and probe. Omit the deliberate mutant rounds this time. This repeats the relevant warm interval with less prior compiler-cache preparation; report its first preparation and whole runner time separately.

Each job has a 25-minute bound, retains full xcresult and commands, and has no automatic retry. These are selected follow-ups, not a full UI matrix. After completion remove experimental push triggers. Do not count the expected mutant failures as app passes, or infer low failure probability from two trials. Same-HEAD receipt reuse remains an offline prototype, and ordinary daily CI integration remains unimplemented.

The cold UI0 trial completed successfully in 596 seconds (369 Unit passed, 29 existing skips, no unexpected UI). Repeat that configuration exactly once to measure a two-trial mean and variability; do not discard the first observation or rerun until the mean passes. This adds one VM while the warm-worker repeat continues, retaining the maximum of two VMs.
