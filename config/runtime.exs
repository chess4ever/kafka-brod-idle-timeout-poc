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

config :brod,
  clients: [
    kaffe_producer_client:
      [
        endpoints: [{host, port}],
        auto_start_producers: true,
        request_timeout: 60_000,
        default_producer_config: [
          required_acks: -1,
          max_retries: 30,
          retry_backoff_ms: 1000,
          ack_timeout: 10_000
        ],
        extra_sock_opts: [
          {:keepalive, true},
          {:nodelay, true},
          # keepalive timers (unsigned 32-bit, native endian)
          # TCP_KEEPIDLE = 37s
          {:raw, 6, 4, <<37::unsigned-native-32>>},
          # TCP_KEEPINTVL = 9s
          {:raw, 6, 5, <<9::unsigned-native-32>>},
          # TCP_KEEPCNT   = 3
          {:raw, 6, 6, <<3::unsigned-native-32>>},
          # optional but helpful against blackholes (in ms)
          # TCP_USER_TIMEOUT = 20s
          {:raw, 6, 18, <<20_000::unsigned-native-32>>}
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
