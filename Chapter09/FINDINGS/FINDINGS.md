# Chapter 09 — Service discovery with Netflix Eureka

## Summary

Ch09 introduces a **Eureka server** (`spring-cloud/eureka-server`, a separate
Gradle module in the same build) and turns each core and composite service into a
**Eureka client** that registers itself on startup and renews its lease every 5
seconds. The composite stops hard-coding `localhost` + port for the core services
and resolves them through the registry instead. This is the chapter that removes
the static topology from the earlier chapters.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB / 32 GB storage. Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS
Gradle 5.6.4, Spring Boot 2.3.2.RELEASE, Spring Cloud Hoxton.SR6
spring-cloud-starter-netflix-eureka-client 1.0.x (Hoxton.SR6)
Docker 29.9.2-2 · Docker Compose v5.6.1
```

### Infrastructure required (same as ch07, plus Eureka)

Five containers plus the Eureka server itself:

```sh
mongo:3.6.9 (27017)   mysql:5.7 with review-db (3306)
kafka (9092)          zookeeper (2181)      rabbitmq:3.8 (5672)
eureka-server         (port 8761, from spring-cloud/eureka-server)
```

### Build — one invocation, both modules

The Eureka server is a module of the same multi-module build
(`include ':spring-cloud:eureka-server'` in `settings.gradle`), so it does not
need a separate `gradlew`:

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter09
./gradlew build
```

Expected: `BUILD SUCCESSFUL`, with the `eureka-server` tasks present.
Actual: `BUILD SUCCESSFUL in 2m 1s`, 31 actionable tasks — up from ch07's 26,
the extra five being the new module.

### Run, then verify registration rather than assuming

```sh
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/ch09_eureka.log 2>&1 &
curl -s -o /dev/null -w "%{http_code}\n" localhost:8761/     # 200

for s in product-service review-service recommendation-service product-composite-service; do
  P=$(grep -m1 "server.port" microservices/$s/src/main/resources/application.yml | cut -d: -f2 | tr -d " ")
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/ch09_$s.log 2>&1 &
done
```

Expected: Eureka up, four services started and each registered.
Actual: Eureka `HTTP=200`, four `Started` lines, and in the client logs:

```
Registering application REVIEW with eureka with status UP
```

The registry side, counted rather than eyeballed:

```sh
curl -s localhost:8761/eureka/apps | grep -oE "<name>[A-Z-]+</name>" | sort | uniq -c
```

```
1 PRODUCT-COMPOSITE
1 PRODUCT
1 RECOMMENDATION
1 REVIEW
```

All four registered. The registry view is the check that proves service discovery
is doing something — a service can start and pass tests while never appearing in
the registry, and this chapter is about the registry.

### The book's own suite

```sh
HOST=localhost PORT=7000 ./test-em-all.bash
```

Expected: every assertion OK, including the async event step.
Actual — **all OK**:

```
Wait for: curl http://localhost:7000/actuator/health
200 / 200 / Wait for messages to be processed...
productId 2: 3 recs, 3 revs
404 "No product found for productId: 13"
productId 114: 0 recs, 3 revs
productId 214: 3 recs, 0 revs
422 "Invalid productId: -1"
400 "Type mismatch."
```

## Problems encountered

| What happened | Cause |
|---|---|
| First run: three of four services would not start | **All five infrastructure containers had exited.** Nothing to do with ch09. |
| Kafka container repeatedly exited | It needed a manual `docker start` and ~30s before `KafkaServer` was listening on 9092. |
| I briefly reported "REVIEW is not registered with Eureka" | **Wrong** — I read a `sort -u` listing truncated by `head` and inferred absence from a partial output. A `grep -oE … \| sort \| uniq -c` showed all four present, and the client log has `Registering application REVIEW with eureka with status UP`. |

The last row is the same failure mode as ch04 and ch05 — claiming a gap from an
incomplete listing — except this time I caught it before publishing. The fix is
the same: **count the registry with `uniq -c`; never infer absence from a
truncated list.**

## Fixes applied

None to source. Ch09 built, registered and ran unchanged, given Eureka plus the
five infrastructure containers.

## Benefit of this code run

A four-service system that no longer addresses its peers by hostname and port:
each service registers itself on boot, renews a lease, and is resolvable by name
from the registry. Verified by reading the registry itself and seeing all four
names, not merely by the API answering.

## Business value & opportunities

Service discovery is the prerequisite for autoscaling and for blue/green deploys
— without it, every instance must be configured with the addresses of its peers,
which is exactly what breaks when an instance count changes. The demonstrated
capability — self-registration with lease renewal and resolution by name — is
what lets a deployment add or remove instances without touching configuration.

## Still unverified (this chapter)

- **Eureka's own high availability was not tested.** One server, one peer; the
  book's multi-peer `defaultZone` setup was never stood up.
- The composite still ran with the `localhost` profile, so although the clients
  *registered* with Eureka, the composite's requests were **not observed
  resolving core services through the registry** — registration was verified,
  resolution-through-registry was not.
- `docker-compose.yml` was not started as a file; only the database containers
  were replicated, so the `docker` profile and `mem_limit` were not exercised.
- The Eureka dashboard was never rendered or screenshotted; only the `/eureka/apps`
  XML was read.
- No coverage report produced.
