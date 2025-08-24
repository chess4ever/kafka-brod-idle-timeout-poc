defmodule KafkaIdleTimeoutPoc.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("App starting…")

    children =
      case System.get_env("ENABLE_REFRESHER", "true") do
        "false" -> [KafkaIdleTimeoutPoc.Runner]
        _ -> [KafkaIdleTimeoutPoc.ConnectionRefresher, KafkaIdleTimeoutPoc.Runner]
      end

    opts = [strategy: :one_for_one, name: KafkaIdleTimeoutPoc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
