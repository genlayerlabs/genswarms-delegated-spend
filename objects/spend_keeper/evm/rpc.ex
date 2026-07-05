defmodule DelegatedSpend.Evm.Rpc do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  Ethereum JSON-RPC transport over `curl` + `System.cmd` — NOT `:httpc`, which is
  unusable in this OTP build (same reason `tg_ingress` shells out to curl).

  `call/3` returns `{:ok, result}` | `{:error, reason}`; `call!/3` raises. Typed
  wrappers (`chain_id`, `gas_price`, `nonce`, `eth_call`, `send_raw`, `receipt`,
  `get_logs`, `block_timestamp`, `estimate_gas`) cover everything the chain layer
  needs. No business logic lives here.
  """

  @timeout_s "120"

  def call(rpc_url, method, params) do
    body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})

    args = [
      "-s",
      "--max-time",
      @timeout_s,
      "-X",
      "POST",
      rpc_url,
      "-H",
      "Content-Type: application/json",
      "-d",
      body
    ]

    case System.cmd(curl_bin(), args, stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => err}} -> {:error, {:rpc_error, method, err}}
          _ -> {:error, {:bad_rpc_response, method, String.slice(out, 0, 200)}}
        end

      {err, code} ->
        {:error, {:curl_failed, code, String.slice(err, 0, 200)}}
    end
  end

  def call!(rpc_url, method, params) do
    case call(rpc_url, method, params) do
      {:ok, result} -> result
      {:error, reason} -> raise "rpc #{method} failed: #{inspect(reason)}"
    end
  end

  # ── typed helpers ─────────────────────────────────────────────────────────────
  def chain_id(rpc), do: call!(rpc, "eth_chainId", []) |> hex_to_int()
  def gas_price(rpc), do: call!(rpc, "eth_gasPrice", []) |> hex_to_int()

  def nonce(rpc, addr),
    do: call!(rpc, "eth_getTransactionCount", [addr, "pending"]) |> hex_to_int()

  def block_timestamp(rpc) do
    call!(rpc, "eth_getBlockByNumber", ["latest", false])["timestamp"] |> hex_to_int()
  end

  def block_number(rpc), do: call!(rpc, "eth_blockNumber", []) |> hex_to_int()

  @doc "eth_getBalance — native balance (wei) of `addr`. Used by the health monitor's gas check."
  def balance(rpc, addr), do: call!(rpc, "eth_getBalance", [addr, "latest"]) |> hex_to_int()

  @doc "eth_estimateGas — returns `{:ok, gas_int}` | `{:error, _}` (can revert)."
  def estimate_gas(rpc, tx) do
    case call(rpc, "eth_estimateGas", [tx]) do
      {:ok, hex} -> {:ok, hex_to_int(hex)}
      other -> other
    end
  end

  @doc "eth_call a view function; `data` is `0x…` calldata. Returns raw 0x-hex result."
  def eth_call(rpc, to, data), do: call!(rpc, "eth_call", [%{to: to, data: data}, "latest"])

  def code(rpc, addr), do: call!(rpc, "eth_getCode", [addr, "latest"])

  def send_raw(rpc, raw_hex), do: call(rpc, "eth_sendRawTransaction", [raw_hex])

  @doc "eth_getTransactionReceipt — returns the receipt map, or `nil` if not yet mined."
  def receipt(rpc, hash), do: call!(rpc, "eth_getTransactionReceipt", [hash])

  def get_logs(rpc, filter), do: call!(rpc, "eth_getLogs", [filter])

  # ── hex ───────────────────────────────────────────────────────────────────────
  def hex_to_int("0x"), do: 0
  def hex_to_int("0x" <> h), do: String.to_integer(h, 16)
  def hex_to_int(int) when is_integer(int), do: int

  defp curl_bin, do: System.find_executable("curl") || "/run/current-system/sw/bin/curl"

  @doc "eth_call with an explicit `from` — the simulation gate needs the real sender."
  def eth_call_from(rpc, from, to, data),
    do: call(rpc, "eth_call", [%{from: from, to: to, data: data}, "latest"])

  @doc "Current suggested priority fee (wei)."
  def max_priority_fee(rpc), do: call!(rpc, "eth_maxPriorityFeePerGas", []) |> hex_to_int()

  @doc "Latest block base fee (wei)."
  def base_fee(rpc) do
    %{"baseFeePerGas" => hex} = call!(rpc, "eth_getBlockByNumber", ["latest", false])
    hex_to_int(hex)
  end
end
