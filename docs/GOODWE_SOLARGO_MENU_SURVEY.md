# SolarGo 7.2.2 — GW5048D-ES menu and configuration survey

Survey date: 2026-10-29. Target: GW5048D-ES, ESU serial family, DSP23 / ARM14, Australia-A, PYLONTECH US2000B-TB*2; communication module V1.1.3.14.

The running Android app connected through a read capture relay to the real inverter is the reference for visible menus. APK code supplies command construction, conditional branches and validation. This survey records 130 UI snapshots and 208 entries, including navigation, repeated schedule fields, conditional fields and explicitly excluded schema entries. **208 is not a count of independently verified settings.**

No configuration writes were submitted to the real inverter during this menu survey. Earlier bounded EMS write/readback trials are documented separately in [the protocol reference](GOODWE_REFERENCE.md). A visible value, a static encoder and a successful hardware write are distinct evidence levels.

The [machine-readable survey](GOODWE_SOLARGO_MENU_SURVEY.json) preserves each entry's source location, visibility classification and evidence hashes. Raw UI and packet captures remain private because WLAN responses can contain credentials. Source locations below refer to the locally extracted APK, not OpenWatt implementation files.

## Applicable navigation

- Home: power flow, operating status, grid code, work mode, battery model/status, meter status, backup and software/hardware power limits.
- Parameters: Data and Alarm. Data includes inverter identity, PV1/PV2, AC/backup/import and battery measurements. Alarm shows paged history; no date/filter control was observed.
- Settings → Communication Settings: Privacy & Security, WLAN/LAN, WLAN Detection, 4G.
- Settings → Basic Settings: Grid Code overview/selection → Working Mode → Battery Model → Meter/CT Detection. Installer entry uses the application password; this is separate from the module WLAN password.
- Settings → Advanced Settings: operating toggles and limits, Detection Mode, Battery Function, Safety Parameter Settings. Safety has Protection, Connection, Curve Settings and Other tabs.
- Settings → Meter Function → Meter/CT Detection.
- Settings → Device Information → Update Record. APP Version is displayed in Settings.

## Findings that change previous interpretations

1. **BMS Information:** the app reads battery serial at F7/90C4/16, then BMS version at F7/0780/1. `GoodUtil.readOneByte` returns zero on exhausted/invalid reads; the UI formats it as `00`. The observed `--.--` → `00` transition therefore does not establish a reported zero firmware version. Register7506 is Hardware Power Limit, not BMS version. Earlier marker associations are superseded.
2. **Safety loading placeholders:** the initial loading screen's100.3V,83.6V,80.5V,56.1V and0.1Hz values are not fresh inverter data. Settled reads showed265/180/275/70V and52/47Hz. Record only settled responses with packet provenance.
3. **Battery Function:** both DoD fields loaded80% through the real-inverter relay and through the same proxy reached over the clean alternate network path. The on-grid and off-grid reserve encodings are minimum SOC (`100-DoD`); the selected battery UI rejects95% DoD. Earlier proxy fetch errors correlate with duplicate UDP replies on the VLAN3 path; see the [network investigation](GOODWE_PROXY_NETWORK_DIAGNOSIS.md).
4. **DoD reset investigation:** battery-model selection performs coupled capacity, charge, discharge, reserve and protocol writes. This is a confirmed potential writer of reserve values, not proof of the owner's spontaneous-reset cause.
5. **Configured current scaling:** this ESU bulk reply uses charge raw/2.66 A and discharge raw/1.28 A; setters use physical tenths of an ampere. Runtime BMS limits are separate fields.
6. **Module protocol:** family1 function04 reads server connection status,05 reads packet counters,0D reads router credentials,0E scans hotspots. WLAN configuration writes family1/0B network mode/address CSV, then1/0A length-prefixed SSID/encryption/password, followed by1/0C reload. The UDP module-password workflow instead uses family2/01 with an AT command payload, then1/0C; its framing family must remain distinct.
7. **Curve time constants:** Q(U)45468 and P(U)45512 use `seconds=819.2/raw-0.2`; raw zero displays infinity. Their setters truncate `819.2/(seconds+0.2)`. This transform is not established for every field named time constant.
8. **Ride-through switches:** LVRT and HVRT share45499: bit0 LVRT, bit1 HVRT. Update one while preserving the other.

## Scope and remaining limits

All top-level menus listed above and their applicable screen branches were visited. Time1's schedule editor was visited; Time2–4 use the same source editor. The disabled cosφ(P) branch and immediate-charge cutoff were traced statically without enabling operation. Every country, battery model and operator catalogue choice was not selected: some battery selections immediately commit configuration. Other model/regional branches are explicitly excluded below.

The physical CT test was not started because the current BMS communication failure invalidates its prerequisites. No network/password, safety, battery-model or operating-setting writes were performed in this survey. Hardware ACK semantics, persistence across reset, inverter acceptance limits and physical power response require separate bounded trials. The DoD reversion cause and complete proxy warning fix remain unproven. Remaining work is tracked in [TODO](../TODO.md).

## Entry reference

AA55 notation is control/function. F703/F706/F710 denotes Modbus RTU unit F7 and function03/06/10 on the dongle UDP endpoint. Hexadecimal prefixes and addresses are shown as recorded; explicit decimal addresses are annotated in entries. These are application encodings, not a claim that every command is accepted by this firmware.


### Home

#### item-001 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Parameters / Data

#### item-002 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Parameters / Alarm

#### item-003 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Settings / Communication Settings

#### item-004 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Settings / Basic Settings

#### item-005 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Settings / Advanced Settings

#### item-006 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Settings / Meter Function

#### item-007 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Settings / Device Information

#### item-008 — Open screen

- **Evidence:** visited

- **Read:** Live UI and read traffic

- **Write/action:** Navigation only

- **Encoding/validation:** No configuration commit

- **APK source:** com/goodwe/hybrid/fragment/SettingFragment.java



### Communication / Privacy & Security

#### item-009 — WLAN Module Password Change

- **Evidence:** visited

- **Read:** 5A5A version1/function01 ->81; V1.1.3.14

