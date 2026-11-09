# Chapter 10 — Spring Cloud Gateway in front of Eureka discovery

## Summary

Ch10 does two structural things. It **removes the health-aggregation code from
the composite** — `getProductHealth()`, `getReviewHealth()`,
`getRecommendationHealth()` and the private `getHealth()` all disappear from
`ProductCompositeIntegration` — and it **adds a `spring-cloud/gateway` module**:
a Spring Cloud Gateway that fronts the four services and routes to them through
Eureka's discovery locator rather than hard-coded ports.

## Runbook

**Environment actually used:** codespace `redesigned-guide-9j4x6q96qwjcp7p`.
Versions pasted, not assumed:

```
openjdk version "11.0.25" 2024-10-15 LTS
Gradle 5.6.4 | Spring Boot 2.3.2.RELEASE | Spring Cloud Hoxton.SR6
org.springframework.cloud:spring-cloud-starter-gateway
spring-cloud-starter-netflix-eureka-client
```

### Build — one invocation, both new modules

`settings.gradle` gains `include ':spring-cloud:gateway'`, so the gateway is part
of the same multi-module build (36 tasks, up from ch09's 31):

```sh
source /usr/local/sdkman/bin/sdkman-init.sh
cd Chapter10
./gradlew build
```

Expected: `BUILD SUCCESSFUL`.
Actual: `BUILD SUCCESSFUL in 2m 2s`, 36 actionable tasks.

### Start order matters

Eureka must be up before the gateway and the services register:

```sh
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw.log 2>&1 &
sleep 30
for s in product-service review-service recommendation-service product-composite-service; do
  P=$(grep -m1 "server.port" microservices/$s/src/main/resources/application.yml | cut -d: -f2 | tr -d " ")
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/$s.log 2>&1 &
done
```

Expected: all six `Started`, gateway on **8080**, composite on 7000.
Actual: eureka 1, gateway 1, and 1 for each of the four services.

### Verify the gateway routes, don't assume it does

```sh
curl -s localhost:8080/actuator/gateway/routes
```

Actual route for the composite:

```
route_id:    product-composite
predicate:   Paths: [/product-composite/**], match trailing slash: true
uri:         lb://product-composite
```

`lb://` means the gateway resolves the target **through Eureka**, not a fixed host
and port. The load balancer log confirms it resolved a real instance:

```
DynamicServerListLoadBalancer for client product-composite initialized:
  ... Servers=[ffa0cc3a-c532-4895-885e-860b7ae14e32.internal.cloudapp.net:7000]
```

### The call through the gateway

```sh
curl -s localhost:8080/product-composite/1
```

Returns 404. **This 404 is not a gateway fault and not an Eureka fault** — it is
the correct business answer, and the three logs prove the whole chain ran:

```
gateway:  tag(routeId=product-composite) tag(routeUri=lb://product-composite)
          tag(httpStatusCode=404) tag(status=NOT_FOUND)
composite: Returning HTTP status: 404 NOT_FOUND for path: /product-composite/1,
           message: No product found for productId: 1
```

Product 1 does not exist in this run. The chapter's own suite drives the event
flow, which creates products **2, 114 and 214**, not 1. The request was routed
and load-balanced through Eureka, delivered to the composite, and the composite
answered truthfully that the id is absent.

The working call is the one the suite makes:

```
Test OK (HTTP Code: 200)      productId 2,   3 recs, 3 revs
Test OK (HTTP Code: 200)      productId 114, 0 recs, 3 revs
Test OK (HTTP Code: 200)      productId 214, 3 recs, 0 revs
Test OK (HTTP Code: 404)      "No product found for productId: 13"
Test OK (HTTP Code: 422)      "Invalid productId: -1"
Test OK (HTTP Code: 400)      "Type mismatch."
TOTAL: Test OK=24  FAILED=0
```

## Problems encountered

| What happened | Cause |
|---|---|
| I first reported "the gateway returns 404 — real finding" | **Wrong, for the seventh time this session.** A 404 from an HTTP probe is not evidence of a routing fault. Reading the gateway's route tags, the load balancer's resolved server list and the composite's own log line showed the request was correctly routed, load-balanced through Eureka and correctly answered. |
| Ch09's earlier `/product-composite/1` 404 | Same root cause: product 1 absent. My probe chose an id that the event flow never creates. |

**The pattern across all seven of these:** I probe a single endpoint, get a
non-200, and write it up as a defect before reading the service's own log. The
fix that works every time is to read the *provider's* log line for the same
request before claiming a routing or wiring failure.

## Fixes applied

None to source. Ch10 built and ran unchanged.

## Benefit of this code run

The four services are now fronted by a single entry point that resolves its
targets through a registry rather than enumerated ports — verified by reading the
gateway's own route table showing `uri: lb://product-composite`, and its load
balancer having resolved a live instance, plus the composite's log confirming the
request arrived. Composite health aggregation is now the gateway's job, not
embedded in the business service.

## Business value & opportunities

An API gateway backed by service discovery is what removes per-client
configuration of instance addresses — new instances become routable without any
client or load-balancer change, which is the prerequisite for autoscaling and
zero-downtime deploys. This chapter's point is architectural: health and routing
concerns leave the service and live at the edge.

## Still unverified (this chapter)

- The book's `test-em-all.bash` was run against the composite on **7000**, not
  through the gateway. So its 24/24 proves the services, not the routing.
- Closing that gap required a separate manual probe, which I did and which now
  passes. Through the gateway on 8080:

```
:8080/product-composite/2   -> HTTP=200      (direct :7000 -> 200)
:8080/product-composite/114 -> HTTP=200      (direct :7000 -> 200)
:8080/product-composite/214 -> HTTP=200      (direct :7000 -> 200)
payload: {"productId":2,"name":"product name C","weight":300,
           "recommendations":[{"recommendationId":1,"author":"author 1",
           "rate":1,"content":"content 1"}, ...]}
```

Identical status codes and payloads through the gateway and direct, so Eureka
resolves and the gateway is transparent to the response.

Still genuinely unverified after that probe:
- No load test or multi-instance test, so gateway load **balancing across two
  instances** of the same service was never exercised (one instance per service).
- The gateway's other discovery-locator routes (`/eureka/**` UI proxying) and the
  `host_route_*` sample routes were never exercised.
- `docker-compose.yml` was not started as a file, so the `docker` profile and
  service-name hosts remain untested.
- No coverage report produced.
