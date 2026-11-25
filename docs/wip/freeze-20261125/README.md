# WIP credit-freeze checkpoint - 2026-11-25

Archival branch only. Do not merge this branch as a feature PR. No new implementation was started for the freeze. Product changes remain in their own PR branches.

## Windows discovery split

windows-discovery-candidate.patch preserves the existing approved candidate against #9899e469e69, for Ethernet/WLAN discovery plus the shared destruction helper. The measured shared candidate was +1,240 B Win64/RAM flat. The standalone persistence PR has NOT been created. The patch still contains #989-dependent watcher/deinit/test-observer assumptions and owner cleanup; isolate the persistence changes against current master before calling it an independent implementation. The later centralized all-object shutdown means the old deinit destruction loops are redundant. Its unmodified old evidence is preserved for attribution, not a current readiness claim.

## Encoder reentrancy

encoder-reentry-probe.d is a temporary module-local D regression appended to the JSON module in the executed negative control. It covers both JSON and binary encoders, showing a nested outgoing subscriber overwrites the outer shared buffer. No production fix or permanent standalone test has been implemented. Next: separate PR off current master using send-local Array ownership and move-back on scope exit, permanent regression, serializer audit, size and exact-head review. This remains the highest-priority production fix once work resumes.

The negative probe executable and larger measurement artifacts remain at the local paths in the evidence documents; generated binaries are intentionally not committed. The source, trace and small test log needed to reproduce the finding are preserved here.

## Doorbells / lifetime

process-global-registry-audit.md and sync-encoder-lifetime-audit.md preserve the source findings. No doorbell code was changed. Latest disposition: identify static handlers and reuse their process-lifetime slot; inventory any delegate/instance-bound registrants separately. No slot bump, fixture reset or teardown workaround.

#989's current simplified shutdown source is saved on its existing draft branch, with its own MODULE_LIFETIME_WIP.md and main-loop shape. The superseded two-phase evidence is historical only. The singleton-vs-recreatable decision and final main-loop/quiescence design remain unresolved.

## Other parked work

926 files preserve the existing local validation and source-edit probes; the actual #926 head292d00b5 is already pushed. RDMD cache lock/dependency files are generated artifacts and are not changes to preserve in Git. The ESP CI worktree codex/ci-esp-ldc-142 is clean at c5c2e70b: no IDF/LDC pin implementation or PR exists yet. Approved next step is IDF v6.1 plus LDC1.42.0 with a five-target workflow_dispatch firmware check.

The detached entropy-integration snapshot is saved separately as a WIP source branch; it is diagnostic only and must not replace #987's held feature branch. #9873e4b20cd and uRT#419c7296eee were already pushed and remain untouched.

manifest.json hashes canonical Git-index blob bytes (Git normalizes text line endings); the negative transcript is archived as encoder-reentry-negative-test.txt.
