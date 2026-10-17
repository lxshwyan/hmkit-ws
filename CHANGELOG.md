# Changelog

## 0.1.2 - 2026-10-17

- Fixed `@hmkit/ws-native` type declarations so consumers can import all ArkTS transport/server adapters.
- Hardened polling HTTP and IM file-store exception/recovery handling and added a handshake-failure regression test.
- Synchronized core, server, native, app, and Rust crate versions and upgraded Hypium to 1.0.29.
- Added coverage floors, full API contracts, HAR security/metadata scans, isolated three-package consumers, and hosted interoperability CI.

## 0.1.1 - 2026-09-02

- Added Chinese-first README content for all OHPM packages.
- Added complete author, homepage and repository metadata to optional packages.

## 0.1.0 - 2026-09-02

- Added the API 12+ pure-ArkTS WebSocket client and extension contracts.
- Added configurable reconnect, heartbeat, queue, codec and persistence policies.
- Added Socket.IO 4 polling/WebSocket, STOMP 1.2 and MQTT 3.1.1/5 clients.
- Added opt-in IM persistence and the API 19+ Network Kit server backend.
- Added the optional Rust/Node-API client/server backend for three OHOS ABIs.
- Added reference-server interoperability tests and release verification scripts.
