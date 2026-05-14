defmodule AdgearFun do
  @moduledoc """
  HTTP/1.x response parser — Elixir port of adgear_fun.erl.

  Parses a raw HTTP/1.x response binary into a 4-tuple:
    {status_code, reason_atom, headers, body}

  Design goals:
  - Single-pass, O(N) — the parser never backtracks.
  - Streaming-capable via an internal State struct that tracks the current
    parse phase (:status_line → :headers → :body).
  - No atom-table exhaustion: unknown reason phrases use
    String.to_existing_atom/1 and raise on unknown values.
  - Headers are returned in reverse wire order (last header first), matching
    the assignment's test fixture exactly — a natural consequence of prepend
    accumulation that avoids an extra list reversal pass.
  - Content-Length lookup is ASCII case-folded without relying on
    library behaviour that may differ across OTP/Elixir versions.
  """

  # ---------------------------------------------------------------------------
  # Test fixtures (mirrors the Erlang macros)
  # ---------------------------------------------------------------------------

  @resp1 (
    "HTTP/1.1 200 OK\r\n" <>
    "Server: AdGear\r\n" <>
    "Content-Length: 12\r\n" <>
    "Date: Wed, 21 Dec 2016 18:29:13 GMT\r\n" <>
    "Connection: close\r\n\r\nhello world!"
  )

  @resp2 (
    "HTTP/1.1 204 No Content\r\n" <>
    "server: AdGear\r\n" <>
    "date: Wed, 15 Feb 2017 01:47:43 GMT\r\n" <>
    "content-length: 0\r\n" <>
    "Connection: Keep-Alive\r\n\r\n"
  )

  @resp3 (
    "HTTP/1.1 500 Internal Server Error\r\n" <>
    "Server: AdGear\r\n" <>
    "Date: Fri, 03 Jun 2016 14:34:26 GMT\r\n" <>
    "Content-Length: 0\r\n\r\n"
  )

  # ---------------------------------------------------------------------------
  # Internal state
  # ---------------------------------------------------------------------------

  defstruct phase: :status_line,
            buf: <<>>,
            status: nil,
            reason: nil,
            headers: [],
            clen: nil

  @type t()       :: %AdgearFun{}
  @type status()  :: pos_integer()
  @type reason()  :: atom()
  @type headers() :: [{binary(), binary()}]
  @type body()    :: binary()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse a complete HTTP/1.x response binary.

  Returns `{status, reason, headers, body}` or raises on malformed / incomplete input.
  """
  @spec http_parser(binary()) :: {status(), reason(), headers(), body()}
  def http_parser(bin) do
    case stream(%AdgearFun{}, bin) do
      {:done, status, reason, headers, body} -> {status, reason, headers, body}
      {:more, _state}  -> raise ArgumentError, "parse_error: incomplete_response"
      {:error, reason} -> raise ArgumentError, "parse_error: #{reason}"
    end
  end

  @doc """
  Run `http_parser/1` 10 000 times on RESP1 and print the average microseconds.
  Uses integer division to keep the result in whole microseconds.
  """
  def bench do
    n = 10_000

    total =
      Enum.reduce(1..n, 0, fn _, acc ->
        {time, _} = :timer.tc(fn -> http_parser(@resp1) end)
        acc + time
      end)

    IO.puts("average parsing time: #{div(total, n)} us")
  end

  @doc """
  Smoke-tests all three canned responses. Raises (MatchError) on any mismatch.
  """
  def test do
    # Headers come back in reverse wire order — last header in the response
    # is first in the list — because they are prepended during accumulation.
    # This matches the original assignment's test/0 fixture exactly.
    {200, :ok,
     [
       {"Connection", "close"},
       {"Date", "Wed, 21 Dec 2016 18:29:13 GMT"},
       {"Content-Length", "12"},
       {"Server", "AdGear"}
     ], "hello world!"} = http_parser(@resp1)

    {204, :no_content,
     [
       {"Connection", "Keep-Alive"},
       {"content-length", "0"},
       {"date", "Wed, 15 Feb 2017 01:47:43 GMT"},
       {"server", "AdGear"}
     ], ""} = http_parser(@resp2)

    {500, :internal_server_error,
     [
       {"Content-Length", "0"},
       {"Date", "Fri, 03 Jun 2016 14:34:26 GMT"},
       {"Server", "AdGear"}
     ], ""} = http_parser(@resp3)

    IO.puts("All tests passed!")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Streaming engine
  # ---------------------------------------------------------------------------

  # Append the new chunk to the internal buffer and re-dispatch.
  # Using binary concatenation here is fine for typical HTTP response sizes;
  # for very high-throughput streaming an iolist accumulator would reduce
  # allocations at the cost of some complexity.
  @spec stream(t(), binary()) ::
    {:done, status(), reason(), headers(), body()} | {:more, t()} | {:error, term()}
  defp stream(%AdgearFun{buf: existing} = state, chunk) do
    dispatch(%{state | buf: existing <> chunk})
  end

  defp dispatch(%AdgearFun{phase: :status_line} = s), do: parse_status_line(s)
  defp dispatch(%AdgearFun{phase: :headers}     = s), do: parse_headers(s)
  defp dispatch(%AdgearFun{phase: :body}        = s), do: parse_body(s)

  # ---------------------------------------------------------------------------
  # Phase 1 — Status line  "HTTP/1.1 200 OK\r\n"
  # ---------------------------------------------------------------------------

  defp parse_status_line(%AdgearFun{buf: buf} = s) do
    case :binary.split(buf, "\r\n") do
      [line, rest] ->
        case parse_status_line_bin(line) do
          {:ok, status, reason} ->
            dispatch(%{s | phase: :headers, buf: rest, status: status, reason: reason})
          err ->
            err
        end

      [_] ->
        {:more, s}
    end
  end

  # Match "HTTP/1.x " — _minor captures exactly one byte (the minor version digit).
  defp parse_status_line_bin(<<"HTTP/1.", _minor, " ", rest::binary>>) do
    case rest do
      # Status code is always exactly 3 ASCII digits followed by a space.
      <<code::binary-size(3), " ", phrase::binary>> ->
        {:ok, String.to_integer(code), phrase_to_atom(phrase)}
      _ ->
        {:error, :malformed_status_line}
    end
  end

  defp parse_status_line_bin(_), do: {:error, :unsupported_protocol}

  # ---------------------------------------------------------------------------
  # Phase 2 — Headers  "Key: Value\r\n" … "\r\n"
  # ---------------------------------------------------------------------------

  defp parse_headers(%AdgearFun{buf: buf, headers: acc} = s) do
    case :binary.split(buf, "\r\n") do
      # An empty line signals the end of the header section (RFC 7230 §3.5).
      [<<>>, rest] ->
        clen = content_length(acc)
        dispatch(%{s | phase: :body, buf: rest, clen: clen})

      [line, rest] ->
        case parse_header_line(line) do
          # Prepend for O(1) accumulation; caller receives reverse-wire order.
          {:ok, kv} -> parse_headers(%{s | buf: rest, headers: [kv | acc]})
          err       -> err
        end

      [_] ->
        {:more, s}
    end
  end

  # RFC 7230 §3.2.6: optional whitespace (SP / HTAB) is allowed after the colon.
  # We split on the first colon only so header values that contain colons
  # (e.g. Date values) are preserved intact.
  # String.trim_leading/1 (no second argument) trims all leading Unicode
  # whitespace, which covers both SP and HTAB correctly.
  defp parse_header_line(line) do
    case :binary.split(line, ":") do
      [k, v] -> {:ok, {k, String.trim_leading(v)}}
      _      -> {:error, :malformed_header}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3 — Body
  # ---------------------------------------------------------------------------

  defp parse_body(%AdgearFun{buf: buf, clen: clen, status: st, reason: re, headers: hd} = s) do
    # Headers remain in the prepend-accumulated (reverse wire) order — no extra
    # reversal pass needed because the assignment fixture expects this ordering.
    case clen do
      0   -> {:done, st, re, hd, ""}
      nil -> {:done, st, re, hd, buf}
      n when byte_size(buf) >= n ->
        <<body::binary-size(n), _::binary>> = buf
        {:done, st, re, hd, body}
      _   -> {:more, s}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # ASCII-only case fold for header key lookup.
  # We deliberately avoid String.downcase/1 here because it is Unicode-aware
  # and performs additional allocations; HTTP header names are always ASCII.
  defp ascii_downcase(bin) do
    for <<c <- bin>>, into: <<>> do
      if c >= ?A and c <= ?Z, do: <<c + 32>>, else: <<c>>
    end
  end

  # Locate Content-Length using a case-insensitive key comparison.
  # The value is trimmed before integer parsing to guard against any stray
  # leading/trailing whitespace that survived the header-line parser.
  defp content_length(headers) do
    lookup = Enum.map(headers, fn {k, v} -> {ascii_downcase(k), v} end)

    case List.keyfind(lookup, "content-length", 0) do
      {_, val} -> val |> String.trim() |> String.to_integer()
      nil      -> nil
    end
  end

  # Known reason phrases are hardcoded to avoid atom-table exhaustion (DoS).
  # The fallback uses String.to_existing_atom/1: if the normalised phrase has
  # never been defined as an atom the call raises ArgumentError, which is safe
  # because no new atoms are created from untrusted input.
  defp phrase_to_atom("OK"),                    do: :ok
  defp phrase_to_atom("No Content"),            do: :no_content
  defp phrase_to_atom("Internal Server Error"), do: :internal_server_error
  defp phrase_to_atom(phrase) do
    phrase
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.to_existing_atom()
  end
end
