# Windows discovery ownership evidence

Scope: local candidate atop #989 9e469e695f143b26b5bd9f6b0f07a6bc2d0670d7. Not committed or pushed; the broader lifecycle gate remains held.

Linux discovered Ethernet/WiFi/CAN/BLE objects use ObjectFlags.dynamic; config export excludes dynamic, temporary and remote objects. ESP WiFi/Ethernet hardware objects are console-command configured in platform system.conf rather than created by these discovery callbacks. Windows mirrors the Linux discovery convention without adding an ownership bit.

Windows candidate marks discovered Ethernet, WiFi radios and paired WLANs dynamic, preserves manually configured objects, deduplicates discovery replay by adapter, and uses normal destroy rather than Collection.remove (which only unindexes). Module deinit retires dynamic objects with a shared cold BaseCollection.destroy_dynamic traversal. Tests remain in the Ethernet and WiFi modules.

| LDC 1.43 Windows release, fixed BUILD_ID | Flash bytes | RAM bytes | Delta vs 9e |
| --- | ---: | ---: | ---: |
| 9e control | 3,870,564 | 153,592 | 0 |
| Initial candidate | 3,873,168 | 153,592 | +2,604 |
| Virtual destruction candidate | 3,872,624 | 153,592 | +2,060 |
| Shared traversal candidate | 3,871,804 | 153,592 | +1,240 |

Shared traversal saves 820 shipped bytes vs the unshared virtual candidate. COFF supporting sizes: shared traversal 439 bytes; Ethernet/WLAN deinit 259/279 bytes, down from 700/1132. The supporting archived raw-object control is the earlier indexed-lookup control, not an exact 9e per-symbol reconciliation.

RP2350 release: flash 1,601,108 bytes, RAM 46,480 bytes, image size and sections unchanged. The unused Windows cleanup helper is absent from the linked symbols. Artifact hashes differ; byte identity is not claimed.

Make DMD 2.113: 216/216 pass (D:/tmp/ow-discovery-shared-dmd-full.log).
Sorted Visual D DMD 2.113: 216/216 pass (D:/tmp/ow-discovery-shared-vs-full.log).

Broader detached entropy integration is BLOCKED: manager/package.d:2040 out of doorbells, during HA Application construction through I2CModule.init. The process-global table has 32 entries and repeated Application creation registers static handlers anew. No reset, enlargement, fixture consolidation or lifecycle workaround was applied. Log: D:/tmp/ow-discovery-final-integration-full.log.

Separately the encoder audit reproduced JSON and binary scratch-buffer corruption under synchronous nested sends. No encoder fix is in this candidate. Evidence: D:/tmp/ow-encoder-reentry-audit-20261125/README.md. Teardown audit: D:/tmp/ow-sync-encoder-lifetime-audit-20261125.md.
