import Config

config :logger, :console,
  format: "time=$time level=$level [$metadata] $message\n",
  metadata: [:module, :function, :line]

config :logger, level: :info
