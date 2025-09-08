# Kafka Idle Timeout PoC (Elixir + Kaffe)

This project is a minimal proof-of-concept to reproduce and analyze the
idle connection timeout behavior of Kafka producers using Elixir and Kaffe.

It simulates:

1. Sending a burst of messages.
2. Going idle for a configurable time (to let TCP/LB idle timers expire).
3. Sending probe messages (one per partition, discovered automatically) to trigger potential
   :request_timeout and observe reconnection behavior.

I have also committed an example [log](https://github.com/chess4ever/kafka-brod-idle-timeout-poc/blob/main/logs.txt) of one of my trials (stopped after the ack for partition 1).

## Getting Started

### Prerequisites

- Erlang/OTP 26+ and Elixir 1.15+ (There is a devcontainer setup to speed up things)
- A Kafka cluster (tested with the basic free plan of Confluent Cloud)
- A topic created in the cluster (tested with 2 partitions)

Note: The POC with this setup has been tested also through a Github Codespace, in the hope to remove the "works on my machine" issue.

### Setup

Clone the repo and install dependencies:

```
mix deps.get
```

Copy the provided example env file and fill it with your cluster details:

```
cp .env.example .env
# edit .env with your bootstrap host, API key/secret, and topic
```

Export all variables:

```
set -a; source .env; set +a
```

Run the POC:

```
mix run --no-halt
```

or

```
iex -S mix
```

## Environment Variables

See `.env.example` for all available options:

- CC_BOOTSTRAP_HOST – Kafka bootstrap server hostname (e.g. pkc-xxxxx.us-east-1.aws.confluent.cloud)
- KAFKA_CLUSTER_PORT – Kafka bootstrap port (default 9092)
- CC_API_KEY – Confluent Cloud API key
- CC_API_SECRET – Confluent Cloud API secret
- CC_TOPIC – Topic to produce into (must exist)

POC behavior toggles:

- BURST_SIZE – Number of messages in initial burst (default 50)
- IDLE_SECS – Idle period before probes (default 420)
- REPEATS – How many burst+idle+probe cycles (default 1)
- ENABLE_REFRESHER – true/false, run a background metadata refresher (default true)

Debugging:

- BROD_DEBUG – 1 enables very verbose brod logs

## What to Expect

- During the burst: you’ll see `produce_sync OK` logs for each message.
- After the idle: you’ll see `SENDING probe …` lines for each discovered partition.

  - If connections went stale, you may see:

    1. `payload connection down … reason::request_timeout`
    2. `Failed to (re)init connection …`
    3. `client :kaffe_producer_client connected …`
  - When reconnected, probes return with `:ok` and `elapsed_ms` showing how long they were blocked.

This mirrors the issue seen in production when Confluent Cloud idle timeouts silently drop sockets.

## Development Notes

- Burst messages use:
  `Kaffe.Producer.produce_sync(topic, key, value)`(partition chosen by strategy).
- Probes use:
  `Kaffe.Producer.produce_sync(topic, partition, key, value)` (explicit partition).
- Partitions are auto-discovered at runtime using `:brod_client.get_partitions_count/2`.

## Troubleshooting

- `unknown_topic_or_partition` – make sure `CC_TOPIC` exists and your API key has write access.
- `No probe logs` – check that your topic has partitions; the code auto-discovers them.
- `Observer GUI missing` – install erlang-wx or use observer_cli for a TUI observer.
- Note that this project comes with an opinionated .`iex.exs` defining a module `DevObserver` to make `:observer.start()` work easily after having installed all the OS required deps.
