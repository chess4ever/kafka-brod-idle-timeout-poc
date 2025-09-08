# Kafka Producer timeout issue - Root Cause Analysis

## Context

### What we observed in prod

At the beginning of August, during a bulk upload of UK claims in production, we observed a delay (around 5 minutes) during the production of integration events from claims-modeling-backend to its Kafka topic.

These were the logs we observed:

```
client :kaffe_producer_client: payload connection down b3-pkc-e8mp5.eu-west-1.aws.confluent.cloud:9092
reason::request_timeout

:kaffe_producer_client (re)connect to b3-pkc-e8mp5.eu-west-1.aws.confluent.cloud:9092 aborted.
last failure: :request_timeout

Failed to (re)init connection, reason:
:request_timeout

client :kaffe_producer_client connected to b3-pkc-e8mp5.eu-west-1.aws.confluent.cloud:9092
```

For more info see the related youtrack [card](https://prima-assicurazioni-spa.myjetbrains.com/youtrack/issue/CAB-10592/Investigate-Kafka-consumers-delays).

We couldn't reproduce the issue in staging, but we could reproduce it with a [POC](https://github.com/chess4ever/kafka-brod-idle-timeout-poc) connected to a personal basic confluent account. Please read the related README for details about the setup.

In a nutshell, what the POC does is sending a small burst of messages to the Kafka topic (to all partitions randomly), waiting for an IDLE_SECS time (the right balance between "quick" feedback and consistency seems to be 300 seconds) and then sending a probe message that visibly cannot be delivered to the broker until around 5 minutes pass, the old connection gets closed and brod spawns a new fresh connection and the probe is delivered and acknowledged by the broker (the same should happen for all partitions where at least one message was initially sent; it is good to check directly in the confluent console what partitions are "touched").

### The hypothesis

A **middlebox** on the path (NAT / firewall / load balancer) is **silently dropping idle TCP flows** after around 5 minutes. When we send the first post-idle produce, packets are blackholed (no ACKs, no RST/FIN), so the client’s TCP stack **retransmits with exponential backoff** and the app **waits**. Eventually the brod client tears the socket down and reconnects; with a fresh, non-idle flow the send/ack is immediate.

### The on-wire proof (what the packets show)

With `tcpdump` on the affected socket:

* During idle: **no** traffic (we weren’t using TCP keepalive yet).
* At the first post-idle send: one small client packet → **no ACK** → repeated **retransmissions** (gaps grow: ~0.3s, 0.6s, 1.2s… seconds → tens of seconds).
* No FIN/RST from anywhere (so not an explicit close).
* After around 5 minutes of idle the app gives up and reconnects: the **send is ACKed immediately** .

### What we’re going to prove end-to-end

1. **Reproduce** : with keepalive  **off** , we can reproduce the hang/timeout after about 5 minutes idle and watch retransmissions with `tcpdump`.
2. **Instrument** : use `ss -tino` to watch the socket’s timers (no `keepalive` timer when KA is off).
3. **Fix** : enable **per-socket TCP keepalive** on the brod client (so both metadata and payload sockets send probes during idle).
4. **Verify** :

* With KA  **on** , `ss -tino` shows `timer:(keepalive,…)`.
* `tcpdump` shows tiny keepalive packets every ~37s and **ACKs** from the broker.
* After the same idle window, the **first** produce **completes immediately** (no long backoff).

5. **(Optional)** demonstrate `TCP_USER_TIMEOUT` (20s) causing a **fast fail** if a post-idle data packet isn’t ACKed, even when keepalive is set high (to show we won’t sit for minutes on a blackhole again).

## Reproduce the stall with KA **off**

* **Config** : remove any `extra_sock_opts` and `request_timeout` from your  `:brod` client.
* Be sure to have this in your `.env` for a "quicker"" feedback loop:

  ```
  BURST_SIZE=4
  IDLE_SECS=300
  REPEATS=1
  ENABLE_REFRESHER=false
  ```
* **Host sysctls** (leave defaults):

```
cat /proc/sys/net/ipv4/tcp_keepalive_time    # expect 7200
cat /proc/sys/net/ipv4/tcp_keepalive_intvl   # expect 75
cat /proc/sys/net/ipv4/tcp_keepalive_probes  # expect 9

```

* **Env** : start IEx with no Erlang flags that might inject KA:

```
env -u ERL_FLAGS -u ELIXIR_ERL_OPTIONS BROD_DEBUG=0 iex -S mix

```

* **Runtime sanity checks (in IEx)**:

```
:application.get_env(:kernel, :inet_default_connect_options)  # expect :undefined
:application.get_env(:kernel, :inet_default_listen_options)   # expect :undefined
```

* **Verify that the socket has no keep alive timer:**

```
sudo ss -ptni dport = :9092 | grep beam.smp -A1
```

This should output 3 live sockets; pick the source port of one of those and go with

```
watch -n1 "sudo ss -tino sport = :$LPORT | sed -n '1,20p'"
```

or

```
watch -n1 -- "sudo ss -tino state established \( sport = :$LPORT1 or sport = :$LPORT2 or sport = :$LPORT3 \)"

```

if you want to see all the sockets together.

You shouldn't see any `timer` line, just rtt, rto and other details. That is a confirmation that KA is disabled for that socket (and this is true for all the 3 brod sockets).

* **Verify that the socket does not send keep alive and does not receive any FIN/RST:**

```
sudo timeout 600 tcpdump -i any -n -vvv -tttt "src port $LPORT or dst port $LPORT"
```

or

```
sudo tcpdump -i any -n -vvv -tttt "(tcp port 9092) and (src port $LPORT1 or dst port $LPORT1 or src port $LPORT2 or dst port $LPORT2 or src port $LPORT3 or dst port $LPORT3)"
```

You should observe no traffic at all between the burst and the first probe. Then you should observe such a pattern:

```
2025-09-08 14:58:55.091668 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 48939, offset 0, flags [DF], proto TCP (6), length 275)
    192.168.1.7.34076 > 34.194.20.210.9092: Flags [P.], cksum 0xfa48 (incorrect -> 0x83a9), seq 957:1180, ack 4395, win 471, options [nop,nop,TS val 3831610315 ecr 3109721164], length 223
2025-09-08 14:58:55.394798 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 48940, offset 0, flags [DF], proto TCP (6), length 275)
    192.168.1.7.34076 > 34.194.20.210.9092: Flags [P.], cksum 0xfa48 (incorrect -> 0x8279), seq 957:1180, ack 4395, win 471, options [nop,nop,TS val 3831610619 ecr 3109721164], length 223
2025-09-08 14:58:55.698942 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 48941, offset 0, flags [DF], proto TCP (6), length 275)
    192.168.1.7.34076 > 34.194.20.210.9092: Flags [P.], cksum 0xfa48 (incorrect -> 0x8149), seq 957:1180, ack 4395, win 471, options [nop,nop,TS val 3831610923 ecr 3109721164], length 223
...
```

In the output we see that the probe message being resent without any inbound package (no ACK/FIN/RST). Note that during the reconnection attempts you will see also metadata packets (on a different IP address).

If we want to see also the reconnection and the ACK to the probe, we need to slightly change the approach, because the new connection is a different socket on a different source port. We can check the traffic of all the IP addresses of our partition leader broker, or we can just see all the traffic related to Kafka. We will use now the latter approach, which can be used also to inspect traffic from the beginning, including the first connection and the initial burst:

```
sudo tcpdump -i any -n -vvv -tttt -s 0 'tcp port 9092'

```

What you will observe at the point of the application timeout is the brod client timing out the connection with this line

```
2025-09-08 15:03:54.805762 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 48951, offset 0, flags [DF], proto TCP (6), length 83)
    192.168.1.7.34076 > 34.194.20.210.9092: Flags [FP.], cksum 0xf988 (incorrect -> 0x1b35), seq 1180:1211, ack 4395, win 471, options [nop,nop,TS val 3831910029 ecr 3109721164], length 31
```

which is a FIN+PSH packet.

Then during the reconnection attempts you will observe some traffic to the metadata broker and finally when the brod client reconnects successfully to the partition leader (likely with a different IP address) you will see all the connection packets, starting with the initial SYN:

```
2025-09-08 15:08:54.907884 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 56253, offset 0, flags [DF], proto TCP (6), length 60)
    192.168.1.7.53290 > 13.219.126.200.9092: Flags [S], cksum 0x4e81 (incorrect -> 0x4266), seq 2522435991, win 64240, options [mss 1460,sackOK,TS val 1939369246 ecr 0,nop,wscale 7], length 0
```

And finally at the end of the handshake we see the probe sent and ACKed:

```
2025-09-08 15:08:55.583409 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 56262, offset 0, flags [DF], proto TCP (6), length 275)
    192.168.1.7.53290 > 13.219.126.200.9092: Flags [P.], cksum 0x4f58 (incorrect -> 0x9a6a), seq 736:959, ack 4303, win 471, options [nop,nop,TS val 1939369921 ecr 3024818413], length 223
2025-09-08 15:08:55.678113 wlp0s20f3 In  IP (tos 0x0, ttl 241, id 14665, offset 0, flags [DF], proto TCP (6), length 52)
    13.219.126.200.9092 > 192.168.1.7.53290: Flags [.], cksum 0xdcd3 (correct), seq 4303, ack 959, win 118, options [nop,nop,TS val 3024818509 ecr 1939369921], length 0
```

## Enable per-socket TCP keepalive (fix)

Turn on KA **only** for the brod client sockets (least intrusive fix). An alternative would be to enable it for the entire app using beam startup flags.

Upgrade the brod/kaffe config in `runtime.exs` to something similar to this:

```elixir
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
```

## Verify KA is active and working

* `strace` shows the setsockopt calls:

  Start iex without starting the application with `$ env -u ERL_FLAGS -u ELIXIR_ERL_OPTIONS BROD_DEBUG=0 iex -S mix run --no-start`

  In another terminal attach `strace` before starting the app:

  ```
  PID=$(pidof beam.smp)
  sudo strace -f -e trace=network -p "$PID" 2>&1 | \
    egrep -i 'connect\(.*:9092|setsockopt\(.*SO_KEEPALIVE|TCP_KEEP(IDLE|INTVL|CNT)|TCP_USER_TIMEOUT'
  ```

  and back in the `iex` session:

  ```
  iex(1)> Application.ensure_all_started(:kafka_idle_timeout_poc)
  ```

  For each socket you will see the following 5 lines:

  ```
  [pid 284577] setsockopt(21, SOL_TCP, TCP_USER_TIMEOUT, [20000], 4) = 0
  [pid 284577] setsockopt(21, SOL_TCP, TCP_KEEPCNT, [3], 4) = 0
  [pid 284577] setsockopt(21, SOL_TCP, TCP_KEEPINTVL, [9], 4) = 0
  [pid 284577] setsockopt(21, SOL_TCP, TCP_KEEPIDLE, [37], 4) = 0
  [pid 284577] setsockopt(21, SOL_SOCKET, SO_KEEPALIVE, [1], 4) = 0
  ```

  This confirms that the KA config was applied to all brod connections.
* **Watch the kernel timers (ss):**

  Rerun the POC and after the initial burst observe this time the a KA timer is set

  ```
  watch -n1 -- "sudo ss -ptino state established '( dport = :9092 )' | sed -n '1,200p'"

  ```

  and observe for each socket the line `timer:(keepalive,XXms,0)`. This is another proof that KA is enabled on all brod sockets.
* Capture the keepalive probes with `tcpdump` as before:

  ```
  sudo tcpdump -i any -n -vvv -tttt -s 0 'tcp port 9092'
  ```

  Every about 37s you should see 2 lines for each socket:

  ```
  2025-09-08 16:13:40.058894 wlp0s20f3 Out IP (tos 0x0, ttl 64, id 39577, offset 0, flags [DF], proto TCP (6), length 52)
      192.168.1.7.40396 > 34.233.240.208.9092: Flags [.], cksum 0xd58f (incorrect -> 0x9b9b), seq 300129365, ack 1180240174, win 426, options [nop,nop,TS val 3747556980 ecr 2212148047], length 0
  2025-09-08 16:13:40.155956 wlp0s20f3 In  IP (tos 0x0, ttl 111, id 52298, offset 0, flags [DF], proto TCP (6), length 52)
      34.233.240.208.9092 > 192.168.1.7.40396: Flags [.], cksum 0x5aca (correct), seq 1, ack 1, win 16920, options [nop,nop,TS val 2212185318 ecr 3747519807], length 0
  ```

  The first line is the KA sent to the broker, and the second one is the related ACK from the broker.

## Fast fail on blackholed socket

Note that even if we set a very high `TCP_KEEPIDLE` (like 600), the `TCP_USER_TIMEOUT=20000` flag will make the socket fail fast.

If you run the POC with this values, you will see the reconnection attempts 20s after the probe is being sent without an ACK.

## Tuning `request_timeout` and `max_retries` and other knobs

Why they matter?

* **`request_timeout` (client)**

Upper bound for a single Kafka request (Produce, Metadata, etc.) on a given socket.

*Without* `TCP_USER_TIMEOUT`, a blackhole can leave the TCP socket “alive” and the app would wait until this timer fires → you see `reason: :request_timeout` and brod reconnects.

*With* `TCP_USER_TIMEOUT` (e.g., 20s), the kernel will fail the un-ACKed send faster; `request_timeout` becomes a **safety ceiling** (should be **>** `TCP_USER_TIMEOUT`), ensuring you never wait minutes if the kernel doesn’t trip.

* **`max_retries` + `retry_backoff_ms` (producer)**

  After a failure (connection drop, leader move, transient broker error), brod’s producer buffer  **resends**. This is independent from TCP retransmissions. These knobs decide how long we’ll keep retrying at the app layer **after** brod reconnects.

  Set them to ride through brief broker hiccups/rolling restarts without dropping messages.
* **`ack_timeout` + `required_acks`**

  With `required_acks: -1` (acks=all), the broker waits for ISR replicas before acking. `ack_timeout` bounds that wait so a slow replica doesn’t stall the producer forever.

## How to know the role of each socket

When you run:

```
sudo ss -ptni '( dport = :9092 )' | grep beam.smp -A1
```

you usually see 3 TCP sockets opened by the Erlang VM (`beam.smp`) toward your Kafka broker(s). Each socket has a different role inside the Kafka client:

#### 1. **Metadata socket**

* Used by brod/kafka_client to send **Metadata requests** (cluster topology, broker info, partition leaders).
* Identifiable because:
  * It connects to **any broker** (doesn’t need to be the leader of a partition).
  * Traffic is light, periodic (refreshes).
  * Closing it only delays discovery, not data production.

#### 2. **Producer socket**

* Used by the producer process to **send Produce requests** with your messages.
* Identifiable because:
  * Local Erlang process (PID in `ss`) will match the **producer connection** in `:sys.get_state`
  * You see **large payloads** flowing outbound (look at `bytes_sent` in `ss -i`).
  * Each producer socket is tied to the broker that is **leader** for the topic/partition you’re writing to.

Also note that with `:brod_client.get_metadata(:kaffe_producer_client, "demo_elixir")` you can get the topic metadata (list of all brokers and partitions leaders) and with the command `getent hosts bXX-pkc-p11xm.us-east-1.aws.confluent.cloud` you can see the mapped IP addresses for each broker, so that you can manually relate the sockets to the host (useful if you are looking also at the POC logs where we see the partition leader broker).

## Nice to have

- It would be nice to be able to reproduce it in staging
- It would be nice to be able to reproduce it locally with redpanda instead of confluent in order to have a faster feedback loop
