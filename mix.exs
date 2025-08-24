defmodule KafkaIdleTimeoutPoc.MixProject do
  use Mix.Project

  def project do
    [
      app: :kafka_idle_timeout_poc,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      # <— must be present and match the module name
      mod: {KafkaIdleTimeoutPoc.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:kaffe, "~> 1.26"}
    ]
  end
end
