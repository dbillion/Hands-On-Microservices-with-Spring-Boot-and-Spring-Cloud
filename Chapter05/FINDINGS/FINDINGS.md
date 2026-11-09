# Chapter 05 — Swagger/OpenAPI documentation of the API

## Summary

Ch05 adds OpenAPI documentation to the composite service using
`io.springfox:springfox-boot-starter:3.0.0` and the `@Api`, `@ApiOperation` and
`@ApiResponses` annotations on the shared `api` module's
`ProductCompositeService` interface. The annotations live on the interface, so
the documentation is defined once in the shared module rather than duplicated
per service.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`,
4 cores / 16 GB / 32 GB storage. Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS        <- default, carried from ch03
Gradle 5.6.4, Spring Boot 2.3.2.RELEASE, Spring 5.2.8.RELEASE
io.springfox:springfox-boot-starter:3.0.0       <- new in ch05
```

### Build

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter05
./gradlew build -x test
```

Expected: `BUILD SUCCESSFUL`.
Actual: `BUILD SUCCESSFUL in 6s`, 16 actionable tasks.

### Run

```sh
for s in product-service review-service recommendation-service product-composite-service; do
  P=$(grep -m1 "server.port" microservices/$s/src/main/resources/application.yml | cut -d: -f2 | tr -d " ")
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/ch05_$s.log 2>&1 &
done
sleep 42
```

Expected: four services up on 7000-7003, composite healthy despite springfox.
Actual: `Started ProductCompositeServiceApplication` present in the composite log,
zero `documentationPluginsBootstrapper` failures.

### Verify the documentation, not just the port

```sh
curl -s -o /dev/null -w "%{http_code}" localhost:7000/v2/api-docs
curl -s -o /dev/null -w "%{http_code}" localhost:7000/v3/api-docs
curl -s -o /dev/null -w "%{http_code}" localhost:7000/swagger-ui/
curl -s localhost:7000/v2/api-docs | jq -r '.paths | to_entries[] | "\(.key) \(.value.get.summary)"'
```

Expected: all three endpoints return 200, and the composite path appears with the
summary text from `@ApiOperation`.
Actual:

```
/v2/api-docs   -> 200
/v3/api-docs   -> 200
/swagger-ui/   -> 200
/product-composite/{productId} | Returns a composite view of the specified product id
```

The summary string resolving means the annotation from the shared `api` module
reached the generated spec — the documentation is real, not just a live endpoint.

### The book's own suite

```sh
HOST=localhost PORT=7000 ./test-em-all.bash
```

Expected: every assertion OK.
Actual: **17 Test OK, 0 failures.** (My first probe annotated this as "14 = all
pass" — that number was a guess, written before I counted. It was wrong.)

## Problems encountered

| What happened | Cause |
|---|---|
| Composite failed to start: `Port 7000 was already in use` | **Ch04's jars were still running** from the previous chapter. My test was invalid, not the code. |
| SSH session died with exit 255 | `pkill -f "product-service"` matched the remote shell's own command line, so it killed its own parent. The patterns were substrings of the command being run. |
| Then had to free the ports | Used `fuser -k $p/tcp` per port (7000-7003) instead of `pkill`. No self-match. |

**The middle row matters for every later chapter.** Any `pkill -f <name>` where
the remote command line also contains that name will kill the shell. The fix is
either `fuser -k <port>/tcp` or the bracket-regex trick (`pkill -f 'pr[o]duct'`)
so the pattern text does not match itself.

### A trap worth naming, because it is the classic springfox failure and it did not happen

`springfox-boot-starter:3.0.0` is widely reported to break with the
`Failed to start bean 'documentationPluginsBootstrapper'` error on Spring Boot
2.6+ and on Java 17+. Ch05 runs Spring Boot 2.3.2 on Java 11, and the failure
does **not** occur — I checked the log for it specifically and the count is zero.
The chapter's own code is fine on this toolchain. Anyone who bumps Spring Boot
before running the back half of this book should expect that error.

## Fixes applied

None to source. Ch05 built and ran unchanged.

## Benefit of this code run

One composite endpoint fully documented in a machine-readable spec, with the
annotation text visible in the generated `api-docs` — verified by extracting the
actual path and summary from the JSON rather than by trusting the 200.

## Business value & opportunities

An OpenAPI spec generated from code is what makes client SDKs, API gateways,
contract tests and developer portals possible without maintaining a separate
hand-written document that drifts. The demonstrated capability — the spec's
content derived from annotations shared in a common module — is how a
multi-service estate keeps its public contract synchronised with its
implementation.

## Still unverified (this chapter)

- Only the composite service was probed for Swagger endpoints; the three core
  services expose `api-docs` too but were never checked.
- The generated spec's placeholder metadata ("Sample API", "me@mail.com",
  "My") is springfox's default and was never replaced in `application.yml` —
  no effort was made to author real API metadata.
- `docker-compose.yml` and the `spring.profiles: docker` profile were not used.
- Tests skipped (`-x test`); `test-em-all.bash` is the only verification run.
