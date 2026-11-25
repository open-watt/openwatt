# Sync encoder lifetime audit

Scope: stop/deinit/recreation ownership and pending callbacks, recovered from the reviewer checkpoint. Source trace at OpenWatt #9899e469e69, parent/master c5c2e70b (GitHub master checked). Windows discovery edits do not touch these files. This is a source audit, not an executed active-command teardown reproduction or a blanket encoder-safety approval. No encoder/lifecycle fixes were made.

## Conclusion

Do not add encoder frees to SyncModule.deinit in isolation. Current teardown retains the encoders/module-related work; it does not establish a quiescent point. This is a confirmed lifetime omission and latent-command ordering requirement, not a demonstrated current encoder use-after-free: the current code never frees the encoder instances there. General Application recreation remains a separate held design decision.

## Ownership and call chain

- manager/sync/package.d158-184: SyncModule.init allocates JsonEncoder(this) and BinaryEncoder(this), publishes them in g_json_encoder/g_binary_encoder and g_encoders, and registers object lifecycle/state, element lifecycle, device lifecycle and clock callbacks.
- manager/sync/{json,binary}_encoder.d44/85: each encoder retains a SyncModule reference and a mutable scratch buffer. The encode/decode APIs themselves are synchronous; inspection found no encoder-owned pending CommandState or async registration. Their consumers own the pending work.
- manager/sync/package.d186-189: SyncModule.deinit only unsubscribes the clock callback. It neither stops peers, cancels/drains inbound commands, unregisters the four lifecycle callbacks, clears globals nor frees the encoder allocations. Recreation allocates new instances and overwrites the globals while old callbacks/module state remain.
- manager/sync/package.d1255-1277: inbound_cmd creates a SyncConsoleStream, ProducerSession and InboundCmd, installs session.ready=&cmd.wake and stream.tx_handler=&session.produce, then appends it to peer._commands.
- manager/sync/peer.d566-577: shutdown requests command cancellation and marks each cancelled, then returns Continue while _commands is nonempty. Calling shutdown again does not itself run command.update or retire that ownership.
- manager/sync/package.d230-266: only SyncModule.update polls command.update, frees a completed command, and calls cmd.retire before removing it. InboundCmd.retire (package.d130-138) releases the producer handler/session, calls g_app.console.destroy_session, closes/destroys the stream and frees the context. The Application and console must still be valid through this phase.
- manager/sync/peer.d580-604: module detachment, transport/waiter cancellation, RDP closure and log-consumer cleanup occur after that command-drain condition. detach_transport (1092+) cancels _tx_waiter and removes state/packet subscriptions. They are not proven quiescent while shutdown is returning Continue.
- manager/sync/console.d135-175: stream output resolves encoder_for and encodes console frames; room_returned can resume queued output. PeerConsoleCommand.request_cancel (281+) routes through the current SyncModule. These are service dependencies during cancellation, not free-standing encoder-owned callbacks.
- manager/package.d318-325: shutdown_application calls module deinit then frees the Application, without requesting peer destruction or continuing the normal stopping/command/event passes. Quiet test fixtures with no pending work do not prove the active case safe.

## Callback API inventory

Object lifecycle/state unregister APIs already exist (collection.d512, base.d1390) but SyncModule.deinit does not call them. Element/device lifecycle registration APIs (element.d49, device.d37) have no corresponding unregister API in the inspected tree. Both categories must be considered before freeing the bound module target. No registry-wide clears or fixture resets were introduced.

## Safe boundary required, not implemented

Producers must stop and peers/console commands finish through the existing cancellation/update paths while their Application, SyncModule, console and transport services remain alive. Once no work can call back, app-owned registrations can be removed and encoder/module allocations released or replaced. The exact outer lifecycle/drain contract is still held for Manu; this audit does not authorize or implement a generic drain. A process-lifetime encoder alternative would first have to remove its Application-owned SyncModule reference and define ownership explicitly; retaining the current pointer is not that design.

## Additional boundary checked

The singleton scratch buffers are borrowed by send_frame into SyncPeer transmit. Bundles and fragment holds copy into owned peer arrays; the raw path wraps the slice in StackPacket and forwards it. A control refusal can synchronously request restart (peer.d1024, base.d905), and detach callbacks can encode error/close frames. The scratch/reentrancy/transport-copy guarantee is not established by the teardown analysis, and no corruption claim is made here. It remains a separate audit branch if needed; freeing scratch storage during an active encode is clearly not justified.

## What the current tests establish

The quiet Make/VisualD Application recreation suites pass. New Windows discovery tests create unstarted synthetic adapters and prove flags/export/normal destruction and replay; they do not cover in-flight Sync commands, active radio I/O or async driver shutdown. The earlier detached entropy suite keeps WS/Tesla tests in their own modules and has no global teardown resets. These results do not waive the lifecycle hold.

## Follow-on executed reentrancy finding

A separate temporary D unittest now proves both encoder scratch buffers can be overwritten by a nested outgoing-interface subscriber before the outer send consumes them. JSON's outer seq11/text outer becomes seq22/text inner and is transmitted twice; binary also fails outer_intact. Negative probe exit3 and the exact source/executable are archived at D:/tmp/ow-encoder-reentry-audit-20261125/README.md. No encoder fix is implemented. The proposed scoped move of the Array into a send-local owner is separate from the unresolved teardown policy.

Clarification: the object-state unregister API cited above is #989's existing five-line addition; object-lifecycle unregister predates it. The audit scope is the #989 tree, not a claim that both APIs already exist on c5c2e70b.

## Broader integration now blocked by doorbell exhaustion

After restoring the temporary encoder probe, the detached entropy combination with the two new module-local Windows discovery fixtures fails in ha_discovery at manager/package.d2040: out of doorbells. Stack: ha_discovery.d1169 -> create_application -> Application.this -> I2CModule.init (router/iface/i2c.d438) -> register_doorbell -> Doorbells.register. The table is DoorbellHandler[32] at package.d2082. I2CInterface.complete_buses is static (i2c.d319), but init registers it anew per Application; Doorbells only increments _count and has no release/dedup. This confirms the already listed process-global lifecycle issue, not an encoder-probe artifact: JSON source was restored and git-diff empty, and the full run reaches HA after JSON and WebSocket pass. Log: D:/tmp/ow-discovery-final-integration-full.log. No table enlargement, global reset, fixture consolidation or lifetime fix was made. The #989-only Make and sortedVS suites pass216/216; the broader entropy combination cannot yet be called green.
