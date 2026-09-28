defmodule JidoSwarm.LLM.HealthTest do
  use ExUnit.Case, async: false

  alias JidoSwarm.LLM.Health

  test "readiness is a memory read that follows the last probe" do
    # Anthropic's readiness is a matter of configuration, so it is a probe
    # whose answer this test controls without a network.
    System.delete_env("ANTHROPIC_API_KEY")
    :ok = Health.refresh()
    refute Health.ready?(JidoSwarm.LLM.Anthropic)
    assert is_integer(Health.probed_at(JidoSwarm.LLM.Anthropic))

    System.put_env("ANTHROPIC_API_KEY", "sk-test")
    :ok = Health.refresh()
    assert Health.ready?(JidoSwarm.LLM.Anthropic)
  after
    System.delete_env("ANTHROPIC_API_KEY")
    Health.refresh()
  end

  test "the console reads providers without touching the network" do
    {us, providers} = :timer.tc(fn -> JidoSwarm.LLM.providers() end)
    assert Enum.map(providers, & &1.name) == ["Ollama", "Anthropic"]
    # Well under the five seconds an unreachable Ollama used to cost.
    assert us < 100_000
  end
end
