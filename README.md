# nats-js-wq-issue
Repo containing test code/scripts to reproduce a NATS JetStream bug in conjunction with R3 worker queues.

The consumer will fail to ack' every 10th message (with `max_deliver=2`) so that NATS emits an advisory and keeps the dead-lettered message in the worker queue after 2 failed delivery attempts.

## NATS Setup

```
                                    NATS Cluster: "nats_cluster"
    ┌────────────────────────────────────────────────────────────────────────────────────────────────┐
    │                                                                                                │
    │       ┌───────────┐                   ┌───────────┐                   ┌───────────┐            │
    │       │    s1     │◄─────────────────►│    s2     │◄─────────────────►│    s3     │            │
    │       │  :4222    │                   │           │                   │           │            │
    │       │  :8222    │                   │           │                   │           │            │
    │       │  :6222    │                   │  :6222    │                   │  :6222    │            │
    │       └─────┬─────┘                   └─────┬─────┘                   └─────┬─────┘            │
    │             │                               │                               │                  │
    │             └───────────────────────────────┼───────────────────────────────┘                  │
    │                                             │                                                  │
    │                                      ┌──────┴──────┐                                           │
    │                                      │  JetStream  │                                           │
    │                                      └──────┬──────┘                                           │
    │                                             │                                                  │
    │             ┌───────────────────────────────┴───────────────────────────────┐                  │
    │             │                                                               │                  │
    │   ┌─────────┴─────────────────────────────────────────────┐    ┌────────────┴───────────────┐  │
    │   │ Stream "monitoring" | R=3 | memory                    │    │ Stream "wq" | R=3 | memory │  │
    │   │ subjects: $JS.EVENT.ADVISORY.>                        │    │ subjects: wq.*             │  │
    │   │ retention: limits                                     │    │ retention: work-queue      │  │
    │   └─────────────────────────┬─────────────────────────────┘    └──────────────────┬─────────┘  │
    │                             │                                                     │            │
    │   ┌─────────────────────────┴─────────────────────────────┐    ┌──────────────────┴─────────┐  │
    │   │ Consumer "dlq-monitor"                                │    │ Consumer "c-wq-0"          │  │
    │   │ filter: $JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>  │    │ filter: wq.0               │  │
    │   └───────────────────────────────────────────────────────┘    └────────────────────────────┘  │
    │                                                                                                │
    └────────────────────────────────────────────────────────────────────────────────────────────────┘
                  │
                  │ client port :4222
                  ▼
            ┌───────────┐
            │  Clients  │
            └───────────┘
```

## Prerequisites
- Go SDK >= 1.25.7
- Docker / Docker Compose
- Curl
- NATS CLI

### Windows
- PowerShell

### Linux
- JQ

## Test Execution
### Windows
```powershell
.\test.ps1
```

### Linux
```sh
chmod -x test.sh

test.sh
```

## Results
The output might look like:
```
=== Analyzing API Monitor Logs ===

20 dead-lettered messages
Obtaining Stream stats

╭─────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│                                                Stream Report                                                │
├────────────┬─────────┬───────────┬───────────┬──────────┬────────┬──────┬─────────┬───────────┬─────────────┤
│ Stream     │ Storage │ Placement │ Consumers │ Messages │ Bytes  │ Lost │ Deleted │ API Level │ Replicas    │
├────────────┼─────────┼───────────┼───────────┼──────────┼────────┼──────┼─────────┼───────────┼─────────────┤
│ wq         │ Memory  │           │ 1         │ 9        │ 837 B  │ 0    │ 72      │ 0         │ s1*, s2, s3 │
│ monitoring │ Memory  │           │ 1         │ 229      │ 79 KiB │ 0    │ 0       │ 0         │ s1, s2*, s3 │
╰────────────┴─────────┴───────────┴───────────┴──────────┴────────┴──────┴─────────┴───────────┴─────────────╯

╭───────────────────────────────────────────────────────────────────────────╮
│                      9 Subjects in stream monitoring                      │
├───────────────────────────────────────────────────────────────────┬───────┤
│ Subject                                                           │ Count │
├───────────────────────────────────────────────────────────────────┼───────┤
│ $JS.EVENT.ADVISORY.CONSUMER.CREATED.monitoring.dlq-monitor        │ 1     │
│ $JS.EVENT.ADVISORY.STREAM.CREATED.monitoring                      │ 1     │
│ $JS.EVENT.ADVISORY.STREAM.LEADER_ELECTED.wq                       │ 1     │
│ $JS.EVENT.ADVISORY.CONSUMER.LEADER_ELECTED.monitoring.dlq-monitor │ 1     │
│ $JS.EVENT.ADVISORY.CONSUMER.CREATED.wq.c-wq-0                     │ 1     │
│ $JS.EVENT.ADVISORY.CONSUMER.LEADER_ELECTED.wq.c-wq-0              │ 1     │
│ $JS.EVENT.ADVISORY.STREAM.CREATED.wq                              │ 1     │
│ $JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.wq.c-wq-0              │ 20    │
│ $JS.EVENT.ADVISORY.API                                            │ 204   │
╰───────────────────────────────────────────────────────────────────┴───────╯

  Checking seq 10 on stream wq.. NOT FOUND
  Checking seq 20 on stream wq.. NOT FOUND
  Checking seq 30 on stream wq.. NOT FOUND
  Checking seq 40 on stream wq.. NOT FOUND
  Checking seq 50 on stream wq.. NOT FOUND
  Checking seq 60 on stream wq.. NOT FOUND
  Checking seq 70 on stream wq.. NOT FOUND
  Checking seq 80 on stream wq.. NOT FOUND
  Checking seq 90 on stream wq.. NOT FOUND
  Checking seq 100 on stream wq.. NOT FOUND
  Checking seq 110 on stream wq.. NOT FOUND
  Checking seq 120 on stream wq.. OK
  Checking seq 130 on stream wq.. OK
  Checking seq 140 on stream wq.. OK
  Checking seq 150 on stream wq.. OK
  Checking seq 160 on stream wq.. OK
  Checking seq 170 on stream wq.. OK
  Checking seq 180 on stream wq.. OK
  Checking seq 190 on stream wq.. OK
  Checking seq 200 on stream wq.. OK

DNFs: 11 out of 20 dead-lettered messages missing
```

**In this example run, <ins>11 out of 20 messages are missing</ins> in the worker queue, even though being neither ack'ed nor TTL'ed.**