# Chapter 07 — Events and asynchronous messaging (Spring Cloud Stream, Kafka/Rabbit)

## Summary

Ch07 makes the composite service **asynchronous**. Instead of three synchronous
calls, it publishes an `Event` to a Spring Cloud Stream binder and the core
services consume it. The chapter adds `se.magnus.api.event.Event`, both
`spring-cloud-starter-stream-kafka` and `spring-cloud-starter-stream-rabbit`,
and `MessagingTests`. It also introduces two things that matter operationally:
the composite's `/actuator/health` now **aggregates the downstream services'
health**, and `docker-compose-kafka.yml` / `docker-compose-partitions.yml` run
the whole system with Kafka.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB / 32 GB storage. Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS
Gradle 5.6.4, Spring Boot 2.3.2.RELEASE, Spring Cloud Hoxton.SR6
Docker 29.9.2-2 · Docker Compose v5.6.1
```

### Blocker found first, and its workaround

**The book's Kafka images cannot be pulled at all.** `docker-compose-kafka.yml`
pins `wurstmeister/kafka:2.12-2.1.0` and `wurstmeister/zookeeper:3.4.6`, and both
fail with:

```
Error response from daemon: not implemented: media type
"application/vnd.docker.distribution.manifest.v1+prettyjws" is no longer
supported since containerd v2.1
```

Those 2018 images were published with the v1 manifest schema, which Docker's
current containerd storage layer refuses outright. This is not a registry or
network problem — the images are unloadable on any modern Docker.

Substituted equivalent modern images with the same 2.1-era Kafka semantics:

```sh
docker run -d --name ch7zk -p 2181:2181 -e ZOOKEEPER_CLIENT_PORT=2181 \
  confluentinc/cp-zookeeper:5.5.0

docker run -d --name ch7kafka -p 9092:9092 --link ch7zk:zookeeper \
  -e KAFKA_ZOOKEEPER_CONNECT=zookeeper:2181 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
  -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  confluentinc/cp-kafka:5.5.0
```

Verified the broker with a real round trip rather than by assuming it worked:

```
Created topic ch07probe.
consumed: hello-kafka-1794232423
```

### Second blocker: Rabbit, and why it is not optional

The chapter adds the Rabbit binder *alongside* Kafka, so the Actuator health of
all three core services includes a **rabbit binder** check. With no RabbitMQ
running:

```json
{"status":"DOWN","components":{"binders":{"status":"DOWN",
 "components":{"rabbit":{"status":"DOWN","details":{"error":
 "org.springframework.amqp.AmqpConnectException: java.net.ConnectException:
 Connection refused"}}}}}}
```

That cascaded into the composite being DOWN and the book's suite failing at its
very first step (`Wait for: curl .../actuator/health` retrying forever). Added:

```sh
docker run -d --name ch7rabbit -p 5672:5672 -p 15672:15672 \
  rabbitmq:3.8-management-alpine
```

After it came up, all three core services returned 200 and the suite ran.

**This is the finding worth carrying forward:** Ch07's health check is a real
dependency, so a missing broker does not look like "a service is down" — it
looks like the composite is down, which is a very different and much more
alarming symptom. The book's own Compose files cover Kafka but not Rabbit, even
though both binders are on the classpath.

### Build

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter07
./gradlew build
```

Expected: `BUILD SUCCESSFUL` with tests, now including `MessagingTests`.
Actual: `BUILD SUCCESSFUL in 1m 43s`, 26 actionable tasks (up from ch06's 24,
the new event tests).

### Run

Four services on 7000-7003 plus three infrastructure containers (Mongo 3.6.9,
MySQL 5.7, Kafka, Rabbit).

```sh
HOST=localhost PORT=7000 ./test-em-all.bash
```

Expected: every assertion OK, **and** the script's `Wait for messages to be
processed...` step passing, which is the proof the event flow works.
Actual — all OK, including that step:

```
Wait for: curl http://localhost:7000/actuator/health
Test OK (HTTP Code: 200)
Test OK (HTTP Code: 200)
Wait for messages to be processed...        <- async event flow verified
Test OK (HTTP Code: 200)    productId 2,  3 recs, 3 revs
Test OK (HTTP Code: 200)    3 recs, 3 revs
Test OK (HTTP Code: 404)    "No product found..."
Test OK (HTTP Code: 200)    productId 114, 0 recs, 3 revs
Test OK (HTTP Code: 200)    productId 214, 3 recs, 0 revs
Test OK (HTTP Code: 422)    "Invalid productId: -1"
Test OK (HTTP Code: 400)    "Type mismatch."
```

The product ids differ from ch06 (2, 114, 214 rather than 1, 113, 213) precisely
because the messaging path created them through the event consumer rather than
in synchronous handler code.

## Problems encountered

| What happened | Cause |
|---|---|
| Compose up failed completely | `wurstmeister/*` images unpublished from modern Docker's schema support. Substituted Confluent images. |
| `review-service` would not start for a long time | MySQL container had silently failed to start — I had piped `docker run` output to `/dev/null 2>&1` and never saw it. Symptom was `HibernateException: Access to DialectResolutionInfo cannot be null`, i.e. "can't reach MySQL". |
| Suite failed at step one with 0 assertions | `binders → rabbit → DOWN` from a missing RabbitMQ, propagated to the composite's aggregate health. |
| MySQL container vanished entirely | The earlier `docker run` had failed and I assumed from a later `docker ps` line that it was up. |

Two of these are the same class of my own error: **assuming an infrastructure
container was up because I could not see the failure.** Both are now avoided by
checking `docker inspect -f {{.State.Status}}` with *visible* output.

## Fixes applied

None to source. Ch07 built, tested and ran unchanged once the four
infrastructure containers were correct.

## Benefit of this code run

A four-service system where the composite no longer waits on three synchronous
calls: it fires an event, the core services process it, and the assertions
confirm the result — with the script's explicit "wait for messages to be
processed" step passing. That is the asynchronous architecture the rest of the
book builds on, verified end to end rather than assumed.

## Business value & opportunities

Async messaging is what keeps a write request from blocking on three downstream
services, which is the difference between a system that absorbs a traffic spike
and one that folds on it. The demonstrated capability — publish-once,
consume-many, with the health of every dependent surface visible in one
endpoint — is the pattern behind order pipelines, notification fans and
event-driven inventory updates.

## Still unverified (this chapter)

- **Kafka was substituted, not the book's own images**, and the substitution is
  a different vendor's distribution (Confluent 5.5.0 vs wurstmeister 2.12-2.1.0).
  The broker is modern Kibana-era Kafka with the same 2.1 semantics, but it is
  not byte-identical to the book's pin.
- Only `docker-compose-kafka.yml`'s database services were replicated, and then
  as bare `docker run` containers. Neither Compose file (Kafka or partitions) was
  ever started as a file, so the `docker` Spring profile, service-name hosts and
  `mem_limit` were never exercised.
- `docker-compose-partitions.yml` was never run, so the partition-topology
  section of the chapter is unverified.
- Event *content* was not inspected; the tests confirm consumers processed
  events, not what the event payloads contained.
- No coverage report was produced.
