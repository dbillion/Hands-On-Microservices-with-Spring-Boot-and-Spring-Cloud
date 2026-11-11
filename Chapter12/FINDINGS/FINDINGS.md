# Chapter 12 — Centralised configuration with Spring Cloud Config

> **Supersedes `FINDINGS-attempt1-superseded.md`.** That version recorded the
> chapter as `PARTIAL` on the false premise that `CONFIG_SERVER_USR`,
> `CONFIG_SERVER_PWD` and `CONFIG_SERVER_ENCRYPT_KEY` were "not in the
> repository". They are, in `Chapter12/.env`, which `ls` without `-a` does not
> show. It is retained because the correction is more useful than the erasure.

## Summary

Ch12 externalises service configuration. A new `spring-cloud/config-server`
module (port 8888) serves property files from a `config-repo/` directory, and
the four microservices lose their `application.yml` entirely — each carries only
a `bootstrap.yml` that fetches everything from the server. `spring-retry` retries
the config fetch and `failFast: true` makes a client refuse to start without it.
Sensitive values (the Eureka password, the RabbitMQ password) are stored
`{cipher}`-encrypted and are decrypted by the server on serve, keyed by an
operator-supplied `ENCRYPT_KEY`.

## Verdict: PASS — full stack runs on externalised configuration

The config server serves eight property files over authenticated HTTP Basic;
all six services (four microservices, eureka, gateway, auth-server) start with
no local config, register in Eureka, aggregate a cross-service call, process
messages end to end, and the book's own suite ends `End, all tests OK` including
the 404 / 422 / 400 / 401 / 403 error paths.

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, standardLinux32gb, 4 cores / 16 GB RAM / 32 GB storage |
| Java | `openjdk version "11.0.25" 2024-10-15 LTS` (via sdkman) |
| Gradle | `gradle-5.6.4-bin.zip` (from `gradle-wrapper.properties`) |
| Spring Boot / Cloud | 2.3.2.RELEASE / Hoxton.SR6 |
| Docker | 29.9.2-2 |

The codespace had **rebooted** before this run: `/tmp` was empty, every
container (`ch6mongo`, `ch6mysql`, `ch7zk`, `ch7kafka`, `ch7rabbit`) was
`Exited`, and no port was listening. Containers were **recreated**, not started —
a recycled machine has no container state to resume.

## Runbook — repeat the whole chapter from scratch

```sh
# 0. infrastructure (recreated after codespace reboot)
sudo docker rm -f ch6mongo ch6mysql ch7zk ch7kafka ch7rabbit
sudo docker run -d --name ch6mongo -p 27017:27017 mongo:3.6.9 mongod --smallfiles
sudo docker run -d --name ch6mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpwd -e MYSQL_DATABASE=review-db \
  -e MYSQL_USER=user -e MYSQL_PASSWORD=pwd mysql:5.7
sudo docker run -d --name ch7zk -p 2181:2181 -e ZOOKEEPER_CLIENT_PORT=2181 \
  confluentinc/cp-zookeeper:5.5.0
sudo docker run -d --name ch7rabbit -p 5672:5672 -p 15672:15672 \
  rabbitmq:3.8-management-alpine
sudo docker run -d --name ch7kafka -p 9092:9092 --link ch7zk:zookeeper \
  -e KAFKA_ZOOKEEPER_CONNECT=zookeeper:2181 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
  -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  confluentinc/cp-kafka:5.5.0
```

Expected: five containers running, ports 3306/27017/9092/5672/2181 listening.
Actual: `containers: ch7kafka ch7rabbit ch7zk ch6mysql ch6mongo`, ports listening
`3306=2 27017=2 9092=2 5672=2 2181=2`, `mysql ready for connections: 2`.

```sh
# 1. credentials — they are in the repo, in Chapter12/.env
cat Chapter12/.env
# CONFIG_SERVER_ENCRYPT_KEY=my-very-secure-encrypt-key
# CONFIG_SERVER_USR=dev-usr
# CONFIG_SERVER_PWD=dev-pwd
```

