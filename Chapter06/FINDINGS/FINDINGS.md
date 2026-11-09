# Chapter 06 — Persistence (Mongo + MySQL), MapStruct mapping, and the test suite

## Summary

Ch06 gives the core services actual storage. `product-service` moves to
**Spring Data MongoDB** (Plus MapStruct 1.3.1 for DTO↔entity mapping), while
`review-service` and `recommendation-service` move to **MySQL via JPA/Hibernate**
with `ddl-auto: update`. It also adds the first real unit/integration tests —
`PersistenceTests` and `MapperTests` — using `de.flapdoodle.embed.mongo` for an
in-process Mongo. `docker-compose.yml` gains `mongodb: mongo:3.6.9` and
`mysql: mysql:5.7` to back the running system.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB / 32 GB storage. Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS        <- default, carried from ch03
Gradle 5.6.4, Spring Boot 2.3.2.RELEASE
org.mapstruct:mapstruct 1.3.1.Final             <- new in ch06
de.flapdoodle.embed:de.flapdoodle.embed.mongo   <- new in ch06
mongo:3.6.9 and mysql:5.7 (Docker 29.9.2)        <- new in ch06
```

### Stand up the databases first (fixture-first)

`product-service` needs Mongo at `localhost:27017` (`spring.data.mongodb`), and
`review-service`/`recommendation-service` need MySQL at `localhost` with
`review-db`, user `user`, password `pwd` (`spring.datasource`). I ran the two
DBs as bare containers matching Compose's definitions exactly, rather than the
whole Compose stack:

```sh
sudo docker run -d --name ch6mongo -p 27017:27017 mongo:3.6.9 mongod --smallfiles
sudo docker run -d --name ch6mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpwd -e MYSQL_DATABASE=review-db \
  -e MYSQL_USER=user -e MYSQL_PASSWORD=pwd \
  --health-cmd "mysqladmin ping -uuser -ppwd -h localhost" \
  --health-interval 10s --health-retries 10 mysql:5.7
```

Expected: both `running`, mysql `healthy`.
Actual: `running` / `running health=healthy`.

Both 2018-era images still start cleanly on Docker 29.9.2 — the old image tags
are not a problem.

### Build **with** tests

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter06
./gradlew build
```

Note the command: ch03-ch05 all used `build -x test`. Ch06 does not, because
its own new tests are part of what the chapter is for.

Expected: `BUILD SUCCESSFUL` with the `test` tasks executed, embedded Mongo
started by flapdoodle inside `PersistenceTests`.
Actual: `BUILD SUCCESSFUL in 1m 28s`, 24 actionable tasks, all executed.

The build log shows `LocalContainerEntityManagerFactoryBean` and
`HikariDataSource` shutting down for review-service — real JPA wiring, not a
stub. The embedded Mongo tests ran without any of the usual flapdoodle download
failures.

### Run

```sh
for s in product-service review-service recommendation-service product-composite-service; do
  P=$(grep -m1 "server.port" microservices/$s/src/main/resources/application.yml | cut -d: -f2 | tr -d " ")
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/ch06_$s.log 2>&1 &
done
sleep 50
```

Expected: all four `Started`, no `APPLICATION FAILED TO START`.
Actual: `Started` count 1 for each of the four; no startup failure in any log.

### The book's own suite

```sh
HOST=localhost PORT=7000 ./test-em-all.bash
```

Expected: every assertion OK.
Actual: **20 assertions, 20 OK, 0 failures**, and not just the happy path:

```
200  productId 1,   3 recs, 3 revs
404  "No product found for productId: 13"
200  productId 113, 0 recs, 3 revs
200  productId 213, 3 recs, 0 revs
422  "Invalid productId: -1"
400  "Type mismatch." (/product-composite/invalidProductId)
```

Persistence is genuinely in play here — the composite answers come from Mongo
(product, recommendation counts) and MySQL (review counts), not from in-memory
seed data.

## Problems encountered

| What happened | Cause |
|---|---|
| First Ch06 attempt could not start the services | Ports 7000-7003 were held by Ch05's still-running jars. Freed with `fuser -k <port>/tcp` before starting (learned from ch05). |
| The services would not start without Mongo and MySQL | Correct behaviour, not a fault: ch06's `application.yml` points at real databases. This is the fixture-first case. |
| None in the build or tests | flapdoodle's embedded Mongo started normally on this toolchain. |

## Fixes applied

None to source. Ch06 built, tested and ran unchanged, given Java 11 plus the two
database containers.

## Benefit of this code run

The four services now store and retrieve real data through a polyglot backend —
document store for product, relational for review and recommendation — and the
chapter's own tests prove it, with 20/20 end-to-end assertions passing against
those live databases. That is the difference between a demo that answers from
hardcoded lists and one that answers from its own storage.

## Business value & opportunities

Polyglot persistence is the pragmatic default for microservice estates: documents
where the shape varies, rows where the queries are relational. The demonstrated
capability — one product id aggregated from a document store and two relational
tables, with the aggregate stable under every status code — is exactly the
behaviour a service needs before anyone will let it carry revenue data.

## Still unverified (this chapter)

- Only the composite's HTTP surface was asserted. The three core services'
  create/delete endpoints were not exercised directly.
- The full `docker-compose.yml` was not started — only the two database
  containers. So Compose networking, the `docker` Spring profile (ports 8080,
  service-name hosts) and the memory limits (`mem_limit: 350m`) were never
  tested.
- No data was written through the API before querying, so the assertions ran
  against whatever seed state the databases held.
- Coverage was not measured; `test` ran but no coverage report was produced.
