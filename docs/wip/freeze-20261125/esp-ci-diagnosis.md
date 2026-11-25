# ESP firmware CI toolchain diagnosis

Master c5c2e70b. Normal push/master run45384793396 and ordinary PR trigger run cross-esp, but BUILD_FIRMWARE is false: Setup ESP-IDF and Build firmware are skipped for all five ESP targets. Only release-push or workflow_dispatch enables the final SDK firmware path.

Authorized full-master comparison run45481914858 independently reproduces the errors on both ESP32 job138757027582 and S3 job138757027813: Makefile601 rejects LDC LLVM22 bitcode for esp-clang llcLLVM20. Per-job first diagnostics are archived. Full run completed13/17: all non-ESP jobs and P4 pass; C5/C6 fail at undefined ble_gap_adv_stop/NimBLE, a separate existing SDK Bluetooth configuration gap. Per-job first diagnostics are archived for all four failures.

Requested LDC1.42 pin alone is not sufficient: local known-working compiler reports1.42.0/LLVM21.1.8, and officialrelease https://github.com/ldc-developers/ldc/releases/tag/v1.42.0 explicitly says prebuiltpackages useLLVM21.1.8. CI IDF_REF=v6.0 installs llcLLVM20. Local successful S3 uses IDF6.1/llc21. Need a compatiblepair decision: IDF6.1 + LDC1.42, or an older LLVM20-based LDC for IDF6.0. No workaround or new compiler path added.

Clean CI-only branch codex/ci-esp-ldc-142 in D:/tmp/ow-ci-esp-ldc-142-20261125 is based on master and has no changes or PR. #987 was not touched for this task. PM informed before coding incompatiblepin.
