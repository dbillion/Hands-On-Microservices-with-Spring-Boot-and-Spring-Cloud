# Chapter 14 — Distributed tracing with Spring Cloud Sleuth and Zipkin

## Summary

Ch14 wires Spring Cloud Sleuth into all seven modules plus the Zipkin sender, so
every request carries a trace context that travels with it. Spans are not posted
to a Zipkin endpoint — they are published to **RabbitMQ**
(`spring.zipkin.sender.type: rabbit`), consumed by Zipkin's `RabbitMQCollector`,
and stored in memory. Sampling is total (`spring.sleuth.sampler.probability:
1.0`) so every request is recorded.

The book's own `test-em-all.bash` asserts nothing about tracing. The verification
that matters is therefore not the suite but the collector: that a single request
produces one trace whose spans come from every service it touched, with the trace
context intact across each hop.

## Verdict: PASS — the whole stack runs, and traced spans really do correlate

Two independent results, both from real output:

1. The book's own suite: **51 assertions, 0 failures, `End, all tests OK`**.
2. Zipkin (`http://localhost:9411`), after a single
   `GET /product-composite/2` through the gateway: **29 traces spanning more than
   one service**, 25 client spans whose server-side counterpart carries the
   **same span id**, and one 18-span trace covering gateway, product-composite,
   product, review and recommendation with correct parentage throughout.

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, standardLinux32gb, 4 cores / 16 GB RAM |
| Java | `openjdk version "11.0.25" 2024-10-15 LTS` (via sdkman) |
| Gradle | `gradle-5.6.4-bin.zip` |
| Spring Boot / Cloud | 2.3.2.RELEASE / Hoxton.SR6 |
| Zipkin | `openzipkin/zipkin:2.12.9`, `STORAGE_TYPE=mem`, `RabbitMQCollector` |
| Docker | `ch7kafka ch7rabbit ch7zk ch6mysql ch6mongo` running |

## Runbook — repeat the whole chapter from scratch

```sh
# 0. infrastructure (inherited from ch12/ch13 — verify, don't assume)
sudo docker ps --format '{{.Names}}'

# 1. Zipkin must read the same RabbitMQ the services publish to.
#    --network host makes RABBIT_ADDRESSES=127.0.0.1 resolve the same way it
#    does inside the services, so no compose network is needed.
sudo docker rm -f ch14zipkin
sudo docker run -d --name ch14zipkin --network host \
  -e STORAGE_TYPE=mem -e RABBIT_ADDRESSES=127.0.0.1 \
  openzipkin/zipkin:2.12.9
sleep 25
curl -s http://localhost:9411/health
```
Expected health, actual:
```
{"status":"UP","zipkin":{"status":"UP","details":{"InMemoryStorage":{"status":"UP"},
 "RabbitMQCollector":{"status":"UP"}}}}
```
`RabbitMQCollector: UP` is the line that matters: Zipkin is actually consuming
spans, not merely running.

```sh
# 2. free every port the stack owns
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do fuser -k $p/tcp; done
sleep 12
ss -ltn | grep -cE ':(7000|7001|7002|7003|8443|8761|9999|8888)'   # must print 0

# 3. build
cd Chapter14 && source /usr/local/sdkman/bin/sdkman-init.sh
./gradlew build
```
Expected `BUILD SUCCESSFUL`; actual `BUILD SUCCESSFUL in 2m 3s`,
`49 actionable tasks: 49 executed`.

```sh
# 4. start the stack — all three credential exports, as in ch12/ch13
cd Chapter14
export ENCRYPT_KEY=my-very-secure-encrypt-key          # NOT CONFIG_SERVER_ENCRYPT_KEY
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/c14cfg.log 2>&1 &
sleep 40
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd   # what the clients send
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu14.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth14.log 2>&1 &
sleep 35
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw14.log 2>&1 &
sleep 35
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c14_$s.log 2>&1 &
done
sleep 90
curl -sk -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' \
  | grep -oE '"name":"[A-Z-]+"' | sort -u
```
Expected six registrations; actual `AUTH-SERVER GATEWAY PRODUCT
PRODUCT-COMPOSITE RECOMMENDATION REVIEW`.

```sh
# 5. exercise a traced request and read the collector (the real verification)
TOK=$(curl -sk -s https://writer:secret@localhost:8443/oauth/token \
  -d grant_type=password -d username=magnus -d password=password | jq -r .access_token)
curl -sk -o /dev/null -H "Authorization: Bearer $TOK" 'https://localhost:8443/product-composite/2'
sleep 20
curl -s 'http://localhost:9411/api/v2/traces?serviceName=product-composite&limit=200' | jq ...
```

**Filter by `serviceName`, never by recency.** Zipkin's in-memory store holds a
bounded number of traces and Eureka's heartbeat floods them: querying
`?limit=100` returns 100 traces of which 99 are `eureka-server get` spans, and the
request you want has already been evicted. Querying
`?serviceName=product-composite` returns exactly the traces that matter.

