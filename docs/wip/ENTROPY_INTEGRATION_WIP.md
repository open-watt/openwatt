# WIP diagnostic integration snapshot

Credit-freeze preservation only; do not merge or use as #987's feature head. Parent is held #9873e4b20cd, with copied module lookup, watcher retry, BuiltinBLE/GoodWe ownership and Windows discovery candidate changes. #987's actual branch is untouched.

Earlier combination passed sorted Visual D216/216 before the two Windows discovery fixtures. With those module-local fixtures it fails at manager/package.d2040, out of doorbells (32 process-global slots), during HA Application construction through I2CModule.init. No table bump, reset or test relocation was applied. It does not include #989's later simplified global shutdown.

Next: resolve #989's authorized process-lifetime static-doorbell contract and remaining lifetime design, then rebase the real entropy PR rather than merging this diagnostic snapshot. Evidence and encoder probe are preserved on codex/wip-freeze-artifacts-20261125. No encoder production fix is present here.
