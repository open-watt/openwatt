# Process-global registry and cache audit

- Master audited: c5c2e70bfc7195c9ae688bd14074aa31b4513f82.
- Held #989: df362917d8a6cc64e434a1410c816da13632de49.
- Held #987: 8cf6bc47c5f6103e2dc1631d73c0217d388b2259.
- Paths below are repository-relative. OpenWatt lines refer to held #989 unless marked master; uRT paths are under third_party/urt/src/.
- Source inspection only. No fixes, builds, rebases, commits, pushes or PR-body edits performed for this audit.
- Entries distinguish no Application boundary, per-object/operation cleanup, intentional process-lifetime state, and matching teardown. They are a list of lifetime facts, not a claim that every retained value is defective.

## Instance-bearing registries and registrations without complete Application teardown

| Global / definition | Writer | Retained state and teardown status |
| --- | --- | --- |
| `get_module!T.g_module_instance`, master `src/manager/package.d:337` | First typed lookup | Process-static module reference; master never invalidates it. Removed in held #989 and its stacked #987; not an outstanding cache in those held trees. |
| `g_item_tables`, `src/manager/collection.d:553` | Collection registration, creation, subscriptions and removal | Live object pointers, collection delegates, pending frees and tombstones. Per-object removal/free exists; no whole-Application empty/reset. Tombstones deliberately support ObjectRef rebinding; remaining live rows are a distinct lifetime issue. |
| `_on_object_lifecycle`, `src/manager/collection.d:551` | SyncModule init; IPModule -> Linux mirror init | Bound SyncModule and global-mirror delegates. Unregister API exists, but those registrations are not removed by their teardown. |
| `_on_object_state`, `src/manager/base.d:1434` | SyncModule init; Linux bridge module | SyncModule delegate remains. The Linux bridge's matching unregister is added only by held #989; master lacks that pair. |
| `_on_element_lifecycle`, `src/manager/element.d:1660` | SyncModule, PanelModule, InterfaceModule init | Bound Sync/Panel delegates plus InterfaceModule's free `led_created` callback. No matching module removal. Free callback itself does not capture an Application, but duplicate entries accumulate. |
| `_on_device_lifecycle`, `src/manager/device.d:990` | SyncModule and EnergyModule init | Bound module delegates; no matching unregister/reset. |
| `_frame_handlers[PacketType.ble]`, `src/router/iface/package.d:124` | BLEModule init, `src/protocol/ble/package.d:49` | Bound BLEModule.on_ble_frame, defined at :129. BLEModule has no deinit removal. Registration refuses an occupied slot, so later startup does not replace the prior module handler. |
| `g_profile_sections`, `g_profile_root_sections`, `src/manager/profile.d:1826-1827` | CAN, Modbus, GoodWe, HTTP, MQTT, OBD, BLE and Zigbee module profile registration | Bound module interfaces. Same-name registration rebinds the handler while preserving kind; no teardown null/clear between Applications. |
| `g_panel`, `src/manager/panel.d:335` | PanelModule.init, :121 | Module pointer is assigned and never cleared. |
| `g_json_encoder`, `g_binary_encoder`, `g_encoders`, `src/manager/sync/{json_encoder.d:35,binary_encoder.d:33,encoder.d:69}` | SyncModule.init, package.d:162-165 | Allocated encoder objects retain their SyncModule; no free/null pair. Live consumers and latent commands make release timing a separate unresolved boundary. |
| `_sync_states`, `_free_sync_slots`, `src/manager/base.d:1436-1437` | Sync-state allocation / delta-slot attachment | Channel identities and slot state. Individual detach clears/recycles; no Application reset, and BaseObject destruction alone does not detach its slot chain. |
| `g_dirty_elements`, `g_historical_elements`, `g_pending_updates`, `g_commit_depth`, `src/manager/element.d:1634,1661-1663` | Element writes, history and batched commits | Element references and pending commit state. Element.teardown removes its entries and processing drains updates; no Application-wide reset. |
| `_pools`, `_pages`, `_cpu`, `_stack_peak`, `src/manager/stats.d:119-122` | create_system_device during Application construction | Raw Element pointers; no teardown clear. Next creation overwrites only the metrics it creates. |
| `g_priority_events`, `g_bulk_events`, `src/manager/package.d:2026-2027` | Application/event/ISR posting | Pending delegates may bind runtime objects. Constructor reinitializes queues; shutdown has no explicit drain/reset. |
| `g_doorbells`, `g_pages_freed`, `src/manager/package.d:2082-2083` | Application constructor; Serial, CAN, I2C, GPIO, BLE, Ethernet, WiFi, WPAN, XRAM, SFP, IDF log, SmartEVSE startup | Static function handlers, fixed 32-slot count, control mask and pending ring bits. No unregister/reset/deduplication; repeated startup allocates more slots. Static handlers are not bound Application pointers. |
| `_stack_ptr`, `src/protocol/ip/package.d:2752`; `_stack`, `src/protocol/ip/socket.d:70` | IPModule.pre_init / install_socket_backend | Pointers into the module's IPStack are not nulled by module teardown. |
| `_socket_backend`, `third_party/urt/src/urt/socket.d:46`; `_backend`, `src/protocol/ip/socket.d:66` | install_socket_backend registers the static vtable | No uninstall. Vtable storage is static, but its functions reach the retained module-owned `_stack`. |
| `g_mirror`, `nl`, `src/protocol/ip/linux_mirror.d:80-81` | mirror_init initial sweep and lifecycle/retry work | Tracked runtime objects, delta slots, orphan/retry state and transport context. No production mirror teardown; tracked.clear found in tests is not an Application teardown. |
| `g_adapter_watcher`, `src/driver/windows/adapter_watcher.d:235` | Windows Ethernet/WLAN pre-init scans and init start | Shared worker, adapter snapshot, rings and stop state. CRT-level stop only; stop retains snapshot/rings and stop=true. No Application reset/replay boundary. |
| `_pending_discover`, uRT `driver/windows/ble.d:692` | BLE discovery | Async operation, service collection and current service survive close; later polling is the retirement path. |
| `_pending_gatt`, `_num_pending_gatt`, uRT `driver/windows/ble.d:695-696` | GATT requests | Retained async COM operations are not released/reset by close. |
| `_scan_ring`, `_notify_ring`, `_disconn_ring`, uRT `driver/windows/ble.d:699-701` | Native BLE callbacks | Rings survive close; records identify connections without an Application/session epoch. |
| Native BLE event-handler/session state, uRT `driver/windows/ble.d:641,672-676` | BLE open/connect/subscribe paths | Close removes subscriptions and releases sessions, but handler raw-free paths do not establish outstanding COM invocation/reference quiescence by source inspection. No reproduced UAF is claimed. |
| Ethernet provider ready callbacks, uRT ESP32 Ethernet `_ready_cb_bits` at :228 and MT7621 Ethernet `_ready_callback` at :499 | BuiltinEthernet.port_attach, OpenWatt :378 | No matching ready-callback detach in that path. Close clears RX/link callbacks; ready registration remains. ESP32 context :227 remains inert after those callbacks clear. |

