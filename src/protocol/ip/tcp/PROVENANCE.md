# lwIP TCP

This directory is a D port of the TCP module from [lwIP](https://savannah.nongnu.org/projects/lwip/) (Adam Dunkels / SICS, modified BSD 3-clause). The per-file copyright headers are preserved verbatim in each `.d` file.

Base snapshot: lwIP `<TODO: tag or commit hash>`.

## Porting strategy

Each `.d` file is a line-for-line port of its lwIP counterpart — same function names, same structure, same control flow. Auxiliary D-only files (`ip.d`, `package.d`) hold the glue that maps lwIP's abstractions (`ip_addr_t`, `netif`, `ip_output_if`) onto OpenWatt types (`IPAddr`, `BaseInterface`, `IPStack`).

## Updating

To pull a newer lwIP release:

1. `git diff <base-commit>..<new-commit> -- src/core/tcp*.c src/include/lwip/tcp*.h src/include/lwip/priv/tcp_priv.h` against the upstream repo.
2. Apply the same logical changes to the corresponding `.d` files here.
3. Update `ip.d` / `package.d` if upstream changed any of the integration-point signatures.
4. Bump the base-snapshot reference at the top of this file.
