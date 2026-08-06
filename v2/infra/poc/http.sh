#!/usr/bin/env bash
# Shared bounded curl boundary for active POC shell callers. Source this file.

hivemind_curl() {
    local connect_timeout="${HIVEMIND_CURL_CONNECT_TIMEOUT_SEC:-5}"
    local max_time="${HIVEMIND_CURL_MAX_TIME_SEC:-30}"
    [[ "$connect_timeout" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid curl connect timeout: $connect_timeout" >&2; return 2; }
    [[ "$max_time" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid curl max time: $max_time" >&2; return 2; }
    command curl --connect-timeout "$connect_timeout" --max-time "$max_time" "$@"
}

# Existing call sites retain their response/error handling while all transport
# attempts cross the same bounded boundary. A caller's later --max-time narrows
# an operation-specific deadline without removing the connect deadline.
curl() {
    hivemind_curl "$@"
}
