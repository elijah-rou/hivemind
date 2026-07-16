# Hivemind Style Guide

Based on TigerBeetle's TIGER_STYLE, this document outlines our engineering principles and coding standards.

## Core Principles

### 1. Determinism First
- All components must be deterministically testable
- Use deterministic simulation for testing distributed behavior
- Avoid non-deterministic operations in core logic
- Time and randomness must be injected dependencies

### 2. Performance Matters
- Zero-allocation in hot paths where possible
- Minimize syscalls and context switches
- Batch operations for efficiency
- Profile before optimizing

### 3. Safety Through Simplicity
- Prefer simple, obvious code over clever abstractions
- Use Zig's compile-time features for safety guarantees
- Fail fast and explicitly
- No undefined behavior

### 4. Testing Philosophy
- Unit tests for logic correctness
- Integration tests for component interaction
- Deterministic simulation for distributed scenarios
- Fuzzing for edge cases and invariant violations
- VOPR (Verified Operations Protocol Replay) for regression testing

## Code Organization

### File Structure
```
src/
  main.zig           - Entry point
  cluster.zig        - Cluster management
  scheduler.zig      - Workload scheduling logic
  consensus.zig      - Consensus protocol implementation
  state_machine.zig  - Core state machine
  simulator.zig      - Deterministic simulator
  vopr.zig          - VOPR test harness
  *_test.zig        - Unit tests alongside implementation
```

### Module Boundaries
- Clear interfaces between modules
- Minimize cross-module dependencies
- Use dependency injection for testability
- Separate protocol logic from I/O

## Coding Standards

### Naming Conventions
- Types: PascalCase
- Functions: camelCase
- Constants: SCREAMING_SNAKE_CASE
- Variables: snake_case

### Error Handling
- Use error unions for fallible operations
- Propagate errors explicitly
- Document error conditions
- Never silently ignore errors

### Memory Management
- Prefer stack allocation
- Use arenas for request-scoped allocations
- Clear ownership semantics
- No hidden allocations

### Concurrency
- Message passing over shared state
- Explicit synchronization points
- Lock-free data structures where appropriate
- Document all race conditions

## Testing Requirements

### Coverage Goals
- 100% unit test coverage for core logic
- Simulation tests for all distributed scenarios
- Fuzzing for all parsers and state machines
- Benchmark critical paths

### Test Naming
- Test names describe behavior, not implementation
- Use "should" or "must" for assertions
- Group related tests

## Documentation

### Code Comments
- Explain "why", not "what"
- Document invariants
- Warn about non-obvious behavior
- Reference papers/RFCs for algorithms

### API Documentation
- Document all public functions
- Include examples
- Specify error conditions
- Note performance characteristics

## Performance Guidelines

### Benchmarking
- Benchmark before and after changes
- Use consistent hardware/environment
- Track performance over time
- Document benchmark methodology

### Optimization Rules
1. Make it work
2. Make it right
3. Make it fast (only if needed)

## Review Checklist

Before submitting code:
- [ ] Tests pass including simulation
- [ ] No memory leaks or undefined behavior
- [ ] Documentation updated
- [ ] Benchmarks show no regression
- [ ] Code follows style guide
- [ ] VOPR replay captures added for bugs