## Deferred runtime tables with individual cleanup but no whole-Application retirement

| Global / definition | Writers | Existing cleanup boundary |
| --- | --- | --- |
| `_udp_eps`, `_neighbours`, `_last_neighbour_sweep`, `src/router/iface/endpoint.d:660-662` | Endpoint opens and traffic | Individual endpoint close / update reclamation and neighbor expiry; no whole-App reset. |
| `_slots`, `src/protocol/ip/socket.d:67` | Internal-IP socket creation | Individual close frees slots; module teardown does not retire all remaining slots. |
| `_pcbs`, `src/protocol/ip/udp.d:87`, `tcp.d:266`; `_iface_watcher`, `tcp.d:361` | Socket/transport startup | Per-PCB cleanup and interface subscriptions; no whole-App drain. Watcher/PCB state can retain interface references. |
| `_tcp_conns`, `_tcp_listeners`, `src/protocol/ip/package.d:2684-2685` | Connect/listen/accept | Native deinit closes and pumps once, with in-flight cancelled operations explicitly permitted to remain; internal-IP deinit has no equivalent complete sweep. |
| `_link_locals`, `_address_memberships`, `src/protocol/ip/nd.d:632-633` | Automatic station/address discovery | Cleanup depends on later updates noticing absent/offline objects, not module teardown. |
| `_slaac_ifaces`, `_slaac_prefixes`, `_slaac_routes`, `src/protocol/ip/nd.d:382-384` | Discovery and received advertisements | ObjectRefs, generated address/route records and expiry state; no module-wide retirement. |
| `_memberships`, `src/protocol/ip/mld.d:201`, `igmp.d:160` | Automatic address/RA and socket joins | Individual leave/update paths; no module-wide retirement. |
| `_pending_echoes`, `src/protocol/ip/icmp.d:428`, `icmp6.d:437`; pending Ethernet ping/discovery delegates, `src/router/iface/ethernet.d:794,796` | Commands and traffic | Per-operation completion, cancellation/expiry; no Application-wide reset. |
| `waiting`, `waiting_pool`, `free_list`, uRT `async.d:321-323` | Module-owned Zigbee objects create asynchronous operations; Application.update services them | Runtime/process-owned scheduler and allocation pools. Owner object abort/finish retires individual work; shutdown_application does not globally cancel it. deinit_async is called at runtime/process teardown, not Application teardown. Live work can retain owner arguments/delegates. |
| ESP32 BLE event queues, uRT ESP32 BLE :759-768 | BLE provider operations | Successful provider deinit resets queues; failed native deinit leaves them and marks faulted. No successful reusable-retirement claim on that failure path. |

