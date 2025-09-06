defmodule KafkaIdleTimeoutPoc.ConnectionRefresher do
  @moduledoc """
  Periodically pings Kafka metadata to keep connection alive.
  """

  use GenServer
  require Logger

  @interval 10_000

  def start_link(_opts) do
    client_name = Kaffe.Config.Producer.configuration().client_name
    topic = hd(Kaffe.Config.Producer.configuration().topics)
    GenServer.start_link(__MODULE__, %{client_name: client_name, topic: topic}, name: __MODULE__)
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :refresh_connection}}

  @impl true
  def handle_continue(:refresh_connection, state) do
    refresh_connection(state)
    {:noreply, state, @interval}
  end

  @impl true
  def handle_info(:timeout, state) do
    refresh_connection(state)
    {:noreply, state, @interval}
  end

  defp refresh_connection(%{client_name: client_name, topic: topic}) do
    Logger.debug("Refreshing Kafka connection for #{topic}")

    case :brod_client.get_metadata_safe(client_name, topic) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Failed to refresh Kafka connection", reason: reason)
    end
  end
end