- **Write/action:** Version-dependent route to password editor

- **Encoding/validation:** V1.1.2+ selects UDP path

- **APK source:** com/goodwe/hybrid/activity/WIFIPrivacySecurityActivity.java:94



#### item-010 — New password

- **Evidence:** visited

- **Read:** No current password read into editor

- **Write/action:** 5A5A family2/01 with ASCII AT+WAKEY=WPA2PSK,AES,<password> CR LF; on ACK family1/0C reload

- **Encoding/validation:** Matching 8–16 characters: underscore, digits, upper/lowercase letters

- **Notes:** HTTP fallback exists for older module versions; not exercised on V1.1.3.14.

- **APK source:** com/goodwe/hybrid/activity/ModifyWifiPasswordActivity.java:448



#### item-011 — Confirm new password

- **Evidence:** visited

- **Read:** No current password read into editor

- **Write/action:** 5A5A family2/01 with ASCII AT+WAKEY=WPA2PSK,AES,<password> CR LF; on ACK family1/0C reload

- **Encoding/validation:** Matching 8–16 characters: underscore, digits, upper/lowercase letters

- **Notes:** HTTP fallback exists for older module versions; not exercised on V1.1.3.14.

- **APK source:** com/goodwe/hybrid/activity/ModifyWifiPasswordActivity.java:448



### Communication / WLAN/LAN

#### item-012 — Network Name

- **Evidence:** visited

- **Read:** 5A/02 length-prefixed SSID

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-013 — Encryption

- **Evidence:** visited

- **Read:** 5A/02 third length-prefixed string

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-014 — Password

- **Evidence:** visited

- **Read:** 5A/02 includes credential; keep captures private

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-015 — DHCP

- **Evidence:** visited

- **Read:** 5A/03 first CSV field

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-016 — IP Address

- **Evidence:** visited

- **Read:** 5A/03 second CSV field

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-017 — Subnet Mask

- **Evidence:** visited

- **Read:** 5A/03 third CSV field

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-018 — Gateway Address

- **Evidence:** visited

- **Read:** 5A/03 fourth CSV field

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-019 — DNS Server

- **Evidence:** visited

- **Read:** 5A/03 fifth CSV field

- **Write/action:** 5A5A/0B: U16 length + DHCP or static,IP,mask,gateway,DNS; then 0A: U16 total length + U8-length SSID, encryption, password; then 0C reload

- **Encoding/validation:** SSID nonempty; router password8–64 characters; static IPv4 fields validated; empty editor does not imply unset password

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:206



#### item-020 — Router hotspot list

- **Evidence:** control present; wire purpose traced statically

- **Read:** 5A5A/0E empty payload; READ_WIFI_LIST

- **Write/action:** Selection fills editor; Set commits

- **Encoding/validation:** Response parsed by createWifiListDialog

- **APK source:** com/goodwe/grid/solargo/settings/activity/InverterRouterSettingActivity.java:349



### Communication / WLAN Detection

#### item-021 — Module version

- **Evidence:** visited

- **Read:** 5A/01

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



#### item-022 — Router credentials / encryption

- **Evidence:** visited

- **Read:** 5A/02 and 0D

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



#### item-023 — Assigned network parameters

- **Evidence:** visited

- **Read:** 5A/03 CSV

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



#### item-024 — Server 1 connection

- **Evidence:** visited

- **Read:** 5A/04 payload01

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



#### item-025 — Server 2 connection

- **Evidence:** visited

- **Read:** 5A/04 payload02

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



#### item-026 — Packet counters

- **Evidence:** visited

- **Read:** 5A/05 payload01: channel U8, sent U16, received U16

- **Write/action:** Read-only Diagnosis / Re-diagnose

- **Encoding/validation:** Connection response one-byte number or length-delimited string

- **Notes:** 04 and 0D are traced diagnostic reads, not unknown setters. Diagnosis completed through relay.

- **APK source:** com/goodwe/hybrid/activity/WifiDiagnosisActivity.java:658



### Communication / 4G

#### item-027 — Area

- **Evidence:** visited

- **Read:** F703 B7C1 count004B (75 words); current fields displayed --

- **Write/action:** F710 B7C1 count0019 bytecount32; selected APN data

- **Encoding/validation:** Area/operator list from APN asset; Save confirmation

- **Notes:** Visible on this WiFi installation, but no functioning 4G configuration established; do not infer hardware capability from visibility.

- **APK source:** com/goodwe/hybrid/activity/ApnSettingHybridActivity.java



#### item-028 — Operator

- **Evidence:** visited

- **Read:** F703 B7C1 count004B (75 words); current fields displayed --

- **Write/action:** F710 B7C1 count0019 bytecount32; selected APN data

- **Encoding/validation:** Area/operator list from APN asset; Save confirmation

- **Notes:** Visible on this WiFi installation, but no functioning 4G configuration established; do not infer hardware capability from visibility.

- **APK source:** com/goodwe/hybrid/activity/ApnSettingHybridActivity.java



#### item-029 — APN Name

- **Evidence:** visited

- **Read:** F703 B7C1 count004B (75 words); current fields displayed --

- **Write/action:** F710 B7C1 count0019 bytecount32; selected APN data

- **Encoding/validation:** Area/operator list from APN asset; Save confirmation

- **Notes:** Visible on this WiFi installation, but no functioning 4G configuration established; do not infer hardware capability from visibility.

- **APK source:** com/goodwe/hybrid/activity/ApnSettingHybridActivity.java



### Basic / Grid Code

#### item-030 — Grid Code (Safety Code)

- **Evidence:** visited

- **Read:** Current Australia-A; basic overview reads safety and protection banks

- **Write/action:** SelectSetSafeCodeActivity; legacy 03/01 and region-dependent follow-up

- **Encoding/validation:** Installer login again; explicit Save; region/country choices

- **APK source:** com/goodwe/hybrid/activity/SelectSetSafeCodeActivity.java



#### item-031 — Export

- **Evidence:** visited

- **Read:** Current displayed safety overview

- **Write/action:** Local image export only

- **Encoding/validation:** Not an inverter write

