defmodule DelegatedSpend.Evm.Artifacts do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  Load Foundry build artifacts (`abi` + `bytecode.object`) for the contracts the
  chain layer deploys/calls. Reads `contracts/out/<File>.sol/<Contract>.json`
  (produced by `forge build`).

  Raises loudly if an artifact is missing or its bytecode is empty — that means
  `forge build` was not run, and a silent empty-bytecode deploy would brick a market.
  """

  # repo-root/contracts/out — this file lives at objects/evm/artifacts.ex
  @default_out Path.expand(Path.join([__DIR__, "..", "..", "..", "contracts", "out"]))

  @specs %{
    token: {"MockERC20Permit.sol", "MockERC20Permit"},
    echo: {"EchoSpendRouter.sol", "EchoSpendRouter"}
  }

  @doc "Load all artifacts into `%{usdc: %{abi, bytecode}, vault: …, …}`."
  def load_all(out_dir \\ @default_out) do
    for {key, {file, contract}} <- @specs, into: %{} do
      {key, load_one(out_dir, file, contract)}
    end
  end

  defp load_one(out_dir, file, contract) do
    path = Path.join([out_dir, file, contract <> ".json"])

    data =
      case File.read(path) do
        {:ok, json} ->
          Jason.decode!(json)

        {:error, r} ->
          raise "missing artifact #{path} (#{inspect(r)}) — run `cd contracts && forge build`"
      end

    bytecode = get_in(data, ["bytecode", "object"]) || ""

    if bytecode == "" or not String.starts_with?(bytecode, "0x") do
      raise "empty/invalid bytecode for #{contract} at #{path} — run `forge build`"
    end

    %{abi: data["abi"], bytecode: bytecode}
  end
end
