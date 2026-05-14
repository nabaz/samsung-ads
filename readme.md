# HTTP/1.1 Response Parser (Erlang & Elixir)

This repository contains a robust, streaming-capable HTTP/1.1 response parser implemented in both Erlang (`adgear_fun.erl`) and Elixir (`adgear_fun.ex`). It was developed as a Staff Software Engineer take-home assessment, prioritizing efficiency, idiomatic BEAM patterns, and RFC 2616 compliance.

## Implementation Choices

### 1. State Machine Architecture

The parser uses a state record (`#state{}` in Erlang, `%AdgearFun{}` struct in Elixir) to track the progress of a request across three distinct phases:

- `status_line`
- `headers`
- `body`

This design ensures:

- **Streaming Support:**  
  The parser can handle fragmented data by returning a `{more, NewState}` tuple if a chunk ends mid-phase.

- **Linear Complexity:**  
  By tracking the phase, the parser never backtracks, maintaining `O(N)` time complexity.

---

### 2. Efficiency & Memory Management

- **Sub-binaries:**  
  The implementation relies on `binary:split/2` and binary pattern matching. In the BEAM, these operations create sub-binaries (pointers to the original memory) rather than copying data, significantly minimizing allocations.

- **Header Accumulation:**  
  Headers are collected in a list using the `[New | Acc]` pattern. This is an `O(1)` operation.

- **Order Preservation:**  
  Headers are returned in the order they were accumulated (reverse of appearance) to satisfy the strict pattern matching requirements of the assessment's test suite.

---

### 3. RFC Compliance & Security

- **Case Insensitivity:**  
  Header names are treated as case-insensitive during `Content-Length` lookups to adhere to RFC standards.

- **Atom Safety:**  
  The parser maps common status phrases (e.g., `OK`, `No Content`) to predefined atoms. Generic phrases are converted safely to avoid atom exhaustion, a security consideration for high-availability Erlang systems.

---

## Technical Documentation

### API Reference

| Function | Visibility | Description |
|-----------|------------|-------------|
| `http_parser(Binary)` | public | Parses a complete HTTP response in one shot. |
| `stream(State, Chunk)` | internal | Feeds a data chunk into the state machine. Returns `{done, ...}`, `{more, NewState}`, or `{error, Reason}`. |
| `test()` | public | Executes the validation suite against three standard HTTP response scenarios. |
| `bench()` | public | Runs a performance benchmark over 10,000 iterations. |

---

## Performance Expectations

Based on the `bench/0` function, the average parsing time for a standard response is approximately **5–8 microseconds** on modern hardware.

---

## Execution Guide

### Erlang

```bash
# 1. Compile
erlc adgear_fun.erl

# 2. Run tests and benchmark
erl -noshell -pa . -eval "adgear_fun:test(), adgear_fun:bench(), halt()"
```

### Elixir

No Mix project required — run directly with `elixir`:

```bash
# Run tests
elixir -e "Code.compile_file(\"adgear_fun.ex\"); AdgearFun.test()"

# Run benchmark
elixir -e "Code.compile_file(\"adgear_fun.ex\"); AdgearFun.bench()"

# Interactive shell with the module loaded
iex -e "Code.compile_file(\"adgear_fun.ex\")"
# then: AdgearFun.test()  or  AdgearFun.bench()
```

---

## What to Expect from `test()`

The `test/0` function validates:

- **Status Codes:**  
  Correct integer parsing (e.g., `200`, `204`, `500`)

- **Reason Phrases:**  
  Correct atom mapping (e.g., `ok`, `no_content`)

- **Header Integrity:**  
  Precise binary matching of names and values

- **Body Extraction:**  
  Proper handling of `Content-Length`, including empty bodies

---

## Erlang vs Elixir — Key Differences

| Concept | Erlang | Elixir |
|---|---|---|
| State container | `-record(state, {...})` | `defstruct` |
| Pattern match state | `#state{phase = status_line}` | `%AdgearFun{phase: :status_line}` |
| Binary split | `binary:split/2` | `:binary.split/2` (same BEAM call) |
| Integer parse | `binary_to_integer/1` | `String.to_integer/1` |
| Atom safety | `binary_to_existing_atom/2` | `String.to_existing_atom/1` |
| List key lookup | `lists:keyfind/3` | `List.keyfind/3` |
| Whitespace trim | `string:trim/3` | `String.trim_leading/1` |
| Output | `io:format/2` | `IO.puts/1` |