- **APK source:** com/goodwe/hybrid/activity/SelectSafetyHybirdActivity.java:1002



### Basic / Select Working Mode

#### item-032 — General Mode

- **Evidence:** visited

- **Read:** Bulk01/09 current mode

- **Write/action:** ChooseWorkModeActivity workflow: schedule/offgrid setup then 03/59; do not reduce to one universal write

- **Encoding/validation:** General/off-grid/backup confirmation dialogs; TOU opens four-slot editor

- **Notes:** App modes are separate from EMS 056E. No mode changes committed.

- **APK source:** com/goodwe/hybrid/activity/ChooseWorkModeActivity.java



#### item-033 — Off-Grid Mode

- **Evidence:** visited

- **Read:** Bulk01/09 current mode

- **Write/action:** ChooseWorkModeActivity workflow: schedule/offgrid setup then 03/59; do not reduce to one universal write

- **Encoding/validation:** General/off-grid/backup confirmation dialogs; TOU opens four-slot editor

- **Notes:** App modes are separate from EMS 056E. No mode changes committed.

- **APK source:** com/goodwe/hybrid/activity/ChooseWorkModeActivity.java



#### item-034 — Backup Mode

- **Evidence:** visited

- **Read:** Bulk01/09 current mode

- **Write/action:** ChooseWorkModeActivity workflow: schedule/offgrid setup then 03/59; do not reduce to one universal write

- **Encoding/validation:** General/off-grid/backup confirmation dialogs; TOU opens four-slot editor

- **Notes:** App modes are separate from EMS 056E. No mode changes committed.

- **APK source:** com/goodwe/hybrid/activity/ChooseWorkModeActivity.java



#### item-035 — TOU Mode

- **Evidence:** visited

- **Read:** Bulk01/09 current mode

- **Write/action:** ChooseWorkModeActivity workflow: schedule/offgrid setup then 03/59; do not reduce to one universal write

- **Encoding/validation:** General/off-grid/backup confirmation dialogs; TOU opens four-slot editor

- **Notes:** App modes are separate from EMS 056E. No mode changes committed.

- **APK source:** com/goodwe/hybrid/activity/ChooseWorkModeActivity.java



### Basic / TOU / Time1

#### item-036 — Enabled

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; byte4=FF enabled; enable/disable workflow separate; bytes10..11 zero

- **Encoding/validation:** Save; boolean

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-037 — Start Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; bytes0,1 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59; app compares start and end

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-038 — End Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; bytes2,3 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-039 — Repeat

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; byte5 weekday mask; bytes10..11 zero

- **Encoding/validation:** Save; Sunday through Saturday; empty selection mask0

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-040 — Rated Power (%)

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; bytes6..7 signed percent; negative charge; bytes10..11 zero

- **Encoding/validation:** Save; integer0–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-041 — Charge / Discharge

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; sign of signed power; bytes10..11 zero

- **Encoding/validation:** Save; two choices

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-042 — Charge Cut-off SOC

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9BB/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47547; bytes8..9 U16 percent; discharge writes0; bytes10..11 zero

- **Encoding/validation:** Save; charge only,10–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



### Basic / TOU / Time2

#### item-043 — Enabled

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; byte4=FF enabled; enable/disable workflow separate; bytes10..11 zero

- **Encoding/validation:** Save; boolean

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-044 — Start Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; bytes0,1 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59; app compares start and end

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-045 — End Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; bytes2,3 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-046 — Repeat

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; byte5 weekday mask; bytes10..11 zero

- **Encoding/validation:** Save; Sunday through Saturday; empty selection mask0

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-047 — Rated Power (%)

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; bytes6..7 signed percent; negative charge; bytes10..11 zero

- **Encoding/validation:** Save; integer0–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-048 — Charge / Discharge

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; sign of signed power; bytes10..11 zero

- **Encoding/validation:** Save; two choices

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-049 — Charge Cut-off SOC

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C1/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47553; bytes8..9 U16 percent; discharge writes0; bytes10..11 zero

- **Encoding/validation:** Save; charge only,10–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



### Basic / TOU / Time3

#### item-050 — Enabled

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; byte4=FF enabled; enable/disable workflow separate; bytes10..11 zero

- **Encoding/validation:** Save; boolean

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-051 — Start Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; bytes0,1 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59; app compares start and end

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-052 — End Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; bytes2,3 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-053 — Repeat

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; byte5 weekday mask; bytes10..11 zero

- **Encoding/validation:** Save; Sunday through Saturday; empty selection mask0

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-054 — Rated Power (%)

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; bytes6..7 signed percent; negative charge; bytes10..11 zero

- **Encoding/validation:** Save; integer0–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-055 — Charge / Discharge

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; sign of signed power; bytes10..11 zero

- **Encoding/validation:** Save; two choices

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-056 — Charge Cut-off SOC

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9C7/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47559; bytes8..9 U16 percent; discharge writes0; bytes10..11 zero

- **Encoding/validation:** Save; charge only,10–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



### Basic / TOU / Time4

#### item-057 — Enabled

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; byte4=FF enabled; enable/disable workflow separate; bytes10..11 zero

- **Encoding/validation:** Save; boolean

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-058 — Start Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; bytes0,1 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59; app compares start and end

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-059 — End Time

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; bytes2,3 hour/minute; bytes10..11 zero

- **Encoding/validation:** Save; 00:00–23:59

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-060 — Repeat

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; byte5 weekday mask; bytes10..11 zero

- **Encoding/validation:** Save; Sunday through Saturday; empty selection mask0

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-061 — Rated Power (%)

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; bytes6..7 signed percent; negative charge; bytes10..11 zero

- **Encoding/validation:** Save; integer0–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-062 — Charge / Discharge

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; sign of signed power; bytes10..11 zero

- **Encoding/validation:** Save; two choices

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



#### item-063 — Charge Cut-off SOC

- **Evidence:** Time1 editor visited; slots2–4 same adapter/editor

- **Read:** F703 B9CD/6; twelve-byte slot

- **Write/action:** SetEcoModeData slot 47565; bytes8..9 U16 percent; discharge writes0; bytes10..11 zero

