# Chapter 12 — Centralised configuration with Spring Cloud Config

## Summary

Ch12 externalises service configuration. A new **`spring-cloud/config-server`**
module (port 8888) serves property files from a `config-repo/` directory, and the
four microservices lose their `application.yml` entirely — each now carries only a
`bootstrap.yml` that fetches everything from the server. `spring-retry` is added
so a client retries its config fetch, and `failFast: true` makes a client refuse
to start without its config.

## Verdict: PARTIAL

**The config server runs and serves. The four clients fetch it but cannot
authenticate, so none of the services start and the suite cannot run.**

This chapter is not verified and is not marked as such anywhere in this repo.

## Runbook

### Environment actually used

Codespace `redesigned-guide-9j4x6q96qwjcp7p`, `openjdk 11.0.25`, Gradle 5.6.4,
Spring Boot 2.3.2, Spring Cloud Hoxton.SR6, Docker 29.9.2-2.

### Build

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter12
./gradlew build
```

Expected `BUILD SUCCESSFUL`.
Actual: `BUILD SUCCESSFUL in 1m 44s`, **49 actionable tasks** (up from ch11's 41 —
the config-server module and its tests are new).

### Getting the config server to actually start — this is required

The book's server config sets only the location:

```yaml
spring.cloud.config.server.native.searchLocations: file:${PWD}/config-repo
```

It **never activates the `native` profile**. With no active profile Spring Cloud
Config Server defaults to **git**, and a git-backed server with no URI aborts at
boot:

```
If you are using the git profile, you need to set a Git URI in your configuration.
If you are using the native profile and have spring.cloud.config.server.bootstrap=true,
you need to use a composite configuration.
```

So the profile must be supplied at run time — it is not in any file:

```sh
cd Chapter12
SPRING_PROFILES_ACTIVE=native java -jar spring-cloud/config-server/build/libs/*.jar
```

Expected with 49-file `config-repo` present (`application.yml`, `auth-server.yml`,
`eureka-server.yml`, `gateway.yml`, `product-composite.yml`, `product.yml`,
`recommendation.yml`, `review.yml`).
Actual: `Started ConfigServerApplication`, port 8888 listening, healthy.

### Starting the clients

```sh
cd Chapter12
export CONFIG_SERVER_USR=<value> CONFIG_SERVER_PWD=<value>
java -jar microservices/product-composite-service/build/libs/*.jar   # etc.
```

**I could not do this successfully, and the reason is a missing input, not a code
defect.** `bootstrap.yml` authenticates with env-provided credentials:

```yaml
uri: http://${CONFIG_SERVER_USR}:${CONFIG_SERVER_PWD}@${app.config-server}:8888
failFast: true
retry: {initialInterval: 3000, multiplier: 1.3, maxInterval: 10000, maxAttempts: 20}
```

Those two variables plus `CONFIG_SERVER_ENCRYPT_KEY` are supplied **only by the
Docker Compose path**, which this run does not use:

```
docker-compose.yml:83:  - ENCRYPT_KEY=${CONFIG_SERVER_ENCRYPT_KEY}
```

The reason they cannot simply be looked up is that `config-repo/application.yml`
stores them encrypted:

```yaml
eureka-username: u
eureka-password: '{cipher}bf298f6d5f878b342f9e44bec08cb9ac00b4ce57e98316f030194a225fac89fb'
username: guest
password: '{cipher}17fcf0ae5b8c5cf87de6875b699be4a1746dd493a99d926c7a26a68c422117ef'
```

`{cipher}` is Spring Cloud Config's symmetric encryption, which requires
`ENCRYPT_KEY`. That key is not in the repository.

### What actually happened, and why I can claim it

| Step | Result | Evidence |
|---|---|---|
| Config server, native profile | **Works** | `Started ConfigServerApplication`, `8888: listening` |
| Client locates the server | **Works** | `Fetching config from server at : http://localhost:8888` |
| Client authenticates | **Fails — HTTP 401** | `HttpClientErrorException$Unauthorized: 401 : [no body]` |
| Client retries then dies | **20 attempts** | 20 `Fetching config` lines, `failFast: true` |
| Services started | **0 of 4** | `Started: 0` for all four, ports 7000-7003 free |
| Book's suite | **0 assertions** | 36 retries against `https://localhost:8443`, nothing listening |

The 401 is real and reproducible — an unauthenticated request to the config
server also returns 401. I do not know the correct credentials because they are
the encrypted values above, and I will not invent them.

## Problems encountered

| What happened | Cause |
|---|---|
| First run: suite scored 27/27 | **A false pass.** ch11's services were still running on 7000-7003 and 8443, so the suite exercised the *previous chapter's* stack. |
| Second run: suite scored 0/0 | Correct result now that the stale stack is gone, but for an incomplete reason. |
| Config server aborted at boot | `native.searchLocations` set without activating the `native` profile, so it defaulted to git with no URI. |
| Four clients exhausted 20 retries | 401 on the config server; the credentials are `{cipher}`-encrypted and need `ENCRYPT_KEY`. |
| Gateway/auth-server absent in the last run | I killed every java process to clear the stale stack and did not restart them. |

**The first run is the important one.** I nearly reported Chapter 12 as passing
on the strength of a suite that had never touched ch12 code. The tell was that
the services logged `Started: 0` while the suite reported 27 passes — I had to
check process start flags (`--server.port=...`, which ch10/ch11 scripts set and
ch12's does not) and port ownership to see it. **A suite result is only evidence
for the stack it actually hit.**

## Fixes applied

**None to source.** The chapter's failure is an environment input
(`CONFIG_SERVER_USR`/`CONFIG_SERVER_PWD`/`CONFIG_SERVER_ENCRYPT_KEY`), not a defect
in the checked-in code. Running the config server with
`SPRING_PROFILES_ACTIVE=native` is a run-time flag, not a fix.

## Benefit of this code run

Verified: a config server that serves eight property files and requires
authentication, and a client that correctly locates it, retries on failure, and
refuses to start silently without config. Not verified: any service actually
running on externalised configuration, which is the chapter's actual claim.

## Business value & opportunities

Centralised configuration is what lets the same artefacts run in every
environment with only credentials changing — the precondition for promoting one
build through dev, staging and production. This chapter's design is sound; it
requires an operator-supplied encryption key, which is the correct posture for
production secrets and the reason a local run needs the Compose path.

## Still unverified (this chapter)

- **No service started.** No composite, product, review or recommendation service
  ever bound a port under externalised configuration.
- **No credential was ever obtained.** All three env vars are `{cipher}`-encrypted
  or absent from the repo; I will not guess them.
- The suite did not run at all (0 assertions), so none of ch12's behaviour beyond
  config fetching is tested.
- `docker-compose.yml` was not started as a file — which is precisely the path
  that supplies `CONFIG_SERVER_ENCRYPT_KEY`, `CONFIG_SERVER_USR` and
  `CONFIG_SERVER_PWD`.
- The `docker` profile's `searchLocations: file:/config-repo` and the encrypted
  values' decryption were never exercised.
- No coverage report produced.
