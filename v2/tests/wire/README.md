# Shared wire fixture contract

`contract-v6.json` is the bounded canonical byte corpus for protocol version 6. `../wire-contract-test.sh` validates its schema, proves all four source constants equal 6, then runs the Zig, Rust, Go API, and Go bench corpus consumers.

The corpus is normative for the examples it contains. The behavioral protocol remains defined by [the control-plane contract](../../docs/design/CONTROL_PLANE_CONTRACT.md); source-owned bounds and codecs remain in [`core/src/connection.zig`](../../core/src/connection.zig), [`worker/src/protocol.rs`](../../worker/src/protocol.rs), [`api/client.go`](../../api/client.go), and [`bench/main.go`](../../bench/main.go).

## Bounded schema

The top-level object has exactly these fields:

| Field | Meaning |
|---|---|
| `schema` | Must equal `hivemind-wire-contract-v1`. |
| `protocol_version` | Must equal `6`. |
| `encoding` | Exact textual definitions for byte order, hex, frame, AAD, and peer-body semantics. |
| `test_material` | One explicitly insecure 32-byte PSK and 24-byte nonce used only for deterministic fixtures. |
| `statuses` | The complete legal `/run` status inventory, bytes `0` through `9`, including permitted origins. |
| `vectors` | At most 32 canonical examples. The committed corpus contains 14. |

The file is capped at 256 KiB. A frame is capped at 64 KiB and a fixture payload at 16 KiB. Hex is lowercase, even-length, and has no prefix or separators. Duplicate vector IDs, unknown fields, unknown consumers, noncanonical status inventories, inconsistent lengths, and malformed encoding relationships fail the shell gate. Consumer parsers use bounded reads or compile-time inclusion and fail on malformed JSON or unknown fields where their JSON type owns the field set.

Each vector has exactly:

```text
id                 stable lowercase identifier
channel            worker | client | peer
direction          to-core | from-core | peer-to-peer
message            semantic message name
flags              0 plaintext | 1 encrypted
tag                 worker/client tag, or peer sender identity
key_purpose         null | worker | client | peer
payload_hex         bytes after version and tag/sender identity
plaintext_hex       version || tag/sender identity || payload
frame_hex           complete length-prefixed frame
consumers           nonempty subset of zig, rust, go-api, go-bench
```

All multibyte integers in these vectors are little-endian. Plaintext frames are:

```text
[u32 length of flags+body][flags=0][u16 version][u8 tag_or_from_id][payload]
```

Encrypted frames are:

```text
[u32 length of flags+protected body][flags=1]
[24-byte nonce][XChaCha20-Poly1305 ciphertext][16-byte authentication tag]
```

AAD is the exact serialized five-byte length-and-flags header. The peer plaintext body is `[u16 version][u8 from_id][tagged VRR payload]`.

## Canonical inventory

The corpus covers:

- worker register, heartbeat, and pod status;
- StartPod with its exact fixed header and zero environment entries;
- worker and client run requests and responses;
- leader probe request and response;
- representative tagged VRR peer envelopes;
- every legal status byte: `ok` (0), `deployment_not_found` (1), `queue_full` (2), `invalid_payload` (3), `response_too_large` (4), `outcome_ambiguous` (5), `forwarding_failed` (6), `no_running_pod` (7), `unavailable` (8), and gateway-only `not_leader` (9);
- plaintext examples for every message family;
- fixed-nonce encrypted worker, client, and peer examples.

A worker-originated status 9 remains invalid and must be rejected or disconnect the worker. Listing byte 9 in the complete global status inventory does not make it legal for the worker origin.

## Deterministic encryption material

The fixture PSK and nonce are **INSECURE TEST MATERIAL**. They exist only so each consumer can derive the purpose-specific HKDF key and reproduce exact XChaCha20-Poly1305 bytes. They are not deployment examples, production defaults, or valid nonce-generation guidance. Production keys, credentials, captured ciphertext, and reused production nonces are forbidden in this corpus.

## Consumer obligations

| Consumer | Shared-corpus behavior |
|---|---|
| Zig core | Loads the build-root-provided corpus path, decodes every applicable frame through the production frame decoder, exercises production worker parsers and leader/VRR codecs, and re-encodes applicable bytes exactly. |
| Rust worker | Includes the repository-relative corpus, uses production frame and worker codecs, decodes StartPod/run requests, and reproduces plaintext and deterministic encrypted bytes. |
| Go API | Resolves the corpus from the test source path, uses bounded fail-closed JSON/frame parsing, validates run/leader semantics, and reproduces plaintext and deterministic encrypted client bytes. |
| Go bench | Resolves the same corpus from the test source path, validates status/run/leader semantics, and reproduces all applicable plaintext client bytes. |
| Shell gate | Enforces schema, bounds, encoding relationships, complete message/status inventory, encrypted channel inventory, exact version constants, and all four consumers. |

Self-generated-only tests may remain useful local regressions, but they are not cross-language contract evidence. Shared contract claims must come from consumers of `contract-v6.json`.

## Version workflow and deployment rule

1. Change the corpus first for an incompatible byte or interpretation change.
2. Update Zig, Rust, Go API, and Go bench together, including peer codecs.
3. Bump the one global protocol version in every source constant.
4. Add positive and fail-closed negative cases as appropriate.
5. Run `cd v2/tests && ./wire-contract-test.sh` plus the broader language gates.
6. Land fixture, consumers, gate, protocol docs, and deployment rule atomically.

Mixed-version rolling upgrades are unsupported. Stop every replica, worker, API gateway, and bench client; replace all components; then restart the cluster. Version agreement is a compatibility gate, not peer authentication; TLS/mTLS remains separate work.
