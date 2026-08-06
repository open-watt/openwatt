# UX client task accumulator

Client-visible changes land here as dated task sections; UX clients (sync consumers) work
through them and remove sections as they are absorbed.

## 2026-08-07: interfaces expose a `caps` property

- All `/interface` collections gain a read-only `caps` bitfield property naming the
  interface's transport promises: `ethernet`, `reliable` (acknowledged/retransmitted
  delivery), `ordered` (in-order delivery). Clients rendering interface detail views may
  surface it; absence of a flag means no promise, not a fault.
