# Chapter 03 — Basic REST services (multi-module Gradle, Spring Boot 2.3.2)

## Summary

Four microservices (product, review, recommendation, product-composite) built
from one multi-module Gradle project, plus the shared `api` and `util` source
modules that get copied into each service by the book's own
`create-projects.bash`. The chapter's point is the module split and the
composite service aggregating the three core services.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB RAM / 32 GB storage (12 G free). Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS          <- installed this run
Gradle 5.6.4                                       <- from gradle-wrapper.properties
Spring Boot 2.3.2.RELEASE, Spring 5.2.8.RELEASE   <- from the startup log
Docker 29.9.2-2 · Docker Compose v5.6.1           <- present, unused in ch03
```

**Source:** fork `dbillion/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud`,
branch `master`.

### The toolchain decision, made before the first build

The wrapper pins `gradle-5.6.4` (Feb 2018). Gradle 5.6.4 supports Java up to 12,
and Spring Boot 2.3.2 supports Java 8-15, so neither the codespace's default
Java 25 nor its Java 21 can run this project. `spring init` in
`create-projects.bash` also pins `--boot-version=2.1.0.RELEASE --java-version=1.8`,
confirming the book's intended toolchain is 2018-2020 era.

Installed **Java 11.0.25 LTS** via sdkman and set it as default — the newest
version that both Gradle 5.6.4 and Spring Boot 2.3.2 support.

```sh
sdk install java 11.0.25-zulu
```

Expected: `Setting java 11.0.25-zulu as default.`
Actual: same. `java -version` then printed `openjdk version "11.0.25" 2024-10-15 LTS`.

### Build

```sh
cd Chapter03/2-basic-rest-services
./gradlew build -x test
```

Expected: `BUILD SUCCESSFUL`, four `bootJar` tasks, one per microservice.
Actual:

```
> Task :microservices:product-service:bootJar
> Task :microservices:review-service:bootJar
> Task :microservices:recommendation-service:bootJar
> Task :microservices:product-composite-service:bootJar
BUILD SUCCESSFUL in 23s
16 actionable tasks: 16 executed
```

Note: `gradlew` lives at `Chapter03/2-basic-rest-services/gradlew`, not in
`api/`. Running it from `api/` fails with `No such file or directory` — the
root project is one level down.

### Run

`application.yml` sets `server.port: 7001`, so the port is passed explicitly to
keep the run on a loopback port:

```sh
nohup java -jar microservices/product-service/build/libs/*.jar --server.port=8081
curl -s localhost:8081/actuator/health
curl -s localhost:8081/product/1
```

Expected: health `{"status":"UP"}` and a product object whose `serviceAddress`
records the host and port it was served from.
Actual:

```
INFO  o.s.b.web.embedded.netty.NettyWebServer  : Netty started on port(s): 8081
INFO  s.m.m.c.p.ProductServiceApplication       : Started ProductServiceApplication in 2.562 seconds

{"status":"UP"}                                                                 HTTP=200
{"productId":1,"name":"name-1","weight":123,"serviceAddress":"codespaces-59c529/127.0.0.1:8081"}  HTTP=200
```

The `serviceAddress` echoing back `127.0.0.1:8081` is the concrete
demonstration that the service knows where it is reachable.

## Problems encountered

| What happened | Cause |
|---|---|
| `./gradlew: No such file or directory` | `cd` does not persist between `gh codespace ssh` calls, and the wrapper is at the multi-module root, not in `api/` |
| Build cannot start on Java 25 or 21 | `gradle-wrapper.properties` pins 5.6.4, which supports Java 12 at most |
| `spring init` unavailable | The Spring Boot CLI is not installed and no longer offers `--boot-version=2.1.0.RELEASE` |

## Fixes applied

None to source. The only fix needed was environmental: install Java 11 LTS,
the newest version both Gradle 5.6.4 and Spring Boot 2.3.2 support. No book
file was edited.

## Benefit of this code run

A four-service Spring Boot 2.3.2 system built from a single multi-module Gradle
invocation, with one service verified live: it starts, reports health, and
serves real JSON. That is the base the remaining 16 chapters build on — the
same module layout carries through to Spring Cloud in Ch15-20.

## Business value & opportunities

The multi-module Gradle layout with per-service jars and a composite
aggregator is the structure used by teams shipping several services that must
be versioned and released together. The demonstrated capability — one build
producing four independently deployable jars, each self-reporting its own
address — is what lets a small team own many services without per-service
build scripts.

## Still unverified (this chapter)

- Review, recommendation and product-composite services were built but not
  started or queried; only product-service was run.
- No cross-service call was made, so nothing tests the composite's
  aggregation logic.
- Tests were skipped (`-x test`); the suite never ran.
