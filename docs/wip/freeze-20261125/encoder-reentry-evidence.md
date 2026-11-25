# Confirmed nested encoder-send corruption

Temporary D unittest in the detached #9873e4b20cd +#989 lookup/watcher/Windows ownership diagnostic composition. No encoder product fix or PR change. DMD2.113, sorted VisualD UnitTest/x64, filtered manager.sync.json_encoder.

Control sends seq11/text outer normally and captures the expected frame. A public outgoing-interface subscriber then calls the same encoder with seq22/text inner. The listener has a recursion guard so there are exactly two sends. Both have equal encoded length and reuse existing capacity; no allocator behavior is needed for reproduction.

JSON: expected {"kind":"error","seq":11,"text":"outer"}; both captured frames instead contain {"kind":"error","seq":22,"text":"inner"}. Binary also reports outer_intact=false. The final assertion fails with exit3 as expected for this negative probe. See test.log. This is an executed API-level reproduction, not a live-fleet incident.

Root: each encoder's send_frame passes a slice of its shared _buf. BaseInterface.forward invokes outgoing subscribers after admit; packet_mutable explicitly leaves a foreign stack packet borrowed for headroom0. Nested encode_error clears/reuses that same _buf, so the later outer transmit reads the inner data. RDP.send instead packet_keep-copies the lent frame before pump callbacks on an established session; that path was source-traced, not exercised in this probe.

Proposal, not implemented: move _buf ownership into a local Array for the send duration and restore it with the existing urt.lifetime.move in scope(exit); nested encoding gets a separate buffer while the outer owns its bytes. Use the owned local for failure diagnostics too. Ordinary non-reentrant sends reuse capacity and need no per-frame payload copy/allocation. Measure code/stack impact and test both encoders. This addresses reentrancy while the encoder object remains alive; it does not solve the separately held Application/encoder teardown-quiescence contract.

Build log D:/tmp/ow-encoder-reentry-build.log. Command: MSBuild openwatt.vcxproj Configuration=UnitTest Platform=x64 DMD2.113; run reentry-probe.exe --test-module manager.sync.json_encoder from the detached worktree. Existing interfaces/packet APIs and module-local unittest are used; no raw Python test harness. The temporary append is restored after capturing evidence; probe.d preserves the exact corrected test.
