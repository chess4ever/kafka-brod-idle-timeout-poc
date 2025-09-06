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
        extra_sock_opts: [keepalive: true, nodelay: true],
        auto_start_producers: true
      ] ++ kafka_client_auth
  ]

config :kaffe,
  producer: [
    client_name: :kaffe_producer_client,
    endpoints: [{host, port}],
    topics: [topic],
    partition_strategy: :md5
  ]