## Persistent caches and metadata without Application reset

| Global / definition | Writers | Lifetime classification |
| --- | --- | --- |
| `g_secret_store`, `g_secret_store_loaded`, `g_secret_store_dirty`, `src/manager/secret.d:568-570` | Secret load/set/lookup | File-backed, load-once material cache. No Application clear/reload. |
| `g_capacity_estimates`, `src/apps/energy/vehicle.d:162` | Vehicle capacity samples | VIN-keyed owned data; no clear or explicit process-lifetime contract found. |
| `g_formats`, `src/manager/series.d:1284` | Format registration from Application, modules, profiles and schemas | Explicit process-lifetime identity contract at :68-69. No teardown expected under that contract. |
| `ElemFormat!Decl.cached`, `src/manager/base.d:1702`; `vehicle_element_formats`, `src/apps/energy/vehicle.d:161` | Property/vehicle format initialization | Cached FormatIds; compatible with the persistent format registry. |
| `g_constraints`, `g_descs`, `g_enums`, `src/manager/sample/package.d:552-554` | Registration from modules, profiles and Sync | Descriptor/enum metadata, no clear. Deduplication exists; enum replacement deliberately preserves old definitions for existing Elements. |
| `g_packet_codecs`, `src/router/iface/packet.d:762` | Protocol packet-codec registration | Static function/type metadata, per-kind assignments; no unregister. No bound module references in codec records. |
| `g_codecs`, `g_num_codecs`, `src/manager/series.d:1280-1282` | register_series_codec | Static function metadata; current repository registration is unittest-only, not a production module-init writer. |
| Profile section kind numbers | Protocol module initialization | Numeric IDs refer to persistent profile registry; the handler-reference problem is listed separately above. |
| TLS ACME payload scratch buffers, `src/protocol/tls/certificate.d:1337,1352` | Certificate request generation | Function-static Array buffers persist per thread; owned byte data, not module references. |
| `hostname`, `hostname_explicit`, `_node_id`, `src/manager/system.d:32,104,535` | Factory naming/config/identity | Process configuration and cached node identity; no App reset. Host node identity is file-backed. |
| Bootguard `_state`, `_stored`, flags, `_trial`, `src/manager/bootguard.d:163-179`; `_timers`, :293 | Boot/recovery startup and checkpoints | Process/boot state; no App reset. Boot persistence is part of the subsystem's purpose. |
| Windows DLL/function caches, `driver/windows/{npcap.d:14,68-76,iphlpapi.d:153,wlanapi.d:152}`; IP Winsock extension functions `src/protocol/ip/package.d:2871-2873` | Lazy provider initialization | Process-level loaded-library/function caches, not Application objects. |
| Windows BLE `g_winrt`, factories and global wake-only `_completed_handler`, uRT `driver/windows/ble.d:1510,685-686,652` | First provider use | Process-level COM state, separate from unretired per-operation state above. |
| `g_links`, `g_addrs`, `g_routes`, `g_neighs`, `src/driver/linux/netlink_dump.d:258-261` | Kernel dump commands | Snapshot data is cleared before the next dump, not at App shutdown; not bound runtime-object references. |
| `_urt_entropy`, `_urt_ctr_drbg`, `_urt_rng_seeded`, uRT `internal/mbedtls.c:104-106` | First checked crypto request / MbedTLS use | Process-owned entropy/DRBG context; no Application reset. |
| `g_type_details`, `g_num_type_details`, uRT `typereg.d:51-52` | CRT type registration | Process type/function metadata; production registration is a CRT constructor, not repeated Application initialization. |
| BL808 IPC handlers/space hook and driver hardware callbacks | First channel/peripheral setup | Process-level static functions. XRAM close clears channel notification, but does not unregister the common hardware handler table. |
| IDF log queue, uRT `driver/esp32/idf_log.d:70` | Log bridge/provider open | Queue survives close and resets on next open; ready callback is detached. |
| Watchdog `_request_feed`, `src/driver/watchdog.d:25` | Main installs feed callback | Main-owned process callback; watchdog_stop joins/nulls thread but leaves callback. It reads current g_app rather than capturing an old App. Application-only shutdown does not stop watchdog. |