- **Encoding/validation:** Save; charge only,10–100

- **Notes:** Slot switch and editor save can have mode-selection side effects. Encoding traced; real write untested.

- **APK source:** com/goodwe/hybrid/activity/AddEcoModeActivity.java:258



### Basic / Battery Model

#### item-064 — Brand / model selection

- **Evidence:** visited

- **Read:** BatteryList low-voltage catalogue; current PYLONTECH US2000B-TB*2

- **Write/action:** 03/50 ->03/51 ->03/52 ->02/39(05A0,2) ->battery-index/protocol block; coefficient conditional

- **Encoding/validation:** Selecting model can immediately start coupled configuration

- **Notes:** DoD can be rewritten by battery selection: identified possible writer, not proof of reported spontaneous reset.

- **APK source:** com/goodwe/hybrid/activity/SelectBatteryOver07Activity.java:220



### Basic / Battery Model / SELF-DEFINE

#### item-065 — Battery Capacity

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/50 capacity U16 Ah

- **Encoding/validation:** 50–1000 Ah

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-066 — Charging Voltage

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/51 U16 tenths V

- **Encoding/validation:** 50–60 V

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-067 — Charging Current

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/51 U16 tenths A

- **Encoding/validation:** model-dependent range; C-rate confirmation >0.25C and >0.5C

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-068 — Discharge Current

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/52 U16 tenths A

- **Encoding/validation:** model-dependent range

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-069 — SOC Protection

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/3B 00,value,00

- **Encoding/validation:** switch; inverse stop-protection sense

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-070 — Depth Of Discharge (On-Grid)

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 03/52 byte4 =100-DoD

- **Encoding/validation:** selected battery limit; 80% here

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-071 — Depth Of Discharge (Off-grid)

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** 02/39 address05A1 or coupled05A0/2,100-DoD

- **Encoding/validation:** selected battery limit; 80% here

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-072 — Floating Voltage

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** battery-index/protocol block first U16

- **Encoding/validation:** editor 50–60 V branch; conversion truncates before multiplying10

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-073 — Floating Current

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** same block next U16

- **Encoding/validation:** 0–50 A; conversion truncates before multiplying10

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



#### item-074 — Floating Time

- **Evidence:** visited

- **Read:** Existing bulk settings prefill; opening editor does not apply model

- **Write/action:** same block next U16 minutes

- **Encoding/validation:** 0–60000 in validation branch

- **Notes:** Visited all visible fields without Settings submission. Final multi-command commit selects self-defined battery; not an isolated field write.

- **APK source:** com/goodwe/hybrid/activity/BatterySelfDefineActivity.java:451



### Advanced

#### item-075 — DRED/Remote Shutdown/RCR

- **Evidence:** visited

- **Read:** F703 B7BC/1

- **Write/action:** F706 B7BC U16 1/0

- **Encoding/validation:** boolean; regional visibility

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:2015



#### item-076 — Software Power Limit

- **Evidence:** visited

- **Read:** 01/89 backflow flag

- **Write/action:** 03/53

- **Encoding/validation:** boolean; hides/shows Power Limit Value

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:1832



#### item-077 — Power Limit Value

- **Evidence:** visited

- **Read:** 01/89 export limit; register0566

- **Write/action:** 03/35 U16 watts

- **Encoding/validation:** App uses signed-input-to-U16 conversion; no documented universal5000 maximum

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:2673



#### item-078 — Hardware Power Limit

- **Evidence:** visited

- **Read:** F7037506/1

- **Write/action:** F7067506 U16 1/0

- **Encoding/validation:** Oceania/export-limit gate

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:2065



#### item-079 — Shadow Scan

- **Evidence:** visited

- **Read:** 01/89 flag; register0558

- **Write/action:** 03/28 payload8080 enable /8000 disable

- **Encoding/validation:** boolean; preserve bitfield encoding

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:1802



#### item-080 — Backup

- **Evidence:** visited

- **Read:** 01/89 offset12;0556

- **Write/action:** 03/27 payload0000 enable /0030 disable per app builder

- **Encoding/validation:** boolean; distinct from actual backup output

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:1741



#### item-081 — Detection Mode

- **Evidence:** visited

- **Read:** 01/89 GRID_QUALITY_CHECK_VALUE

- **Write/action:** 03/5B via setDetectionMode

- **Encoding/validation:** UPS Full Wave / UPS Half Wave / EPS supports LVRT; Submit

- **APK source:** com/goodwe/hybrid/activity/DetectionModeActivity.java:180



#### item-082 — First Cold Start (Off-grid)

- **Evidence:** visited

- **Read:** Current settings

- **Write/action:** 03/26 via setStoreEnergyMode

- **Encoding/validation:** Backup must be ON; action affects operation

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:1771



#### item-083 — Battery Activated

- **Evidence:** visited

- **Read:** 01/89;0567

- **Write/action:** 03/37 U16 value

- **Encoding/validation:** boolean; battery wake-up function

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:1602



#### item-084 — Power Factor

- **Evidence:** visited

- **Read:** 01/89 field

- **Write/action:** 03/1F U8: truncate(PF*100), add100 if negative

- **Encoding/validation:** [-0.99,-0.8] or[0.8,1]

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:2694



#### item-085 — Clear Overload History

- **Evidence:** visited

- **Read:** No field read

- **Write/action:** 03/5E

- **Encoding/validation:** Action resets backup reconnection timer; not alarm history deletion

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:3176



#### item-086 — Output Active Power

- **Evidence:** visited

- **Read:** F703B1AC/1

- **Write/action:** F706B1AC U16 percent*10

- **Encoding/validation:** 0–100%, one decimal; not battery watt dispatch

- **APK source:** com/goodwe/hybrid/activity/AdvancedSettingNewActivity.java:2169



### Advanced / Battery Function

#### item-087 — Charging Voltage

- **Evidence:** visited

- **Read:** 01/89 offset24 /10

- **Write/action:** part of03/51

- **Encoding/validation:** read-only for selected lithium battery

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-088 — Charging Current

- **Evidence:** visited

