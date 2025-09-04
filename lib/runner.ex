defmodule KafkaIdleTimeoutPoc.Runner do
  use GenServer
  require Logger

  @burst_size_default "50"
  @idle_secs_default "420"

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    burst_size = System.get_env("BURST_SIZE", @burst_size_default) |> String.to_integer()
    idle_secs = System.get_env("IDLE_SECS", @idle_secs_default) |> String.to_integer()
    repeats = System.get_env("REPEATS", "1") |> String.to_integer()
    topic = System.fetch_env!("CC_TOPIC")
    enable_refresher = System.get_env("ENABLE_REFRESHER", "true")

    Logger.info(
      "POC starting | burst_size=#{burst_size} idle_secs=#{idle_secs} repeats=#{repeats} enable_refresher=#{enable_refresher}"
    )

    send(self(), :do_burst)

    {:ok,
     %{topic: topic, burst_size: burst_size, idle_secs: idle_secs, repeats: repeats, round: 0}}
  end

  def handle_info(:do_burst, %{topic: topic, burst_size: n, round: r} = st) do
    round = r + 1
    Logger.info("Burst ##{round} starting (#{n} messages)")

    for i <- 1..n do
      key = "round-#{round}-msg-#{i}"
      payload = "#{DateTime.utc_now() |> DateTime.to_iso8601()} | payload #{i}"
      Logger.info("produce_sync -> key=#{key}")

      case Kaffe.Producer.produce_sync(topic, key, payload) do
        :ok ->
          Logger.info("produce_sync OK <- key=#{key}")

        {:error, reason} ->
          Logger.error("produce_sync ERROR <- key=#{key} reason=#{inspect(reason)}")
      end
    end

    Logger.info("Burst ##{round} complete. Idling for #{st.idle_secs}s...")
    Process.send_after(self(), :after_idle, st.idle_secs * 1000)
    {:noreply, %{st | round: round}}
  end

  def handle_info(:after_idle, %{topic: topic, round: round, repeats: repeats} = st) do
    Logger.info("Idle finished; probing ALL partitions…")

    Task.start(fn ->
      client = Kaffe.Config.Producer.configuration().client_name

      # Ask brod how many partitions the topic has
      {:ok, parts} = :brod_client.get_partitions_count(client, topic)

      for p <- 0..(parts - 1) do
        key = "probe-p#{p}-r#{round}"
        payload = "#{DateTime.utc_now() |> DateTime.to_iso8601()} | probe p=#{p} r=#{round}"

        Logger.info("sending probe to partition=#{p} key=#{key}")

        t0 = System.monotonic_time(:millisecond)

        # 👇 target a specific partition
        res = Kaffe.Producer.produce_sync(topic, p, key, payload)

        dt = System.monotonic_time(:millisecond) - t0
        Logger.info("probe partition=#{p} key=#{key} result=#{inspect(res)} elapsed_ms=#{dt}")
      end
    end)

    if round < repeats do
      Process.send_after(self(), :do_burst, 5_000)
    else
      Logger.info("POC done. Press Ctrl+C to exit.")
    end

    {:noreply, st}
  end
end
