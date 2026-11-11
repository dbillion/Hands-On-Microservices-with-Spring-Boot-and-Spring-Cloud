# Chapter 13 — Resilience: Resilience4j retry and circuit breaker

## Summary

Ch13 adds fault tolerance to the composite's call to the product service. A
`?delay=<sec>` parameter is threaded through the composite into the product
service so a call can be made artificially slow, the composite wraps the product
call in a `@CircuitBreaker(name="product")` annotated fallback, and a retry
backend retries it. Configuration comes from the config server as in ch12
(`resilience4j.circuitbreaker.backends.product`, `resilience4j.retry.backends.product`).

The claim the chapter makes is that when the product dependency is slow or
unavailable, the composite fails fast, returns a cached fallback, and then
recovers by half-opening. That claim was verified by driving the breaker through
its entire state machine.

## Verdict: PASS — full stack runs; the breaker's full state machine verified

The book's own `test-em-all.bash` runs **51 assertions, zero failures, ending
`End, all tests OK`**, including its complete `testCircuitBreaker()` sequence.
The earlier standalone probe of the same assertions (24 of them, hand-copied)
passed 21; the three it missed were a ring-buffer warm-up difference, not a
defect — see §Ring buffer, an order-dependent assertion.

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, standardLinux32gb, 4 cores / 16 GB RAM / 32 GB storage |
| Java | `openjdk version "11.0.25" 2024-10-15 LTS` (via sdkman) |
| Gradle | `gradle-5.6.4-bin.zip` |
| Spring Boot / Cloud | 2.3.2.RELEASE / Hoxton.SR6 |
| Docker | containers `ch7kafka ch7rabbit ch7zk ch6mysql ch6mongo` running |

Infrastructure was inherited from ch12 (Mongo, MySQL, RabbitMQ, Kafka) and did
not need recreating.

## Runbook — repeat the whole chapter from scratch

```sh
# 0. infrastructure — carried forward from ch12, verify rather than assume
sudo docker ps --format '{{.Names}}'          # ch7kafka ch7rabbit ch7zk ch6mysql ch6mongo
ss -ltn | grep -E ':(3306|27017|9092|5672)'   # all listening

# 1. free every port the stack owns (ch12's lesson — 8761 included)
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do fuser -k $p/tcp; done
sleep 12
ss -ltn | grep -cE ':(7000|7001|7002|7003|8443|8761|9999|8888)'   # must print 0

# 2. build
cd Chapter13 && source /usr/local/sdkman/bin/sdkman-init.sh
./gradlew build
```
Expected `BUILD SUCCESSFUL`; actual `BUILD SUCCESSFUL in 1m 44s`,
`49 actionable tasks: 49 executed`.

```sh
# 3. start the stack — note BOTH credential sets, and the native profile
cd Chapter13
export ENCRYPT_KEY=my-very-secure-encrypt-key            # Spring reads encrypt.key
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/c13cfg.log 2>&1 &
sleep 40
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd   # what the clients send
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu13.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth13.log 2>&1 &
sleep 35
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw13.log 2>&1 &
sleep 35
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c13_$s.log 2>&1 &
done
sleep 90
```

**Every script that starts a service must repeat `CONFIG_SERVER_USR`/`PWD`
itself.** An SSH shell does not carry exports into a second script; a service
started without them cannot fetch configuration and loops in `spring-retry`
forever, printing `Fetching config from server at : http://localhost:8888` with
growing backoff and never reaching `Started`. This cost a full run here.

```sh
# 4. verify the stack whole before testing the breaker
ss -ltn | grep -cE ':(7000|7001|8761|8443|9999|8888)'     # 7
grep -c 'Started.*Application' /tmp/c13_*.log             # 1 each
curl -sk -u u:p localhost:8761/eureka/apps \
  -H 'Accept: application/json' | grep -oE '"name":"[A-Z-]+"' | sort -u
```
Actual: `AUTH-SERVER GATEWAY PRODUCT PRODUCT-COMPOSITE RECOMMENDATION REVIEW`.

Composite health before any fault: overall `UP`, and the chapter's own
instrument present — `circuitBreakers: UP`.

```sh
# 5. the book's own breaker test — needs only ONE substitution
cd Chapter13
sed 's|\$EXEC wget product-composite:8080\([^ ]*\) -qO -|curl -sf http://localhost:7000\1|g' \
  test-em-all.bash > test-em-all-jarrun.bash
HOST=localhost PORT=8443 bash test-em-all-jarrun.bash
```
Expected `End, all tests OK`; actual `End, all tests OK: Wed Nov 11 05:46:26 UTC 2026`
with 51 `Test OK` lines and no `FAILED`/`ABORT`.