**This is the step the previous run got wrong.** It recorded the credentials as
"not in the repository" and left the chapter `PARTIAL`. They are present, in
`Chapter12/.env` — a dotfile that `ls` without `-a` does not show and
`docker-compose` loads automatically.

```sh
# 2. build
cd Chapter12
source /usr/local/sdkman/bin/sdkman-init.sh
./gradlew build
```

Expected `BUILD SUCCESSFUL`. Actual (warm daemon): `BUILD SUCCESSFUL in 50s`,
`49 actionable tasks: 49 up-to-date`. See §Clean build for the from-source run.

```sh
# 3. config server — native profile, user store, and the CORRECT encrypt key
cd Chapter12
export ENCRYPT_KEY=my-very-secure-encrypt-key      # NOT CONFIG_SERVER_ENCRYPT_KEY
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar \
  > /tmp/cfg12.log 2>&1 &
sleep 40
```

Expected: `Started ConfigServerApplication`, port 8888 listening.

The `native` profile must be active or the server defaults to **git** and aborts:
"If you are using the git profile, you need to set a Git URI." It is in no file,
so `SPRING_PROFILES_ACTIVE=native` is part of the path that works.

The server's `SecurityConfig` requires `httpBasic` on every request but declares
no user store of its own, so it falls back to a generated password unless
`SPRING_SECURITY_USER_NAME`/`_PASSWORD` are given. These must match what the
clients' `bootstrap.yml` sends as `CONFIG_SERVER_USR`/`CONFIG_SERVER_PWD`.

Verified auth behaviour:
```
    no credentials        -> HTTP=401
    dev-usr / dev-pwd     -> HTTP=200
    wrong password        -> HTTP=401
```

Verified decryption (real words, not hex):
```
    "app.eureka-password":"p"
    "spring.rabbitmq.password":"guest"
```
Positive control: `POST /decrypt` with the cipher returns `p`.

```sh
# 4. eureka, auth-server, gateway, then the four clients
cd Chapter12
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu12.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth12.log 2>&1 &
sleep 35
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw12.log 2>&1 &
sleep 35
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c12_$s.log 2>&1 &
done
sleep 90
```

Ports come from `config-repo/*.yml` (7000/7001/7002/7003, 9999, 8443) because
the services carry no local `application.yml` — the point of the chapter.

```sh
# 5. the book's own suite
bash test-em-all.bash
```

Expected: `End, all tests OK`. Actual: `End, all tests OK: Wed Nov 11 05:04:56 UTC 2026`.

Verified after the final restart:
```
    eureka registry: AUTH-SERVER GATEWAY PRODUCT PRODUCT-COMPOSITE RECOMMENDATION REVIEW
    composite health overall: UP
    discoveryClient services: [gateway, auth-server, product, review, recommendation, product-composite]
    rabbit: UP
    per-service: Started 1, eureka-401 0, registration-failed 0  (all four)
```

Suite assertions against the freshly built jars:
```
Test OK (HTTP Code: 200) / 2 / 3 / 3     # create + message processing
Test OK (actual value: 2) / 3 / 3
Test OK (HTTP Code: 200) / 114 / 0 / 3
Test OK (HTTP Code: 200) / 214 / 3 / 0
Test OK (HTTP Code: 404, "No product found for productId: 14")
Test OK (HTTP Code: 422, "Invalid productId: -1")
Test OK (HTTP Code: 400,  "Type mismatch.")
Test OK (HTTP Code: 401)                 # no token — ch11 security intact
Test OK (HTTP Code: 200)                 # valid token
Test OK (HTTP Code: 403)                 # reader token on a writer route
End, all tests OK
```

## Clean build

The warm-daemon run proves nothing about compilation, so `./gradlew clean build`
was run for the runbook:

```
> Task :spring-cloud:gateway:test
> Task :spring-cloud:gateway:check
> Task :spring-cloud:gateway:build

BUILD SUCCESSFUL in 1m 55s
59 actionable tasks: 59 executed
```

`59 executed` (not `up-to-date`) means every task ran from source: this is real
compilation evidence, not a daemon cache hit. It was not followed by a third
suite run; the suite results recorded above are from the run immediately before
it.

