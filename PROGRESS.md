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
its own `cd`.

## Chapters

| Ch | Topic | Code | State | Evidence | Fork commit |
|----|-------|------|-------|----------|-------------|
| 03 | Basic REST services (4 microservices, multi-module Gradle) | yes | done, build + run verified | Chapter03/FINDINGS/FINDINGS.md | pending |
| 04 | | yes | todo | | |
| 05 | | yes | todo | | |
| 06 | | yes | todo | | |
| 07 | | yes | todo | | |
| 09 | | yes | todo | | |
| 10 | | yes | todo | | |
| 11 | | yes | todo | | |
| 12 | | yes | todo | | |
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

## Rules for the next run

1. Read this file, pick the first `todo` row, work only that chapter.
2. Write `ChapterNN/FINDINGS/FINDINGS.md` the same day the chapter runs.
3. Append one line to the commit log before declaring the chapter done.
4. FIXTURE-FIRST: where the chapter targets third-party services, stand up a
   local replica under Docker Compose before running against it.
5. If a chapter is partial, mark it `partial` and say what is unverified.
   Never mark `done` to clear the row.
