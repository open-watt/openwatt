# Local #926 combined validation

Clean local feature commit: `f5e7ec4abbc83f690e61a23eb1555c50289d5fa2`, branch `codex/926-dead-source-cleanup`. Parent: approved #988 `6e8df3e693425c11c1c6abfa316dc7eb54c493ed`. Runtime pin remains `c47834e6`.

The original #926 patch was replayed unchanged, then only approved dead source was removed: uncalled `XramInterface.tx_reserve` and `tx_abandon`, plus the unused `LinkUDPState.open` owner formal and call argument. The live `tx_commit` path remains. `_remote` simplification and the public low-level uRT `xram_abandon` API are untouched. No #926 push or merge was performed.

Native DMD 2.113.0, explicit `DC=C:/dev/D/dmd-2.113.0/windows/bin64/dmd.exe`, default debug settings: full combined suite 213/213. Logs: `build-unittest-2113.log` and `test-unittest-2113.log`.

The Git Bash default `dmd` is an older 2.112.0-beta.1. Both the cleanup and unchanged stacked endpoint-API control fail its debug link with LNK1103, while 2.113.0 links and passes. Thus the owner-parameter deletion did not introduce that local beta debug-link failure. No project/toolchain workaround is committed.

Matched Windows LDC 1.43 release against preserved c5c2e70b baseline is in progress. No duplicate S3/M0 build has been started while PM decides the connected-remote simplification.

The initial attribution/dead-source report is `D:/tmp/ow-926-attribution/REPORT.md`. It preserves the original #926 measurements and symbols. #988's final evidence is `D:/tmp/ow-udp-recv-storage-20261125/VALIDATION.md`.

Completed combined Windows release (LDC 1.43, default full features, uRT c478): text 3,166,864 / rodata 597,696 / data 52,224 / bss 101,368. Shipped sections total 3,816,784 bytes; static RAM 153,592. This is -61,568 bytes vs matched current-master c5c2e70b (3,878,352), and +3,544 vs approved #988 (3,813,240). The feature increment is exactly the original #926 increment measured before cleanup, consistent with zero net Windows footprint effect from the dead-source removal. The XRAM wrapper removal's zero linked M0 cost was independently established by symbol absence in the prior report.

The source commit remains f5e7ec4a and the tracked tree is clean. No #926 push or merge has occurred. PM authorization for `_remote` simplification is pending, and no duplicate S3/M0 build was started. Fresh original-head D0 attribution is now complete in the initial report: packed +1,485 B, loaded sections +2,160 B, static RAM flat; this does not remeasure the local cleanup commit. The source/PM authorization restrictions remain unchanged.