The only thing to change: the book's `EXEC` is
`docker run --rm -it --network=my-network alpine` and it addresses
`product-composite:8080`, both of which exist only under `docker-compose`.
Running from jars, `curl -sf http://localhost:7000` serves the same health and
events endpoints on the composite's own port. Everything else, including
`HOST=localhost PORT=8443` (the book's own defaults), is used verbatim.

**Ports differ by purpose and getting this wrong produces HTTP 000.** The
composite serves plain **HTTP on 7000**; the gateway serves **HTTPS on 8443** and
is the OAuth resource server. `https://localhost:7000/...` fails the TLS
handshake and every curl returns `000`, which looks like a dead service rather
than a wrong protocol. Bearer tokens also come from the gateway: the auth server
on 9999 returns an **empty body** for the password grant, while 8443 returns a
JWT. Use the gateway for calls *and* tokens; use the composite directly only for
its `/actuator/health` and `/actuator/circuitbreakerevents`.

## What the breaker actually did (the chapter's claim, verified)

```
state before any slow call ................................. CLOSED
slow call 1   (?delay=3) -> HTTP 500, "Did not observe any item or terminal
               signal within 2000ms"
slow call 2   (?delay=3) -> HTTP 500, same message
slow call 3   (?delay=3) -> HTTP 500, same message
slow call 4   while OPEN -> HTTP 200, name "Fallback product2"     (fail fast)
normal call   while OPEN -> HTTP 200, name "Fallback product2"     (fallback)
/product-composite/13 while OPEN -> HTTP 404, "Product Id: 13 not found in
               fallback cache!"
+10s later ............................................... HALF_OPEN
normal call 1 -> HTTP 200, name "product name C"
normal call 2 -> HTTP 200, name "product name C"
normal call 3 -> HTTP 200, name "product name C"
after those three .......................................... CLOSED
circuitBreakerEvents[-3] ............................... CLOSED_TO_OPEN
circuitBreakerEvents[-2] ............................ OPEN_TO_HALF_OPEN
circuitBreakerEvents[-1] ........................... HALF_OPEN_TO_CLOSED
```

The timeouts are real, not configured away: the config server's
`product-composite.yml` carries `app.product-service.timeoutSec: 2`, and the slow
call's `?delay=3` exceeds it, so the `@TimeLimiter`-style 2000ms bound fires and
the composite answers 500 with the timeout message. When the breaker is open the
same slow call returns **200 with the fallback body** — the dependency is not
even contacted.

## Ring buffer — an order-dependent assertion in the book's own test

A standalone re-run of the book's breaker assertions against a **freshly
restarted** composite passed 21 of 24. The three it missed were not failures of
resilience but of warm-up: with the config server's
`ringBufferSizeInClosedState: 5`, a breaker with an empty buffer needs **five**
calls before it evaluates and opens, so the 4th slow call still timed out with a
500 instead of failing fast with the fallback.

The book's own suite opens the breaker after **three**. The difference is the ~20
earlier assertions in `test-em-all` (the 404, 422, 400, 401, 403 and read
paths), which pre-populate the 5-slot buffer before `testCircuitBreaker()`
starts. Run in the book's sequence it passes 51/51; run cold it does not.

This is worth knowing before "fixing" anything: `testCircuitBreaker()` is
**order-dependent**, and a re-run that isolates it can fail while the chapter is
correct. Do not read a cold re-run failure as a defect in the resilience
configuration.

## Benefit of the code run

The composite now degrades instead of failing. With the product dependency slow,
the aggregate returns in milliseconds with a cached product instead of hanging
for the timeout; with the dependency gone, the composite still answers from its
fallback cache and recovers automatically once it returns. The same
configuration, driven from the ch12 config server, tuned the timeout and the
buffer.

## Business value & opportunities

1. **A slow dependency no longer takes the whole aggregation down.** Before this,
   one hung product call timed out the entire composite. After it, the composite
   answers from cache — the user-visible difference between a degraded page and
   an error.
2. **Automatic recovery without an operator.** The half-open state means a
   transient outage self-heals; no restart, no manual breaker reset, and no page
   for a dependency that recovered on its own.
3. **The failure mode is now configurable and observable.** Timeout, retry count
   and buffer size are config-server values, and
   `/actuator/circuitbreakerevents/product/STATE_TRANSITION` reports every
   transition. A resilience policy can be tuned in production without a rebuild,
   and its behaviour is auditable after the fact.

## Recommendations

- Restart every service through a script that **exports the config credentials
  itself**. Two scripts sharing a stack must both carry
  `CONFIG_SERVER_USR`/`PWD`, or the second one leaves a service looping in
  `spring-retry` and the whole test reads as a dead composite.
- When a curl returns `000`, check the protocol before the process.
- Get the bearer token from the gateway, not the auth server directly.
- Read the book's own test before writing your own: `test-em-all.bash` already
  contains the chapter's verification (`testCircuitBreaker()`), and the only
  change needed to run it outside Compose is the `$EXEC wget` substitution.
- Do not conclude a resilience defect from a cold, isolated re-run of an
  order-dependent breaker test.

## Still unverified (this chapter)

- `docker-compose up` was never run; every service was started from a jar, so
  Compose build/up paths and the `my-network` container path are unexercised.
- Retry behaviour was configured (`resilience4j.retry.backends.product`,
  `maxRetryAttempts: 3`) and present in the source, but no assertion counted
  retry attempts — the breaker's slow-call path masks the retry count.
- No coverage report.