## Problems encountered

| What happened | Cause |
|---|---|
| First attempt: suite 0/0, `Wait for ... Give up` after 99 retries | Config server served `{cipher}` verbatim; wrong env var name for the encrypt key |
| `AmqpAuthenticationException: ACCESS_REFUSED - Login was refused using authentication mechanism PLAIN` on 127.0.0.1:5672 | Same cause — the undecrypted hex was used as the RabbitMQ password |
| Composite health `DOWN`, components `binders: DOWN`, `rabbit: DOWN` | Same cause, surfaced through the binder health indicator |
| `/product-composite/1` without a token -> 401 | Correct behaviour — ch11's OAuth2 resource server is still on the composite |
| Second attempt: suite still 0/0 | I freed ports 7000-7003 and 8443 but **not 8761**. The Eureka process from attempt 1 survived holding the cipher-hex password, while clients now correctly sent `p`, so every registration 401'd |
| Gateway log: `Load balancer does not contain an instance for the service product-composite` | Consequence of the above — no service ever registered in Eureka |
| `RetryableEurekaHttpClient: Request execution failure with status code 401` | Same cause, from the clients' side |
| Suite could not acquire a token (`token acquired: NO`) | Stack was half-wired; resolved once registration worked |

## Fixes applied

| Fix | How verified |
|---|---|
| `CONFIG_SERVER_ENCRYPT_KEY` -> `ENCRYPT_KEY` | Config server serves `"app.eureka-password":"p"` and `"spring.rabbitmq.password":"guest"` instead of hex; `POST /decrypt` returns `p`; all `ACCESS_REFUSED` counts drop to 0 |
| Free **all** ports the stack owns (added 8761, 9999, 8888) before restarting any of it | After the kill, `ports still bound: 0`; fresh Eureka accepts `u:p` -> 200 and rejects `u:wrong` -> 401; registrations show `eureka-401: 0`, `registration-failed: 0` |

Run-time flags, not source patches: `SPRING_PROFILES_ACTIVE=native`,
`ENCRYPT_KEY`, `SPRING_SECURITY_USER_*`, `CONFIG_SERVER_USR/PWD`. The
checked-in code has no defect; the chapter's inputs were simply never supplied.

## Benefit of the code run

The same artefacts now run with **no local configuration at all** — every
property arrives from one authenticated server, and encrypted secrets are
decrypted server-side with an operator key. A configuration change is a commit to
`config-repo` rather than a rebuild.

## Business value & opportunities

1. **One build promoted through every environment.** The precondition for
   dev -> staging -> production promotion with only credentials changing is
   exactly this externalisation; the chapter demonstrates it working end to end,
   including encrypted secret handling.
2. **Secrets leave the artefacts.** `{cipher}` values in `config-repo` are inert
   without `ENCRYPT_KEY`, so a leaked repo or image no longer leaks the Eureka
   or RabbitMQ passwords. The key lives only in the operator's environment.
3. **Centralised audit and change history.** Config changes become commits with
   authorship and review, instead of edits across eight `application.yml` files
   on four hosts.

## Recommendations

- Before claiming a value is absent from a repo, check dotfiles — `ls` without
  `-a` hides `.env`, which is where this chapter's three required variables live.
  The previous run lost a whole chapter to this.
- When a Spring component requires "configuration you must supply", grep the
  chapter directory for `.env` and for `docker-compose` before writing a gap.
- Free **every** port the stack owns before restarting any of it. Restarting a
  subset leaves stale processes holding old credentials and produces 401s that
  look like code defects.
- Read the component's own `SecurityConfig` to learn where its user store comes
  from; `SPRING_SECURITY_USER_NAME/_PASSWORD` is the Spring Boot 2 spelling for
  "in-memory user".

## Still unverified (this chapter)

- `docker-compose.yml` was never started as a file; all three credentials were
  supplied by hand from `.env`, so the Compose path itself is unexercised.
- Compose image builds (`build:`) were not exercised — services ran from jars.
- No coverage report was produced.
- The suite was run twice against the same jar set.