- **Read:** 01/89 offset26 /2.66 for ESU

- **Write/action:** 03/51 uses physical tenths A

- **Encoding/validation:** read-only for selected lithium battery

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-089 — Discharge Current

- **Evidence:** visited

- **Read:** 01/89 offset28 /1.28 for ESU

- **Write/action:** 03/52 uses physical tenths A

- **Encoding/validation:** read-only for selected lithium battery

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-090 — SOC Protection

- **Evidence:** visited

- **Read:** 01/89 protection state

- **Write/action:** 03/3B payload00,value,00

- **Encoding/validation:** inverse stop-protection polarity

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-091 — Depth Of Discharge (On-Grid)

- **Evidence:** visited

- **Read:** 01/89 offset32;0560;100-raw

- **Write/action:** 03/52 also rewrites discharge voltage/current

- **Encoding/validation:** 0–80 for selected battery

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-092 — Depth Of Discharge (Off-grid)

- **Evidence:** visited

- **Read:** AA55 01/1A 05A1/1;100-raw

- **Write/action:** AA55 02/39 05A1 count1 U16minSOC

- **Encoding/validation:** 0–80 for selected battery;95 rejected before TX

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-093 — Immediate Charging

- **Evidence:** visited

- **Read:** F703 B9B9/2 first word

- **Write/action:** F706 B9B9 U16 1/0

- **Encoding/validation:** switch; ESU DSP>=22 gate

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



#### item-094 — Charge Cut-off SOC

- **Evidence:** conditional on Immediate Charging

- **Read:** F703 B9B9/2 second word

- **Write/action:** F706 B9BA U16 percent

- **Encoding/validation:** shown when immediate charging enabled;10–100

- **APK source:** com/goodwe/hybrid/activity/BatteryFunction105Activity.java



### Meter Function / Meter/CT Detection

#### item-095 — Meter/CT Detection

- **Evidence:** visited

- **Read:** AA55 01/1A 059C count2

- **Write/action:** AA55 02/39 059C count1 U16 1 start /0 stop

- **Encoding/validation:** Test may temporarily disable power limiting; requires battery communications/discharge

- **Notes:** Page visited; physical test not run because current BMS communication failure invalidates prerequisites.

- **APK source:** com/goodwe/hybrid/activity/CTCheckActivity.java



#### item-096 — Test Status

- **Evidence:** visited

- **Read:** 059C/2

- **Write/action:** none

- **Encoding/validation:** Test may temporarily disable power limiting; requires battery communications/discharge

- **Notes:** Page visited; physical test not run because current BMS communication failure invalidates prerequisites.

- **APK source:** com/goodwe/hybrid/activity/CTCheckActivity.java



#### item-097 — Test Results

- **Evidence:** visited

- **Read:** 059C/2

- **Write/action:** none

- **Encoding/validation:** Test may temporarily disable power limiting; requires battery communications/discharge

- **Notes:** Page visited; physical test not run because current BMS communication failure invalidates prerequisites.

- **APK source:** com/goodwe/hybrid/activity/CTCheckActivity.java



### Device Information

#### item-098 — DSP Information

- **Evidence:** visited

- **Read:** Identity firmware text / app constants

- **Write/action:** none

- **Encoding/validation:** BMS read failure or wrong length becomes0 then formatted00

- **Notes:** Observed --.-- then00; not verified zero firmware.

- **APK source:** com/goodwe/hybrid/activity/FirmwareInfoAndUpdateActivity.java:738



#### item-099 — ARM Information

- **Evidence:** visited

- **Read:** Identity firmware text / app constants

- **Write/action:** none

- **Encoding/validation:** BMS read failure or wrong length becomes0 then formatted00

- **Notes:** Observed --.-- then00; not verified zero firmware.

- **APK source:** com/goodwe/hybrid/activity/FirmwareInfoAndUpdateActivity.java:738



#### item-100 — BMS Information

- **Evidence:** visited

- **Read:** F7030780/1 after F70390C4/16 battery serial read

- **Write/action:** none

- **Encoding/validation:** BMS read failure or wrong length becomes0 then formatted00

- **Notes:** Observed --.-- then00; not verified zero firmware.

- **APK source:** com/goodwe/hybrid/activity/FirmwareInfoAndUpdateActivity.java:738



### Device Information / Update Record

#### item-101 — Firmware name / time / type / version / result

- **Evidence:** visited

- **Read:** HybridUpgradeRecordActivity server record request by serial

- **Write/action:** none

- **Encoding/validation:** Historical records are not current firmware readback

- **APK source:** com/goodwe/hybrid/activity/HybridUpgradeRecordActivity.java



### Advanced / Safety / Protection

#### item-102 — over_voltage_level_1_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45400 (0xB158)

- **Write/action:** f706b158 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:10



#### item-103 — over_voltage_level_1_time_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45401 (0xB159)

- **Write/action:** f706b159 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:11



#### item-104 — under_voltage_level_1_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45402 (0xB15A)

- **Write/action:** f706b15a + big-endian encoded value + CRC

