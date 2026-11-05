# SolarGo 7.2.2 installed-app evidence

Reconciled protocol tables and identified-surface document:
[GOODWE_REFERENCE.md](GOODWE_REFERENCE.md).

Inspected 2026-10-29. Package `com.goodwe.solargo`, versionCode 1521,
versionName 7.2.2, pulled from the user's Android emulator. Base APK SHA-256:
`777549fd41ac954134ff5e20927cfeb3b78dcab6d44b1188946658cd16de4b67`.
JADX 1.5.6 produced readable methods but reported 457 decompilation errors.
These are static observations, not proof of the path taken in a live session.
The APK and generated sources remain private investigation artifacts in `.tmp/`.

## Password reminder

`com.goodwe.hybrid.fragment.OverviewFragment.initDatas()` shows
`solargo_wlan_password_tips` when all these conditions hold:

- Shared preference `WIFI_STATUS_SEC` equals `"1"` (also its default).
- The app is not in demo mode and `INVERTER_TYPE == 1`.
- `ModelUtils.notOneModel()` is false and `MODULE_WIFI_RAK` is false.
- The serial-specific `<inverter serial>_rak` preference is false.

That branch does not inspect a password-status reply or password value.
The dialog's never-prompt action sets the serial-specific preference.
`WelcomeActivity.getWIFISecurityStatus()` downloads a policy value and stores
it in `WIFI_STATUS_SEC`; this is separate from inverter password state.
Therefore this reminder alone is not evidence of an unset module password.

`WLANDeviceFragment.onItemClick()` classifies a module as RAK when the discovery
MAC string contains `60C5A8`; it also recognizes `ccm` and other module tags.
Changing the proxy discovery identity can consequently change app paths.
Do not spoof a different hardware class merely to suppress the reminder.

## Home WLAN-module error

`OverviewFragment.refreshNewData()` schedules `showNADialog()` with WiFi enabled
when either `BroadcastFailCount` or `CollectorFailCount` reaches 10, provided
the dialog has not already been shown and the shared dialog gate is zero.
`showNADialog()` displays `dialog_Unable_to_connect_inverter`, the exact message
in the user's screenshot. It resets those counters to 0 and 4 respectively.

`DataCollectUtil.getRunningData1()` resets `CollectorFailCount` only after a
received frame passes `checkPackageType(...) == 9` and `saveInventerData(...)`
returns true. A non-null frame of the wrong type, or a failed payload decode,
increments the counter. `saveData()` catches exceptions, logs under
`DataCollectUtil--saveData()`, and returns false after potentially assigning
some displayed values. Partial or cached telemetry therefore cannot establish
that the complete runtime reply passed validation.

`checkPackageType()` checks the additive checksum and control/function bytes.
`fetchData()` requires total length = payload-length byte + 9.
The precise failing reply/exception in the proxy session is still unknown.
Next live evidence: capture logcat alongside raw requests/replies, particularly
the `saveData()` exception tag and the `获取0106成功` runtime-success log.

## Battery Function

For the 105-platform screen, `BatteryFunction105Activity.getBatterySoc()` expects
one four-byte payload from `DataCollectUtil.readBatterySoc()`. That method sends
Modbus `F7 03 B9B9 0002` and requires an 11-byte GoodWe-prefixed response with
valid CRC. Failure shows `get_data_fail`. The two payload words populate the
immediate-charge switch and target SOC. This identifies an exact toast path;
it does not prove this was the failing operation in the user's session.

The same activity separately calls `getOffineDod()` and requires a two-byte
result, displayed as `100 - raw`. A missing/wrong-length result leaves the
off-grid DoD display blank. Existing captured B9B9 and 05A1 replies must be
checked through the app's receive/filter path, not only through our decoder.

## Discovery and module version

`ServerIPSearcher` broadcasts `WIFIKIT-214028-READ` to UDP/48899, receives with
a 500 ms timeout, retries on timeout for a five-second search, and uses the
reply packet's source IP as the connection address. It takes MAC/name from
the comma-delimited payload and excludes names containing WFA, WLA or WNN.

`WLANDeviceFragment.getSolarWifiVersion()` calls
`GoodweAPIs.getWifiModuleVersion()` except for selected module tags. The API
sends `5A5A 01 01 0000` plus CRC over UDP/8899, with up to three attempts and
a two-second timeout. Its parser reads the big-endian payload length at bytes
4–5 and UTF-8 text at byte 6, removing `V` from the stored version string.
The emulator subsequently captured the real response with payload V1.1.3.14,
matching HTTP. See [operational discovery](GOODWE_OPERATIONAL_DISCOVERY.md).

The emulator was relaunched and the real device's Home, Parameters, Alarms,
communications, Advanced and Battery Function screens exercised. Discovery also
uses `GoodFinder`; `ServerIPSearcher` above is not a complete account of the live
path. The privacy reminder appeared against the real inverter. Its Home loaded
without the proxy WLAN error. Logcat contained successful runtime-read messages;
the proxy-specific causal failure is still unresolved. No physical module
configuration was changed. The complete pass and capture limits are recorded in
[the capture manifest](GOODWE_EMULATOR_CAPTURE_20261029.json).

The generated [factory/call-site index](GOODWE_SOLARGO_FACTORY_INDEX.json) makes
the broader APK surface searchable. It includes other model families and
unresolved expressions; decompilation errors and runtime branches preclude a
claim that this is every possible app command.