## Matching teardown, candidate/master differences and exclusions

| Registry/table | Matching behavior |
| --- | --- |
| `g_app` | Application destructor clears it. Held get_module has no static module pointer. |
| `g_console_instances`, `src/manager/console/console.d:662` | Constructor links, destructor unlinks; explicitly leaked test consoles are test-only. |
| `g_encodings`, `g_num_encodings`, `src/manager/sample/codec.d:99-100` | Application registers builtins; destructor clears registry. |
| uRT clock-change handlers | Application, Sync and normal Cron/RTC paths have corresponding unsubscribe/disarm. |
| uRT reclaimers and log sinks | Application, LogModule, ConsoleSessionModule and MQTT registration pairs exist. Bootstrap log sink is main/bootstrap-owned and explicitly retired. |
| uRT page-pool wake hook | Application installs a static notification function and clears it in destructor. The page pool itself is deliberately runtime/process-owned. |
| uRT scope provider / Ethernet frame and TCP input hooks | Matching removals exist. BLE frame handler is the separate missing pair listed above. |
| Linux `g_link_handlers`, `src/driver/linux/netlink.d:40` | Held #989 pairs CAN/Ethernet/WiFi registrations with unsubscriptions; master lacks those new pairs. |
| Linux bridge hooks/offload state | Held #989 unregisters state hook, clears bridge hooks, cancels sync work and disengages owned offloads; master lacks that deinit. Sync state callback remains unpaired separately. |
| Linux `g_fdwatch` | stop clears/tombstones watcher records, detaches reactor hooks and nulls reactor pointer. |
| Active driver arrays | Builtin BLE/WiFi/WPAN, Linux radio list, XRAM links, Serial and I2C tables have per-object shutdown removal. Complete cleanup still depends on those objects reaching shutdown. |
| IDF bridge / SmartEVSE owner pointers | Existing deinit clears bridge/owner references and releases hardware/log buffers. Doorbell registration is still separate. |
| Linux temporary nl80211 active pointers | Assignment uses scope(exit) clear; not retained past the operation. |
| Immutable type/property/enum/literal tables, reactor address sentinel | Static metadata; no Application object ownership to tear down. |
| Per-Application console scopes, intrinsic-function map, signal-provider map, module array, timers and device table | Instance fields, not process-global registries. |
| Hardware ADC/DMA buffers, sequence/port counters, reset classification, supervisor/OTA boot configuration and protocol rate-limiter scalars | Process/hardware/data state rather than additional Application-bound registry tables. |
| Generic heap/free lists and vendor-library internals | Not treated as Application registries solely because allocating an object mutates allocator state; this is a project-owned registration/cache audit, not an audit of every vendor internal global. |
