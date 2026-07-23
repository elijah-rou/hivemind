# Shared wire fixture contract

> **Current limitation:** Hivemind uses protocol version 6 for client, worker, API, bench, and replica peer envelopes. Zig socketpair tests cover peer version rejection, but all languages still have only language-local protocol tests; no shared normative fixture corpus or shared contract gate exists. Everything below marked planned is not runnable today.

The behavioral protocol remains defined by [the control-plane contract](../../docs/design/CONTROL_PLANE_CONTRACT.md). Current constants and codecs remain source-owned by [`core/src/connection.zig`](../../core/src/connection.zig), [`worker/src/protocol.rs`](../../worker/src/protocol.rs), [`api/client.go`](../../api/client.go), and [`bench/main.go`](../../bench/main.go).

## Current versus planned evidence

| Fixture type | Meaning | Gate effect |
|---|---|---|
| Normative | One shared record specifies exact frame bytes, lengths, flags, version, tag, payload, and expected decode/re-encode result | Every applicable consumer must read the same record and reproduce or reject it exactly |
| Illustrative | Prose, a partial decoded structure, or a language-local test explains behavior | Useful for review, but cannot satisfy the shared wire gate |
| Current language-local | A consumer generates and checks its own bytes | Tests that consumer only; agreement can still drift |

There are no normative shared fixtures today. Existing “golden” values in language-local tests remain illustrative across language boundaries until all consumers load one committed corpus.

## Planned, not implemented: corpus schema

The eventual JSON corpus must be bounded and schema-validated. The planned `contract-v6.json` does not exist yet; protocol version 6 is current but does not have a shared normative corpus. Each record needs these fields:

```text
corpus_version
protocol_version
vectors[]
  id
  direction
  consumer_set[]
  envelope
    flags
    version
    tag
    declared_length
  payload_hex
  frame_hex
  encryption
    enabled
    test_key_id
    nonce_hex
    aad_hex
  expected
    decode
    message_type
    status
    error_class
```

Schema rules:

- All multibyte integers declare byte order. Current client/worker framing and numeric payload fields use little-endian encoding unless the active protocol contract says otherwise.
- Hex is lowercase, contains no separators or prefix, and has even length. Empty bytes use the empty string.
- Vector IDs are stable, unique, lowercase identifiers. An existing ID never silently changes meaning; incompatible meaning requires a new ID.
- `declared_length`, `payload_hex`, and `frame_hex` must agree exactly. Consumers never clamp, truncate, or ignore trailing bytes.
- `consumer_set` explicitly names every applicable consumer. A vector cannot silently be skipped by an applicable implementation.
- Expected failures use stable error classes such as `unknown_flags`, `short_frame`, `length_mismatch`, `oversize`, `unsupported_version`, `unknown_tag`, `invalid_status`, or `authentication_failed`, not language-specific error strings.
- Boundary vectors include empty payloads and exact active maxima where the message permits them. Follow source links above for mutable limits.
- Peer vectors must include the version before sender identity and prove old-version rejection occurs before identity binding or VRR dispatch.

## Deterministic encryption policy

Normative encrypted vectors may use fixed keys and nonces only to make exact bytes reproducible.

- Label every key and nonce as **insecure test material**.
- Use a dedicated test-key identifier; never show fixture material as deployment configuration.
- Record the exact key reference, nonce, authenticated header/AAD, plaintext, ciphertext, and authentication tag inputs.
- For the current envelope, AAD must be the exact serialized frame header used by the codec, not a reconstructed semantic value.
- A test key and nonce pair is deterministic corpus input, never a secrecy or nonce-generation example.
- Production keys, credentials, tokens, and captured production ciphertext are forbidden in the corpus.

## Planned required inventory

