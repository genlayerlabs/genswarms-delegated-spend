defmodule DelegatedSpend.Keccak do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  Pure-Elixir **Keccak-256** (the Ethereum hash) — no NIF, no subprocess, no native
  artifact to match the container's libc/arch. Replaces the `ex_keccak` Rust NIF in
  the spirit of the genswarms framework (lean on the BEAM / std libs, like it leans on
  `curl` over a heavy HTTP dep).

  Keccak-256 is **NOT** SHA3-256: same Keccak-f[1600] permutation, but the original
  Keccak padding (`0x01 … 0x80`) instead of SHA3's (`0x06 … 0x80`). Rate 1088 bits
  (136 bytes), capacity 512, 24 rounds. Verified byte-for-byte against `ex_keccak`
  and the published `keccak256('')`/`Transfer(...)` vectors (`tests/chain/evm_signing.exs`).

  `hash_256/1` is a drop-in for `ExKeccak.hash_256/1` (binary → 32 raw bytes), so it
  also slots in as `ex_abi`'s pluggable keccak for function-selector hashing.
  """
  import Bitwise

  @mask 0xFFFFFFFFFFFFFFFF
  @rate 136

  # Rotation offsets r[x][y], flattened by lane index L(x,y) = x + 5*y.
  @rotc {0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56,
         14}

  # Keccak-f[1600] round constants.
  @rc {
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008
  }

  @doc "Keccak-256 of a binary → 32 raw bytes."
  @spec hash_256(binary) :: <<_::256>>
  def hash_256(data) when is_binary(data) do
    state = absorb(pad(data), Tuple.duplicate(0, 25))
    for(i <- 0..3, into: <<>>, do: <<elem(state, i)::little-unsigned-64>>)
  end

  # pad10*1 with the Keccak domain (first pad byte 0x01, last byte | 0x80).
  defp pad(data) do
    case @rate - rem(byte_size(data), @rate) do
      1 -> data <> <<0x81>>
      n -> data <> <<0x01>> <> :binary.copy(<<0>>, n - 2) <> <<0x80>>
    end
  end

  defp absorb(<<>>, state), do: state

  defp absorb(<<block::binary-size(@rate), rest::binary>>, state),
    do: absorb(rest, keccak_f(xor_block(state, block, 0)))

  defp xor_block(state, <<>>, _i), do: state

  defp xor_block(state, <<lane::little-unsigned-64, rest::binary>>, i),
    do: xor_block(put_elem(state, i, bxor(elem(state, i), lane)), rest, i + 1)

  defp keccak_f(state), do: Enum.reduce(0..23, state, &round_fn(&2, &1))

  defp round_fn(a, rnd), do: a |> theta() |> rho_pi() |> chi() |> iota(rnd)

  defp theta(a) do
    c = for x <- 0..4, do: bxor5(a, x)
    d = for x <- 0..4, do: bxor(Enum.at(c, rem(x + 4, 5)), rotl(Enum.at(c, rem(x + 1, 5)), 1))
    d = List.to_tuple(d)

    Enum.reduce(0..24, a, fn i, acc ->
      put_elem(acc, i, bxor(elem(acc, i), elem(d, rem(i, 5))))
    end)
  end

  defp bxor5(a, x),
    do: Enum.reduce(0..4, 0, fn y, acc -> bxor(acc, elem(a, x + 5 * y)) end)

  defp rho_pi(a) do
    Enum.reduce(0..24, Tuple.duplicate(0, 25), fn i, b ->
      x = rem(i, 5)
      y = div(i, 5)
      dst = y + 5 * rem(2 * x + 3 * y, 5)
      put_elem(b, dst, rotl(elem(a, i), elem(@rotc, i)))
    end)
  end

  defp chi(b) do
    Enum.reduce(0..24, b, fn i, acc ->
      x = rem(i, 5)
      y = div(i, 5)
      b1 = elem(b, rem(x + 1, 5) + 5 * y)
      b2 = elem(b, rem(x + 2, 5) + 5 * y)
      put_elem(acc, i, bxor(elem(b, i), band(bxor(b1, @mask), b2)))
    end)
  end

  defp iota(a, rnd), do: put_elem(a, 0, bxor(elem(a, 0), elem(@rc, rnd)))

  defp rotl(v, 0), do: v
  defp rotl(v, n), do: (v <<< n ||| v >>> (64 - n)) &&& @mask
end
