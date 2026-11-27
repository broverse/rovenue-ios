# ``Rovenue``

Subscription, entitlement, and funnel client for the open-source Rovenue
backend — a Swift façade over the shared `librovenue` Rust core.

## Overview

``Rovenue`` is the SDK's single entry point: identify subscribers, read
entitlements, fetch offerings and funnels, submit App Store / Play receipts
for validation — all routed through the same
Rust core that backs the Kotlin, React Native, and Flutter façades, so
behavior (bucketing, caching, retry) is identical across platforms.

This reference is generated from the doc comments on the public API; see the
[iOS guide](https://docs.rovenue.io/docs/platforms/ios-swift) for
a quickstart and installation instructions.

## Topics

### Essentials

- ``Rovenue``

### Entitlements & Offerings

- ``Entitlement``
- ``Offering``
- ``StoreProduct``

### Funnels

- ``RovenueFunnelView``
- ``FunnelDriver``
- ``FunnelHostHandlers``
- ``ResolvedFunnel``