- **Encoding/validation:** [0, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:12



#### item-105 — under_voltage_level_1_time_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45403 (0xB15B)

- **Write/action:** f706b15b + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:13



#### item-106 — over_voltage_level_2_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45404 (0xB15C)

- **Write/action:** f706b15c + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:14



#### item-107 — over_voltage_level_2_time_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45405 (0xB15D)

- **Write/action:** f706b15d + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:15



#### item-108 — under_voltage_level_2_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45406 (0xB15E)

- **Write/action:** f706b15e + big-endian encoded value + CRC

- **Encoding/validation:** [0, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:16



#### item-109 — under_voltage_level_2_time_phase

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45407 (0xB15F)

- **Write/action:** f706b15f + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:17



#### item-110 — over_voltage_phase_10min

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45408 (0xB160)

- **Write/action:** f706b160 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:18



#### item-111 — over_frequency_level_1

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45409 (0xB161)

- **Write/action:** f706b161 + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:19



#### item-112 — over_frequency_level_1_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45410 (0xB162)

- **Write/action:** f706b162 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:20



#### item-113 — under_frequency_level_1

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45411 (0xB163)

- **Write/action:** f706b163 + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:21



#### item-114 — under_frequency_level_1_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45412 (0xB164)

- **Write/action:** f706b164 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:22



#### item-115 — over_frequency_level_2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45413 (0xB165)

- **Write/action:** f706b165 + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:23



#### item-116 — over_frequency_level_2_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45414 (0xB166)

- **Write/action:** f706b166 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:24



#### item-117 — under_frequency_level_2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45415 (0xB167)

- **Write/action:** f706b167 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:25



#### item-118 — under_frequency_level_2_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45416 (0xB168)

- **Write/action:** f706b168 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:26



#### item-180 — over_voltage_level_3_phase

- **Evidence:** visited Basic safety overview; not shown in Advanced protection tab

- **Read:** F703 bank containing 45495 (0xB1B7)

- **Write/action:** f706b1b7 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:92



#### item-181 — over_voltage_level_3_time_phase

- **Evidence:** visited Basic safety overview; not shown in Advanced protection tab

- **Read:** F703 bank containing 45496 (0xB1B8)

- **Write/action:** f706b1b8 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02, 1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:93



#### item-182 — under_voltage_level_3_phase

- **Evidence:** visited Basic safety overview; not shown in Advanced protection tab

- **Read:** F703 bank containing 45497 (0xB1B9)

- **Write/action:** f706b1b9 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:94



#### item-183 — under_voltage_level_3_time_phase

- **Evidence:** visited Basic safety overview; not shown in Advanced protection tab

- **Read:** F703 bank containing 45498 (0xB1BA)

- **Write/action:** f706b1ba + big-endian encoded value + CRC

- **Encoding/validation:** [0.02, 1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:95



### Advanced / Safety / Connection

#### item-119 — connect_voltage_upper_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45417 (0xB169)

- **Write/action:** f706b169 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:28



#### item-120 — connect_voltage_lower_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45418 (0xB16A)

- **Write/action:** f706b16a + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:29



#### item-121 — connect_frequency_upper_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45419 (0xB16B)

- **Write/action:** f706b16b + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:30



#### item-122 — connect_frequency_lower_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45420 (0xB16C)

- **Write/action:** f706b16c + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:31



#### item-123 — grid_connect_wait_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45421 (0xB16D)

- **Write/action:** f706b16d + big-endian encoded value + CRC

- **Encoding/validation:** [1, 1200]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:32



#### item-124 — connect_voltage_upper_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45422 (0xB16E)

- **Write/action:** f706b16e + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:33



#### item-125 — connect_voltage_lower_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45423 (0xB16F)

- **Write/action:** f706b16f + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:34



#### item-126 — connect_frequency_upper_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45424 (0xB170)

- **Write/action:** f706b170 + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:35



#### item-127 — connect_frequency_lower_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45425 (0xB171)

- **Write/action:** f706b171 + big-endian encoded value + CRC

- **Encoding/validation:** [30, 80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:36



#### item-128 — grid_wait_time_lower_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45426 (0xB172)

- **Write/action:** f706b172 + big-endian encoded value + CRC

- **Encoding/validation:** [1, 1200]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:37



#### item-129 — grid_frequency_wait_time_lower_fault

- **Evidence:** excluded from observed target surface: not exposed as an independent field in this target walkthrough

- **Read:** F703 bank containing 45427 (0xB173)

- **Write/action:** f706b173 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 65535]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:38



#### item-130 — grid_connect_power_rate

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45428 (0xB174)

- **Write/action:** f706b174 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1200]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:39



#### item-131 — grid_connect_power_rate_under_fault

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45429 (0xB175)

- **Write/action:** f706b175 + big-endian encoded value + CRC

- **Encoding/validation:** [1, 65535]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:40



#### item-132 — power_slope_enable

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45432 (0xB178)

- **Write/action:** f706b178 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:41



### Advanced / Safety / Curves

#### item-133 — cos_curve

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45433 (0xB179)

- **Write/action:** f706b179 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:43



#### item-134 — power_point_a

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45434 (0xB17A)

- **Write/action:** f706b17a + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:44



#### item-135 — power_point_a_cos

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45435 (0xB17B)

- **Write/action:** f706b17b + big-endian encoded value + CRC

- **Encoding/validation:** [-1, 1]; raw / 100; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:45



#### item-136 — power_point_b

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45436 (0xB17C)

- **Write/action:** f706b17c + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:46



#### item-137 — power_point_b_cos

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45437 (0xB17D)

- **Write/action:** f706b17d + big-endian encoded value + CRC

- **Encoding/validation:** [-1, 1]; raw / 100; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:47



#### item-138 — power_point_c

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45438 (0xB17E)

- **Write/action:** f706b17e + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:48



#### item-139 — power_point_c_cos

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45439 (0xB17F)

- **Write/action:** f706b17f + big-endian encoded value + CRC

- **Encoding/validation:** [-1, 1]; raw / 100; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:49



#### item-140 — entry_curve_voltage

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45440 (0xB180)

- **Write/action:** f706b180 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:50



#### item-141 — exit_curve_voltage

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45441 (0xB181)

- **Write/action:** f706b181 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:51



#### item-142 — exit_curve_power

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45442 (0xB182)

- **Write/action:** f706b182 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:52



#### item-143 — qu_curve

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45456 (0xB190)

- **Write/action:** f706b190 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:53



#### item-144 — entry_curve_power

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45457 (0xB191)

- **Write/action:** f706b191 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:54



#### item-145 — exit_curve_power_2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45458 (0xB192)

- **Write/action:** f706b192 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:55



#### item-146 — voltage_v1

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45459 (0xB193)

- **Write/action:** f706b193 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:56



#### item-147 — reactive_v1

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45460 (0xB194)

- **Write/action:** f706b194 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:57



#### item-148 — voltage_v2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45461 (0xB195)

- **Write/action:** f706b195 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:58



#### item-149 — reactive_v2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45462 (0xB196)

- **Write/action:** f706b196 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:59



#### item-150 — voltage_v3

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45463 (0xB197)

- **Write/action:** f706b197 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:60



#### item-151 — reactive_v3

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45464 (0xB198)

- **Write/action:** f706b198 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:61



#### item-152 — voltage_v4

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45465 (0xB199)

- **Write/action:** f706b199 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:62



#### item-153 — reactive_v4

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45466 (0xB19A)

- **Write/action:** f706b19a + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:63



#### item-154 — reactive_qu

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45468 (0xB19C)

- **Write/action:** f706b19c + big-endian encoded value + CRC

- **Encoding/validation:** [0, 60]; seconds=819.2/raw-0.2; write truncates819.2/(seconds+0.2); raw0 displays infinity

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:64



#### item-155 — cos_qu

- **Evidence:** conditional: cosφ(P) currently OFF; field traced statically

- **Read:** F703 bank containing 45510 (0xB1C6)

- **Write/action:** f706b1c6 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 60]; raw / 2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:65



#### item-156 — pu_curve

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45472 (0xB1A0)

- **Write/action:** f706b1a0 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:66



#### item-157 — voltage_v1_power

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45474 (0xB1A2)

- **Write/action:** f706b1a2 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:67



#### item-158 — active_v1

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45475 (0xB1A3)

- **Write/action:** f706b1a3 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:68



#### item-159 — voltage_v2_power

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45476 (0xB1A4)

- **Write/action:** f706b1a4 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:69



#### item-160 — active_v2

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45477 (0xB1A5)

- **Write/action:** f706b1a5 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:70



#### item-161 — voltage_v3_power

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45478 (0xB1A6)

- **Write/action:** f706b1a6 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:71



#### item-162 — active_v3

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45479 (0xB1A7)

- **Write/action:** f706b1a7 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:72



#### item-163 — voltage_v4_power

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45480 (0xB1A8)

- **Write/action:** f706b1a8 + big-endian encoded value + CRC

- **Encoding/validation:** [60, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:73



#### item-164 — active_v4

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45481 (0xB1A9)

- **Write/action:** f706b1a9 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:74



#### item-165 — active_pu

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45512 (0xB1C8)

- **Write/action:** f706b1c8 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 60]; seconds=819.2/raw-0.2; write truncates819.2/(seconds+0.2); raw0 displays infinity

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:75



#### item-166 — response_time

- **Evidence:** excluded from observed target surface: different firmware/model response-time branch

- **Read:** F703 bank containing 45728 (0xB2A0)

- **Write/action:** f706b2a0 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1000]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:76



