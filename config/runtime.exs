import Config

host =
  System.fetch_env!("CC_BOOTSTRAP_HOST")
  |> String.to_charlist()

port =
  System.get_env("KAFKA_CLUSTER_PORT", "9092")
  |> String.to_integer()

topic = System.fetch_env!("CC_TOPIC")

api_key = System.get_env("CC_API_KEY", "")
api_secret = System.get_env("CC_API_SECRET", "")

kafka_client_auth =
  if api_key != "" and api_secret != "" do
    [
      ssl: true,
      # IMPORTANT: tuple, not map
      sasl: {:plain, api_key, api_secret}
    ]
  else
    []
  end

if System.get_env("BROD_DEBUG", "0") == "1" do
  config :logger, level: :debug
end

# -------- Brod client with per-socket KA tuning (Linux) --------
# IPPROTO_TCP = 6
# TCP_KEEPIDLE = 4 (seconds before first probe)
# TCP_KEEPINTVL = 5 (seconds between probes)
# TCP_KEEPCNT = 6 (failed probes before close)
# TCP_USER_TIMEOUT = 18 (ms to give up on unacked data)

config :brod,
  clients: [
    kaffe_producer_client:
      [
        endpoints: [{host, port}],
        auto_start_producers: true,
        extra_sock_opts: [
          {:keepalive, true},
          {:nodelay, true},
          # keepalive timers (unsigned 32-bit, native endian)
          {:raw, 6, 4,  <<37::unsigned-native-32>>},   # TCP_KEEPIDLE = 37s
          {:raw, 6, 5,  <<9::unsigned-native-32>>},    # TCP_KEEPINTVL = 9s
          {:raw, 6, 6,  <<3::unsigned-native-32>>},    # TCP_KEEPCNT   = 3
          # optional but helpful against blackholes (in ms)
          {:raw, 6, 18, <<20_000::unsigned-native-32>>}# TCP_USER_TIMEOUT = 20s
        ]
      ] ++ kafka_client_auth
  ]

config :kaffe,
  producer: [
    client_name: :kaffe_producer_client,
    endpoints: [{host, port}],
    topics: [topic],
    partition_strategy: :md5
  ]
