# Hands-On Microservices with Spring Boot and Spring Cloud — chapter run state

Single source of truth for progress. Read at the start of every chapter run,
written at the end. Survives context compaction because it is on disk, not in
context. Each chapter gets its own `ChapterNN/FINDINGS/FINDINGS.md`; this file
is the index.

## Environment

Codespace `redesigned-guide-9j4x6q96qwjcp7p`, standardLinux32gb
(4 cores / 16 GB RAM / 32 GB storage; ~12 G free).

Decided on the codespace, for the whole book rather than the opening chapters:
Ch17+ runs Kafka and partition topologies under Docker Compose, and Docker is
inactive on the host with no sudo password available, so there was never a
local option.

| Tool | Version (pasted) |
|---|---|
| Java | openjdk 11.0.25 LTS — **installed this run** |
| Gradle | 5.6.4 (from `gradle-wrapper.properties`) |
| Spring Boot | 2.3.2.RELEASE, Spring 5.2.8.RELEASE |
| Docker | 29.9.2-2 |
| Docker Compose | v5.6.1 |

### Toolchain note that saves every later chapter

The wrapper pins Gradle 5.6.4 (Feb 2018), which supports Java 12 at most, and
Spring Boot 2.3.2 supports Java 8-15. The codespace's default Java 25 and its
Java 21 therefore **cannot** build any chapter of this book. Install Java 11 LTS
once and every chapter follows:

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
sdk install java 11.0.25-zulu
```

Also note: `gh codespace ssh` does **not** persist `cd` between calls, and
`gradlew` sits at each chapter's `2-*/` root, not in `api/`. Every command needs
its own `cd`. **The Gradle root also moves between chapters**: Ch03's is
`Chapter03/2-basic-rest-services/`, Ch04's and Ch05's are `ChapterNN/` itself.
Check `settings.gradle` before assuming.

### Killing services between chapters

- **Never `pkill -f "<name>"` when the remote command line also contains that
  name** — it matches its own shell and the SSH session dies with exit 255. Use
  `fuser -k <port>/tcp` per port, or the bracket trick `pkill -f 'pr[o]duct'`.
- **Free the ports before starting the next chapter.** Ch04's jars still held
  7000-7003 during the first Ch05 attempt, which made the composite fail to start
  and looked exactly like a code fault.

### Never assume a container is up

Every infrastructure failure in ch06 and ch07 was the same mistake: `docker run`
output piped to `/dev/null`, so a container that never started looked exactly
like one that did. `HibernateException: Access to DialectResolutionInfo cannot be
null` is "MySQL unreachable", and a MySQL container that simply does not exist.
Check invasively:

```sh
sudo docker inspect -f '{{.State.Status}}' <name>
ss -ltn | grep <port>          # is the port actually published?
sudo docker logs <name>        # e.g. "ready for connections"
```

### Old Docker images may be unpullable entirely

2018-era images published with the v1 manifest schema are refused by containerd
v2.1+: `media type application/vnd.docker.distribution.manifest.v1+prettyjws is
no longer supported`. The book's `wurstmeister/kafka` and
`wurstmeister/zookeeper` both hit this. Substitute a modern vendor's image of the
same major version and **verify the broker with a real round trip** before
trusting it.

### Ch07+: a missing broker looks like a dead composite

Ch07 puts both the Rabbit and Kafka binders on the classpath, so each core
service's Actuator health includes a **rabbit** binder check. With no RabbitMQ,
all three return `binders → rabbit → DOWN`, the composite's newly aggregating
health goes DOWN, and the book's suite fails at step one with zero assertions.
The symptom implicates the composite; the cause is a missing container.

## Chapters

| Ch | Topic | Code | State | Evidence | Fork commit |
|----|-------|------|-------|----------|-------------|
| 03 | Basic REST services (4 microservices, multi-module Gradle) | yes | done, build + run verified | Chapter03/FINDINGS/FINDINGS.md | b567f21 |
| 04 | Composite service, aggregation + validation | yes | done, book's full suite passed | Chapter04/FINDINGS/FINDINGS.md | 4b509f3 |
| 05 | Swagger/OpenAPI documentation of the API | yes | done, spec verified live | Chapter05/FINDINGS/FINDINGS.md | e993cb2 |
| 06 | Persistence (Mongo + MySQL), MapStruct, tests | yes | done, tests run + 20/20 suite | Chapter06/FINDINGS/FINDINGS.md | de037d8 |
| 07 | Events / async messaging (Spring Cloud Stream) | yes | done, suite + event flow passed | Chapter07/FINDINGS/FINDINGS.md | a81e944 |
| 09 | Service discovery with Netflix Eureka | yes | done, all four registered | Chapter09/FINDINGS/FINDINGS.md | 96a570b |
| 10 | Spring Cloud Gateway over Eureka discovery | yes | done, 24/24 + gateway 200s | Chapter10/FINDINGS/FINDINGS.md | 758586d |
| 11 | Security: Spring Security + OAuth2 resource server | yes | done, 27/27 incl 401/200/403 | Chapter11/FINDINGS/FINDINGS.md | 476aa5e |
| 12 | Centralised configuration (Spring Cloud Config) | yes | partial: config server runs, clients 401 on {cipher} creds | Chapter12/FINDINGS/FINDINGS.md | pending |
| 13 | | yes | todo | | |
| 14 | | yes | todo | | |
| 15 | | yes | todo | | |
| 16 | | yes | todo | | |
| 17 | | yes | todo | | |
| 18 | | yes | todo | | |
| 19 | | yes | todo | | |
| 20 | | yes | todo | | |

Chapters 01, 02 and 08 carry no code files — the book states code runs
Chapter03-20. They are gaps to report, not chapters to invent.

## What Chapter 03 verified

```
BUILD SUCCESSFUL in 23s        4 bootJar tasks, one per microservice
Netty started on port(s): 8081
Started ProductServiceApplication in 2.562 seconds
/actuator/health            -> {"status":"UP"}                            HTTP=200
/product/1                  -> {"productId":1,"name":"name-1","weight":123,
                                "serviceAddress":"codespaces-59c529/127.0.0.1:8081"}  HTTP=200