| Area | Required normative vectors |
|---|---|
| Envelope | Minimum plaintext and encrypted frames; empty and exact-maximum payloads; flags, declared length, version, and tag boundaries |
| Worker registration | node register and register acknowledgement |
| Worker liveness | heartbeat and pod-status events for each legal phase/status representation |
| Lifecycle control | StartPod, StopPod, and ProbePod, including fixed strings, environment entries, optional registry-auth trailer, and exact-length rules |
| Request data plane | run request and run response with empty, typical, and exact-boundary bodies |
| Leader discovery | leader probe request and response/reply framing used by API and bench clients |
| Run statuses | legal bytes `0` through `9`, with names and origin restrictions from [ENGINEERING.md](../../docs/ENGINEERING.md) |
| Peer traffic | representative version-6 peer envelopes, VRR messages, current-1 rejection, malformed input, plaintext, and deterministic encrypted examples |
| Encryption | byte-identical plaintext/encrypted examples plus deterministic authentication failures |

The legal run-status inventory is `ok` (0), `deployment_not_found` (1), `queue_full` (2), `invalid_payload` (3), `response_too_large` (4), `outcome_ambiguous` (5), `forwarding_failed` (6), `no_running_pod` (7), `unavailable` (8), and gateway-only `not_leader` (9). A worker-originated status 9 is invalid and must disconnect/reject that worker rather than becoming a normal response.

## Planned malformed and version cases

Every applicable decoder must fail closed for:

- empty, truncated, overflowed, mismatched, trailing-byte, and oversized declarations;
- unknown flags, tags, enum values, boolean encodings, GPU types, phases, and status bytes;
- plaintext when a key is required and encrypted frames when no key is configured;
- altered nonce, AAD, ciphertext, or authentication tag;
- old protocol versions and future protocol versions;
- current-version peer envelopes, including rejection before identity binding or VRR dispatch.

Old/future-version failures occur before identity binding, dispatch, state mutation, or request execution. Malformed inputs must not be “normalized” into valid values. Corpus cases should distinguish incomplete streaming input from a complete invalid frame where that distinction is observable.

## Consumer matrix

| Consumer | Current state | Planned normative obligation |
|---|---|---|
| Zig core | Self-generated client/worker frame tests plus peer-envelope socketpair tests in [`connection.zig`](../../core/src/connection.zig); peer serialization in [`replica.zig`](../../core/src/replica.zig) | Load applicable shared vectors, decode them, re-encode successful cases byte-identically, and reject every negative case |
| Rust worker | Self-generated frame/payload tests in [`protocol.rs`](../../worker/src/protocol.rs) | Same for worker directions and shared envelope cases |
| Go API | Self-generated client tests in [`client_test.go`](../../api/client_test.go) | Same for API client, leader, reply, and run-response cases |
| Go bench | Self-generated tests under [`bench/`](../../bench/) | Same for probe, reply, and request cases |
| Shared contract gate | Absent | Validate schema and uniqueness, run every consumer, and prove exact global version agreement |

No executable contract-gate command is documented because no such gate exists. Its eventual location and invocation must be added only in the implementation commit that creates it.

## Atomic vector and version workflow

1. Specify the byte or interpretation change and identify every affected direction and consumer.
2. Add or update the normative vectors first so the intended contract is reviewable.
3. Update Zig, Rust, Go API, and Go bench together, including peer codecs when applicable.
4. Bump the one global envelope version whenever bytes or interpretation become incompatible. Do not bump for prose-only clarification.
5. Make every consumer read the same corpus and re-encode successful applicable vectors byte-identically.
6. Add malformed, old-version, and future-version rejection vectors and prove rejection occurs before side effects.
7. Land fixture, schema/gate, all consumers, design documentation, and this README atomically. A partial version change must not merge.
8. Record the deployment rule and evidence for the new version.

Hivemind does not support mixed-version rolling upgrades. Stop all replicas, workers, API gateways, and bench clients; replace every consumer; then restart the cluster. Do not advertise compatibility with an old or future peer until the normative corpus and implementation prove it.
