# Chapter 04 — Composite service (aggregation + validation + error paths)

## Summary

The product-composite service gains real behaviour in this chapter: it calls the
product, recommendation and review services concurrently and merges the three
answers into one aggregate. The book's own end-to-end script
(`test-em-all.bash`) exercises the happy path plus three failure paths, and all
of them pass.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB / 32 GB storage. Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS        <- installed for ch03, persists
Gradle 5.6.4                                     <- gradle-wrapper.properties
Spring Boot 2.3.2.RELEASE, Spring 5.2.8.RELEASE
Docker 29.9.2-2 · Docker Compose v5.6.1
```

**Source:** fork `dbillion/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud`,
branch `master`, built on the ch03 commit.

### Build

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter04            # NOTE: the project root is here, not under a 2-*/ subdir
./gradlew build -x test
```

Expected: `BUILD SUCCESSFUL`, four `bootJar` tasks.
Actual: `BUILD SUCCESSFUL in 3s`, 16 actionable tasks.

Ch03 took 23s; Ch04 took 3s because the Gradle daemon was warm and the
unchanged `api` and `util` modules were already built. Not a code change.

### Run all four services

```sh
for s in product-service review-service recommendation-service product-composite-service; do
  P=$(grep -m1 "server.port" microservices/$s/src/main/resources/application.yml | cut -d: -f2 | tr -d " ")
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/ch04_$s.log 2>&1 &
done
sleep 45
```

Expected: ports 7000-7003 listening, composite healthy.
Actual:

```
*:7000   *:7001   *:7002   *:7003
{"status":"UP"}   HTTP=200
```

### The aggregation call

```sh
curl -s localhost:7000/product-composite/1
```

Expected: one product, three recommendations, three reviews, and a
`serviceAddresses` block naming every service that contributed.
Actual (HTTP 200):

```json
{"productId":1,"name":"name-1","weight":123,
 "recommendations":[{"recommendationId":1,"author":"Author 1","rate":1},
                    {"recommendationId":2,"author":"Author 2","rate":2},
                    {"recommendationId":3,"author":"Author 3","rate":3}],
 "reviews":[{"reviewId":1,"author":"Author 1","subject":"Subject 1"},
            {"reviewId":2,"author":"Author 2","subject":"Subject 2"},
            {"reviewId":3,"author":"Author 3","subject":"Subject 3"}],
 "serviceAddresses":{"cmp":"codespaces-59c529/127.0.0.1:7000",
                     "pro":"codespaces-59c529/127.0.0.1:7001",
                     "rec":"codespaces-59c529/127.0.0.1:7002",
                     "rev":"codespaces-59c529/127.0.0.1:7003"}}
```

Four services, four addresses in the response — the aggregate is assembled from
three separate calls and the response says so.

### The book's own end-to-end suite

```sh
HOST=localhost PORT=7000 ./test-em-all.bash
```

Expected: every assertion OK, including the negative cases.
Actual — all OK:

```
Wait for: http://localhost:7000/product-composite/1... Ok
Test OK (HTTP Code: 200)                    productId 1, 3 recommendations, 3 reviews
Test OK (HTTP Code: 404, "No product found for productId: 13")
Test OK (HTTP Code: 200)                    productId 113, 0 recommendations, 3 reviews
Test OK (HTTP Code: 200)                    productId 213, 3 recommendations, 0 reviews
Test OK (HTTP Code: 422, "Invalid productId: -1")
Test OK (HTTP Code: 400, "Type mismatch.")  /product-composite/invalidProductId
```

The last three are the valuable ones: the service distinguishes a missing
entity (404), a semantically invalid id (422), and a malformed one (400). That is
error handling, not just plumbing.

## Problems encountered

| What happened | Cause |
|---|---|
| `curl /product/1` returned 404 | Wrong path. The book's route is `/product-composite/1`. My error, not the code's. |
| I first reported "the composite has no controller and no HTTP endpoint" | **Wrong, and it was my search that was wrong.** `@RestController` is declared *on* `ProductCompositeServiceImpl` rather than in a separate controller class, so `ls` and a grep for a controller file looked for a file that never existed. I stated absence before testing it. |
| Ch03's `cd api/ && ./gradlew` did not apply here | Ch04's Gradle root is `Chapter04/` itself; Ch03's was `Chapter03/2-basic-rest-services/`. The layout differs between chapters in this repo. |

**The middle row is the point of this file.** The 404 was my wrong URL; the
"no endpoint" claim was my wrong search. Both would have been caught by running
the book's own `test-em-all.bash` before writing anything. That script exists
precisely so the reader does not have to guess the routes.

## Fixes applied

None. Ch04 built and ran unchanged — no source fix was required, only the
Java 11 toolchain decision carried over from Ch03.

## Benefit of this code run

A four-service system with real aggregation and real error handling, verified by
the book's own suite rather than by my assumptions: three concurrent upstream
calls merged into one response, and 404/422/400 all distinguished correctly.
That is the shape every later chapter's composite service reuses.

## Business value & opportunities

The composite-aggregation pattern is what lets a frontend make one call instead
of three, which is the difference between a responsive UI and a chatty one. The
demonstrated capability — three backends merged with per-service addresses and
typed error codes — is the core of any API gateway or BFF layer an organisation
deploys to keep microservice fan-out off the client.

## Still unverified (this chapter)

- `docker-compose.yml` was not started; every service ran as a bare JVM on the
  host, so nothing tests the Compose networking or the `docker` Spring profile.
- The `spring.profiles: docker` profile in `application.yml` (ports 8080, hosts
  by service name) was never activated.
- Tests were skipped (`-x test`); `test-em-all.bash` is the only verification
  that ran, and it exercises the HTTP surface rather than unit-level behaviour.
- Only the composite's endpoints were probed. The three core services were never
  queried directly in this chapter.
