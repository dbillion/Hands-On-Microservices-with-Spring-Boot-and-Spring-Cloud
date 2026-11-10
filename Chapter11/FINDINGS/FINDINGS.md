# Chapter 11 — Security: Spring Security + OAuth2 resource server

## Summary

Ch11 turns the system into an authenticated one. The composite becomes an
**OAuth2 resource server** (`spring-boot-starter-security` +
`spring-security-oauth2-resource-server` + `spring-security-oauth2-jose`),
validating bearer JWTs against the authorization server's JWKS endpoint. A new
**`spring-cloud/authorization-server`** module issues those tokens, and the
gateway gets TLS (`edge.p12`, port **8443**) so the whole path is HTTPS.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`.

```
openjdk version "11.0.25" 2024-10-15 LTS
Gradle 5.6.4 | Spring Boot 2.3.2.RELEASE | Spring Cloud Hoxton.SR6
Docker 29.9.2-2 · Docker Compose v5.6.1
```

### The ch10→ch11 architecture change that explains the ports

Ch11 moves the front door. In ch10 the composite answered on HTTP **7000** and the
gateway on 8080. In ch11 the composite is still HTTP 7000 but is no longer the
entry point — **the gateway owns TLS on 8443** and the book's own
`test-em-all.bash` defaults to `PORT=8443`, not 7000:

```
9:#   HOST=localhost PORT=7000 ./test-em-all.bash
12:: ${PORT=8443}
```

Running the suite against 7000 in ch11 therefore fails at step one: the suite
probes `https://localhost:8443/actuator/health` and nothing answers.

### Infra, created not started

A **fresh codespace boot wipes `/tmp` and stops every container**, so
`docker start` finds nothing. Recreate from scratch:

```sh
docker run -d --name ch6mongo -p 27017:27017 mongo:3.6.9 mongod --smallfiles
docker run -d --name ch6mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpwd -e MYSQL_DATABASE=review-db \
  -e MYSQL_USER=user -e MYSQL_PASSWORD=pwd mysql:5.7
# + confluentinc/cp-zookeeper:5.5.0 (2181), confluentinc/cp-kafka:5.5.0 (9092),
#   rabbitmq:3.8-management-alpine (5672)
```

Kafka is substituted because the book's `wurstmeister/kafka:2.12-2.1.0` and
`wurstmeister/zookeeper:3.4.6` **cannot be pulled at all** — containerd v2.1
refuses their v1 manifest schema (`manifest.v1+prettyjws is no longer
supported`). Verified substitute starts and serves.

### Build

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter11
./gradlew build
```

Expected: `BUILD SUCCESSFUL`, now including the authorization-server module.
Actual: `BUILD SUCCESSFUL in 21s`, 41 actionable tasks.

### Start order, then verify security behaviour

```sh
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu11.log 2>&1 &
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar > /tmp/auth11.log 2>&1 &
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw11.log 2>&1 &
# then the four microservices on their application.yml ports
```

All six started (`Started: 1` each). Then the assertions that are the whole
point of the chapter:

```sh
curl -s -o /dev/null -w "%{http_code}\n" localhost:7000/product-composite/2
curl -H "Authorization: Bearer ***" ...        # invalid token
curl -s -o /dev/null -w "%{http_code}\n" localhost:7000/actuator/health
```

Expected: 401 without a token, 401 with an invalid one, 200 for health.
Actual:

```
no token                 -> HTTP=401
Bearer ***      -> HTTP=401
/actuator/health         -> HTTP=200
```

And through the TLS gateway, same behaviour — health public, product closed:

```
GET /actuator/health             -> HTTP=200
GET /product-composite/2 no token -> HTTP=401
```

### The book's own suite

```sh
HOST=localhost PORT=8443 ./test-em-all.bash
```

Expected and actual — **27 assertions, 0 failures**, including the security
assertions:

```
Wait for: curl -k https://localhost:8443/actuator/health ... DONE, continues...
200/200/200, productId 2 with 3 recs, 3 revs
404 "No product found for productId: 13"
114 with 0 recs, 3 revs  |  214 with 3 recs, 0 revs
422 "Invalid productId: -1"
400 "Type mismatch."
Test OK (HTTP Code: 401, )     <- unauthenticated request MUST be rejected
Test OK (HTTP Code: 200, )     <- bearer token accepted
Test OK (HTTP Code: 403, )     <- token accepted but role insufficient
```

The last three are the security chapter proving itself: 401 for no credentials,
200 for valid ones, 403 for valid credentials with the wrong role.

## Problems encountered

| What happened | Cause |
|---|---|
| First suite run: 0 assertions, endless retries | **I forced `PORT=7000`** while the suite's own default is 8443, so it probed a URL nothing served. |
| Token fetch returned length 0 | My `grep` for `client-id` in the auth-server's `application.yml` found nothing — the OAuth client is configured elsewhere, so I had no client secret to try. The suite obtains tokens its own way and passed regardless. |
| `docker start` found no containers | The codespace had rebooted, which stops containers and wipes `/tmp`. Recreated them instead. |

## Fixes applied

**None to source.** Ch11 built and ran unchanged, given Java 11, the
authorization server, the gateway with its keystore, and the four databases/brokers.

## Benefit of this code run

A four-service system behind an HTTPS gateway that rejects unauthenticated
requests and rejects wrong-role requests, verified by the book's own suite
asserting 401, 200 and 403. The security is enforced at the edge (gateway +
composite resource server), not merely configured — proven by status codes
returned to a real client.

## Business value & opportunities

Every organisation deploying services needs authentication at the edge and
authorization per endpoint. The demonstrated capability — a TLS front door that
distinguishes "no credentials" (401), "valid credentials" (200) and "valid
credentials, wrong role" (403) — is the difference between an API that is
usable and one that is merely reachable.

## Still unverified (this chapter)

- **No bearer token was ever successfully obtained by me.** My client-id grep
  found nothing in `application.yml`, so `access_token length: 0` on both grant
  types. The suite's own 200 and 403 assertions prove tokens exist and are
  accepted, but I did not capture or replay one myself.
- The composite's own `SecurityConfig` methods (`getProductHealth` is gone;
  the chapter's `hasAnyRole` rules) were verified only through status codes, not
  by inspection of which method guards which route.
- The authorization server's token endpoints were probed only for a token I
  failed to obtain; no introspection, expiry or refresh behaviour was tested.
- The gateway's `eureka-username`/`eureka-password` (`u`/`p`) were never
  exercised — the gateway registered without failing, but I did not verify it
  was rejected on bad credentials.
- `docker-compose.yml` was not started as a file, so the `docker` profile,
  service-name hosts and `mem_limit` remain untested.
- No coverage report produced.