#### item-167 — fp_curve

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45443 (0xB183)

- **Write/action:** f706b183 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:77



#### item-168 — of_start_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45444 (0xB184)

- **Write/action:** f706b184 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:78



#### item-169 — uf_start_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45445 (0xB185)

- **Write/action:** f706b185 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:79



#### item-170 — of_end_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45446 (0xB186)

- **Write/action:** f706b186 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:80



#### item-171 — uf_end_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45447 (0xB187)

- **Write/action:** f706b187 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:81



#### item-172 — recovery_wait_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45448 (0xB188)

- **Write/action:** f706b188 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1200]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:82



#### item-173 — recovery_high_frequency

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45449 (0xB189)

- **Write/action:** f706b189 + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:83



#### item-174 — recovery_low_frequency

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45450 (0xB18A)

- **Write/action:** f706b18a + big-endian encoded value + CRC

- **Encoding/validation:** [30,80]; raw / 100

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:84



#### item-175 — recovery_slope

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45451 (0xB18B)

- **Write/action:** f706b18b + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1200]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:85



#### item-176 — fp_setting

- **Evidence:** excluded from observed target surface: not exposed as an independent field in this target walkthrough

- **Read:** F703 bank containing 45452 (0xB18C)

- **Write/action:** f706b18c + big-endian encoded value + CRC

- **Encoding/validation:** [0, 65535]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:86



#### item-177 — of_power_slope

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45453 (0xB18D)

- **Write/action:** f706b18d + big-endian encoded value + CRC

- **Encoding/validation:** [-1000,1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:87



#### item-178 — uf_power_slope

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45454 (0xB18E)

- **Write/action:** f706b18e + big-endian encoded value + CRC

- **Encoding/validation:** [-1000,1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:88



#### item-179 — recovery_power_slope

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45455 (0xB18F)

- **Write/action:** f706b18f + big-endian encoded value + CRC

- **Encoding/validation:** [-1000,2000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:89



#### item-184 — uwItalyFreqMode

- **Evidence:** excluded from observed target surface: Italy regional branch

- **Read:** F703 bank containing 45490 (0xB1B2)

- **Write/action:** f706b1b2 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 4]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:96



#### item-196 — pq_curve_switch

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45526 (0xB1D6)

- **Write/action:** f706b1d6 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:109



#### item-197 — p1_gen_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45527 (0xB1D7)

- **Write/action:** f706b1d7 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1000]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:110



#### item-198 — q1_gen_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45528 (0xB1D8)

- **Write/action:** f706b1d8 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:111



#### item-199 — p2_gen_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45529 (0xB1D9)

- **Write/action:** f706b1d9 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1000]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:112



#### item-200 — q2_gen_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45530 (0xB1DA)

- **Write/action:** f706b1da + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:113



#### item-201 — p3_gen_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45531 (0xB1DB)

- **Write/action:** f706b1db + big-endian encoded value + CRC

- **Encoding/validation:** [0, 1000]; raw value

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:114



#### item-202 — q3_gen_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45532 (0xB1DC)

- **Write/action:** f706b1dc + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:115



#### item-203 — p1_load_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45533 (0xB1DD)

- **Write/action:** f706b1dd + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 0]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:116



#### item-204 — q1_load_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45534 (0xB1DE)

- **Write/action:** f706b1de + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:117



#### item-205 — p2_load_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45535 (0xB1DF)

- **Write/action:** f706b1df + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 0]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:118



#### item-206 — q2_load_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45536 (0xB1E0)

- **Write/action:** f706b1e0 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:119



#### item-207 — p3_load_active_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45537 (0xB1E1)