**Ports and protocols** (the ch13 lesson, unchanged): the composite serves plain
**HTTP on 7000**, the gateway is the TLS endpoint on **8443**, and the bearer
token comes from the **gateway**, not the auth server on 9999.

## What the collector actually held

```
traces fetched (serviceName=product-composite): 35
of those, spanning more than one service:        29

spans by service:
    product-composite: 124
    gateway:           87
    review:            29
    recommendation:     29
    product:           21

largest multi-service trace  (traceId d01ac1ff96d6cdb4, 18 spans):
    gateway            SERVER   post                     id=d01ac1ff parent=-
    gateway            CLIENT   post                     id=e740f3d7 parent=d01ac1ff
    gateway            CLIENT   post                     id=3496fb81 parent=d01ac1ff
    product-composite  SERVER   post /product-composite  id=3496fb81 parent=d01ac1ff
    product-composite  PRODUCER send                     id=046cca09 parent=3496fb81
    product-composite  PRODUCER send                     id=d07f507b parent=3496fb81
    product-composite  PRODUCER send                     id=249d690e parent=3496fb81
    product-composite  PRODUCER send                     id=0aa8d872 parent=3496fb81
    product-composite  PRODUCER send                     id=eb3c2b64 parent=3496fb81
    product-composite  PRODUCER send                     id=15b56556 parent=3496fb81
    product-composite  PRODUCER send                     id=a22df190 parent=3496fb81
    product            PRODUCER send                     id=e75d2d3f parent=046cca09
    review             PRODUCER send                     id=89b7da32 parent=eb3c2b64
    recommendation     PRODUCER send                     id=5a006fc4 parent=d07f507b
    recommendation     PRODUCER send                     id=ca3f8827 parent=249d690e
    recommendation     PRODUCER send                     id=24c94543 parent=0aa8d872
    review             PRODUCER send                     id=d9b83bc4 parent=15b56556
    review             PRODUCER send                     id=f90243cb parent=a22df190
```

**The correlation test that decides the claim.** A trace is genuinely distributed
only when a CLIENT span and the target service's SERVER span share **one span
id** — if the id changes, the context was lost and the spans are orphans:

```
    OK   product-composite CLIENT 720e0131 -> recommendation SERVER 720e0131
    OK   product-composite CLIENT c64e3473 -> recommendation SERVER c64e3473
    OK   product-composite CLIENT 59c69aff -> review          SERVER 59c69aff
    OK   product-composite CLIENT a826dbef -> recommendation SERVER a826dbef
    OK   product-composite CLIENT 1946fd8e -> review          SERVER 1946fd8e
    ...
    total: 25 client spans whose server-side counterpart shares the same span id
           91 client spans with no server span of the same id
```

All 25 synchronous HTTP hops are correlated. The 91 unmatched client spans are the
asynchronous `PRODUCER send` spans shown in the trace above: a message published
to RabbitMQ has no synchronous SERVER counterpart in the same request, so they are
expected not to match — and the parentage in the trace above shows the context
still travels with the message into the consumer's own PRODUCER span.

## Benefit of the code run

Every request now carries one identifier across the gateway, the composite and its
three dependencies, and those spans reach a collector without any application code
touching tracing — Sleuth injects it through the HTTP client and the Spring
configuration supplies the RabbitMQ transport. A slow or failed aggregation can
now be decomposed per hop.

## Business value & opportunities

1. **Cross-service latency is attributable.** Before this, "why was that page
   slow?" had to be answered from six independent logs with no shared key. After
   it, one trace id yields the per-hop timings that name the responsible
   dependency.
2. **Failure localisation replaces guesswork.** A timeout inside an aggregation
   can be traced to the specific hop that produced it, which is the difference
   between a one-line fix and a multi-hour investigation.
3. **Sampling is a production cost lever.** `spring.sleuth.sampler.probability:
   1.0` records everything for development; the same knob drops to `0.01` in
   production, keeping the observability while cutting the trace volume and its
   storage cost.

## Recommendations

- Query Zipkin **by `serviceName`**, not by recency. In-memory storage is
  bounded and Eureka's heartbeats flood it; a `?limit=N` query returns heartbeats
  and hides the request under test.
- Wait for the collector. Spans are published asynchronously to RabbitMQ and
  consumed by Zipkin; querying immediately after a request returns stale data.
  A 15–20 s sleep before reading is enough at this sampling rate.
- Read the composite's own `application.yml` to learn the transport
  (`spring.zipkin.sender.type`) before assuming spans are POSTed to
  `/api/v2/spans`. In this chapter they travel through RabbitMQ.
- The book provides no tracing assertions, so a suite alone cannot verify this
  chapter. The collector is the evidence.

## Still unverified (this chapter)

- The Kafka transport path (`spring.zipkin.sender.type: kafka`, the `kafka`
  profile) was configured but not exercised; only the RabbitMQ sender was run.
- `docker-compose up` was never run, so Compose build/up paths are unexercised;
  Zipkin was started as a standalone container with `--network host`.
- No retention test: `STORAGE_TYPE=mem` holds a bounded set of traces, and no
  assertion bounds how long a trace stays queryable.

