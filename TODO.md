# Engineering task accumulator

Deferred work lands here as dated sections; remove a section once it is absorbed.

## 2026-08-26: profiles should express derived values instead of inventing attribute ids

An IAS Zone device reports its whole state as bits of one attribute, `0x0002` (ZoneStatus,
a `map16`). The profile has no way to say "this element is bit 3 of that attribute", so it
invents an address per bit instead:

```
zb: 0x500, 0xFC01, bool    desc: alarm2
zb: 0x500, 0xFC03, bool    desc: low_battery
```

Nothing on the device answers to `0xFC01`. Priming duly asked for those ids and the reads
came back unsupported, so a contact sensor's state could not be fetched at all; the
controller carries `apply_zone_status` to decode the real attribute by hand, priming carries
a special case for cluster `0x0500`, and both are guarded by treating `>= 0xFC00` as a
never-readable range by convention.

The shared value-spec grammar already covers this and no profile uses it yet:

```
//   <family><width>[_mods][@bit][:name][[N]]
compile_spec("bool@3", ...)  ->  bit_width=1, bit_offset=3
```

So the mapping wants to become:

```
zb: 0x500, 0x0002, bool@0    desc: alarm1
zb: 0x500, 0x0002, bool@3    desc: low_battery
```

reading the attribute the value really lives in, with the generic decode extracting the bit.

Blocked on the element index: `_sample_elements` is keyed by
`(eui, endpoint, cluster, attribute)` and asserts one element per key
(`"TODO: support element duplicates?"`), so seven elements cannot share attribute `0x0002`.
That index has to hold a list per key, and every write path becomes "update all matching"
rather than "update the one". The synthetic ids exist only to manufacture unique keys.

Doing it deletes `apply_zone_status`, the priming special case and the `0xFC00` guard, and
generalises well beyond zigbee: Modbus status/alarm registers, CAN signals (which are only
ever bit offset plus width), ZCL `map8`/`map16` attributes, Tuya bitmap datapoints and
SunSpec bitfields all pack many values into one wire value.

Two values do not fit the model and want deciding separately: the notification's `zone_id`
has a real attribute (`0x0011`) it could map to, and `delay` exists only in the command
payload with no attribute behind it at all.