- **Write/action:** f706b1e1 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 0]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:120



#### item-208 — q3_load_reactive_power

- **Evidence:** excluded from observed target surface: PQ curve branch

- **Read:** F703 bank containing 45538 (0xB1E2)

- **Write/action:** f706b1e2 + big-endian encoded value + CRC

- **Encoding/validation:** [-1000, 1000]; raw value; signed two-byte interpretation required for negative values

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:121



### Advanced / Safety / Other

#### item-185 — LVRT / HVRT Extended Functions (shared register)

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45499 (0xB1BB)

- **Write/action:** f706b1bb + big-endian encoded value + CRC

- **Encoding/validation:** shared U16 bitfield: bit0 LVRT, bit1 HVRT; 0 neither,1 LVRT,2 HVRT,3 both; preserve other switch

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:97



#### item-186 — low_ride_through_start_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45500 (0xB1BC)

- **Write/action:** f706b1bc + big-endian encoded value + CRC

- **Encoding/validation:** [0, 230]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:98



#### item-187 — low_ride_through_end_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45501 (0xB1BD)

- **Write/action:** f706b1bd + big-endian encoded value + CRC

- **Encoding/validation:** [0, 230]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:99



#### item-188 — low_start_point_protection_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45502 (0xB1BE)

- **Write/action:** f706b1be + big-endian encoded value + CRC

- **Encoding/validation:** [0.02, 1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:100



#### item-189 — low_end_point_protection_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45503 (0xB1BF)

- **Write/action:** f706b1bf + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:101



#### item-190 — low_ride_through_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45504 (0xB1C0)

- **Write/action:** f706b1c0 + big-endian encoded value + CRC

- **Encoding/validation:** [0, 230]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:102



#### item-191 — high_ride_through_start_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45505 (0xB1C1)

- **Write/action:** f706b1c1 + big-endian encoded value + CRC

- **Encoding/validation:** [100, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:103



#### item-192 — high_ride_through_end_point

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45506 (0xB1C2)

- **Write/action:** f706b1c2 + big-endian encoded value + CRC

- **Encoding/validation:** [100, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:104



#### item-193 — high_start_point_protection_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45507 (0xB1C3)

- **Write/action:** f706b1c3 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02,1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:105



#### item-194 — high_end_point_protection_time

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45508 (0xB1C4)

- **Write/action:** f706b1c4 + big-endian encoded value + CRC

- **Encoding/validation:** [0.02, 1000]; raw / nominal grid Hz (50 for Australia-A), not gain_hint2

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:106



#### item-195 — high_ride_through_limit

- **Evidence:** parent visited; field mapping traced statically and compared with visible rows

- **Read:** F703 bank containing 45509 (0xB1C5)

- **Write/action:** f706b1c5 + big-endian encoded value + CRC

- **Encoding/validation:** [230, 300]; raw / 10

- **Notes:** Generic editor CustomSaftyParamSettingActivity; declared enum units/types can be wrong. Live UI uses permille for curve power, seconds for slopes, booleans for switches.

- **APK source:** com/goodwe/hybrid/bean/CustomSaftyParamEnum.java:107


## Implemented ESU DSP23 / ARM14 mode transactions

`config.basic.working_mode.activation.requested_mode` stages General, Off-grid,
Backup or TOU; increment `apply` to execute the source-traced AA55 sequence.
This form is scoped to GW5048D-ES and the observed newer-Eco branch, not every
inverter sharing a legacy model name. SolarGo's `supportNewEcoMode` requires
ARM≥14 and ESU DSP≥22; the surveyed DSP23/ARM14 qualifies.

| Mode | Ordered operations |
| --- | --- |
| General | Clear0700=1;03/59 payload00;03/36 payload00 |
| Off-grid | Clear0700=1;03/27 payload0030;03/26 payload04;03/36 payload01;03/59 payload01 |
| Backup | Clear0700=1;03/36 payload00;03/2C payload0000173B0A;03/59 payload02 |
| TOU |03/59 payload03; period editing remains separate |

Clear is AA55 control02/function39 with payload0700010001. Backup's charge
period is00:00–23:59 at10%. The activity sets `SelectRelayControl=3` and
`SelectStoreEnergyMode=0`; buildPackage51 encodes the former as0030 and
buildPackage47 encodes the latter as04. These are selectors, not wire values.
`Constant.RESPONSE_SetRelayControl_CODE` is03/A7 and
`RESPONSE_SetStoreEnergyMode_CODE` is03/A6. The writer requires a positive06 ACK per
step, stops after failure, then reads01/09 and verifies mode bytes66–67. This
verifies the final application-mode register, not backup continuity, autonomous
watchdog release or all intermediate physical effects. There is no rollback.

Sources: `ChooseWorkModeActivity.initESEMGeneralModeDialog`,
`initESEMBackupModeDialog`, `initESEMOffgridModeDialog`,
`DataCollectUtil.buildPackage`, `clearBatteryModeParam`, and
`DataProcessUtil.setEcoModeData`. Older firmware paths also rewrite old charge/
discharge periods and remain separate from this form.

Both profiles now provide the UDP-capable module network/router and WLAN password
forms under `config.communication.wlan_lan`. The observed ES module reports
V1.1.3.14; SolarGo selects its UDP password path for this version. Network apply
sends5A5A family1/0B,1/0A,1/0C; password apply sends family2/01 then1/0C. ACKs are
reported separately from successful reconnect/readback. The older HTTP route is
not silently represented as the same operation.


First Cold Start uses the same store command independently of mode activation:
checked selects0 and emits03/26 payload04; unchecked selects3 and emits01.
`config.advanced.cold_start.enable_request` and `.disable_request` expose explicit
ACK-only actions. Backup supply must already be enabled. The app updates a local
flag after ACK; that flag is not an independent physical-state readback.


The ES meter/CT test component exposes independent status/result codes and
explicit start/stop request counters. The latter reproduce AA55 register059C
values1/0, with vendor ACK06. They do not start on profile load and do not claim
completion from an ACK. The app's battery-discharge/communication requirements
and power-limit interaction still need physical validation.