```

Not verified in ch03: review/recommendation/composite never started, no
cross-service call, tests skipped.

## What Chapter 04 verified

```
BUILD SUCCESSFUL in 3s          warm daemon, not a code change
ports 7000-7003 listening, composite health UP
/product-composite/1  -> 200: product 1, 3 recommendations, 3 reviews,
                          serviceAddresses cmp/pro/rec/rev all present
book's test-em-all.bash: ALL OK
   200 productId 1,   3 recs, 3 revs
   404 "No product found for productId: 13"
   200 productId 113, 0 recs, 3 revs
   200 productId 213, 3 recs, 0 revs
   422 "Invalid productId: -1"
   400 "Type mismatch."   (/product-composite/invalidProductId)
```

Not verified in ch04: `docker-compose.yml` never started; the `spring.profiles:
docker` profile (ports 8080, service-name hosts) never activated; tests skipped
(`-x test`); core services never queried directly.

## Rules for the next run

1. Read this file, pick the first `todo` row, work only that chapter.
2. Write `ChapterNN/FINDINGS/FINDINGS.md` the same day the chapter runs.
3. Append one line to the commit log before declaring the chapter done.
4. **Run the book's own test script if it has one, before writing any claim.**
   `test-em-all.bash` exists for ch04 and settles routes, status codes and error
   handling in one command. In this run it disproved a wrong conclusion I had
   already written down. Probe the documented route first, then claim a gap.
5. FIXTURE-FIRST: where the chapter targets third-party services, stand up a
   local replica under Docker Compose before running against it.
6. If a chapter is partial, mark it `partial` and say what is unverified.
   Never mark `done` to clear the row.
