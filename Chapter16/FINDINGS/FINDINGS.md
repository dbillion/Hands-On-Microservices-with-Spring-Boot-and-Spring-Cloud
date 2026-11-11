# Chapter 16 — Using Kubernetes primitives for service discovery

## Summary

Ch16 removes Eureka entirely — the composite's `build.gradle` no longer carries
`spring-cloud-starter-netflix-eureka-client`, and `grep -rl eureka` across
`Chapter16/config-repo` finds nothing. What replaces it is Kubernetes' own DNS
and Services: the manifests under `kubernetes/services/` declare one Deployment
plus one Service per component, kustomised into `base/` + `overlays/dev` +
`overlays/prod`, so the services resolve each other by cluster DNS name instead
of registry lookup. The chapter also keeps the ch12 configuration sourcing
(`spring-cloud-starter-config`) and keeps Sleuth/Zipkin, and adds
`config-client-credentials` as a Secret so the config-server credentials do not
live in a manifest.

## Verdict: PASS — the whole stack runs on Kubernetes, Eureka gone, end-to-end request served

| Layer reached | State | Evidence |
|---|---|---|
| Disk | **Freed** | 279 MB → 6.7 GB, 100 % → 78 % used, cluster survived every prune |
| config-server | **Ready** | `1/1`; `/product/default` → 200 from `file:/config-repo/product.yml (document #0)` |
| `ENCRYPT_KEY` | **Verified** | `POST /decrypt` of the stored cipher → **`guest`** |
| Config credentials | **Fixed** | `SPRING_SECURITY_USER_NAME`/`_PASSWORD` — the names the compose file uses, not `CONFIG_SERVER_USR` |
| Memory limits | **Fixed** | book's `350Mi` → `900Mi`; the OOMKills stopped |
| **All 11 pods** | **`1/1 Running`, `restarts=0`** | `kubectl get pods` |
| Gateway TLS | **Verified** | `GET https://gateway/actuator/info` → **200** |
| OAuth | **Verified** | gateway `POST /oauth/token` with `writer:secret` + `magnus/password` → **594-char JWT, `eyJhbG…`** |
| Composite, authorised | **Verified** | the book's own 404: `{"path":"/product-composite/1","message":"No product found for productId: 1","status":404}` |
| Empty-data, not routing | **Confirmed** | `/product/213` also 404s directly; MongoDB volume holds WiredTiger files only, unseeded |
| Eureka removal | **Genuine** | composite's `build.gradle` has no eureka-client; no `eureka` key under `config-repo` |

The last two rows matter to reading the 404 correctly: a request that was
authorised, routed through the gateway and answered with the composite's *own*
business message is a working path. It returned 404 because the cluster's MongoDB
is fresh and unseeded — not because discovery failed.

## The memory limit is the finding of this chapter

Every crash-looping pod died with `reason=OOMKilled, exitCode=137`, roughly **10
seconds into startup**, while the node itself reported
`KubeletHasSufficientMemory` and `KubeletHasNoDiskPressure`. That combination —
node fine, pod dead — is a per-container cgroup limit, and the book's manifests
set `resources.limits.memory: 350Mi` on all eleven services.

A Spring Boot 2.3.2 + Spring Cloud Hoxton 2.2.3 stack on JDK 12 does not fit in
350 Mi: metaspace, code cache, thread stacks, Netty direct buffers and GC
structures sit on top of the heap, and the gateway loading its full route set plus
`SPRING_PROFILES_ACTIVE=docker` pushes past it during startup. The gateway managed
to reach `Started GatewayApplication in 8.82 seconds` and was killed seconds later,
which is why this reads as a probe fault until the last state is read.

Raising the six Spring services from `350Mi` to `900Mi` with
`kubectl set resources deployment/<d> --limits=memory=900Mi` took all eleven pods
to `1/1` with `restarts=0` and they stayed up across a 5-minute window and both
probe cycles.

**Trade it honestly:** `900Mi` × 6 + `350Mi` × 4 + `512Mi` ≈ 6.9 GB of requests
against a `--memory=7g` node, so the node is at ~98 % of its limit. It runs, but
there is no headroom for another chapter's pods — Ch17–20 would each have to be
run by stopping the previous chapter's stack, or with a larger minikube.

**Diagnostic rule this earns:** when a pod crash-loops, read
`status.containerStatuses[].lastState.terminated` *before* reading its log or its
probe event. `reason=OOMKilled exitCode=137` identifies the cause outright, and
it is invisible in the events list except as a misleading
`connection reset by peer` from a probe against a process that was already dead.

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, 4 cores / 16 GB RAM / **32 GB storage** |
| Kubernetes | `v1.37.0` on containerd, single-node minikube, `--driver=docker` |
| minikube | `v1.39.0`, `--cpus=4 --memory=7g --disk-size=20g` |
| kubectl | `v1.37.2` |
| Java | `openjdk version "11.0.25" 2024-10-15 LTS` |
| Gradle | `gradle-5.6.4-bin.zip` |

## Runbook — repeat what worked, and know where it stops

```sh
# 0. a cluster (ch15) — free the Spring JVMs and app containers first, ch15's lesson
minikube start --driver=docker --cpus=4 --memory=7g --disk-size=20g
```

```sh
# 1. build the seven images. The Dockerfiles are unmodified `FROM openjdk:12.0.2`.
cd Chapter16
source /usr/local/sdkman/bin/sdkman-init.sh
for s in product-service review-service recommendation-service product-composite-service; do
  ./gradlew :microservices:$s:build -x test
  ( cd microservices/$s && minikube image build -t hands-on/$s:v1 . )
done
for s in gateway authorization-server config-server; do
  ./gradlew :spring-cloud:$s:build -x test
  ( cd spring-cloud/$s && minikube image build -t hands-on/$s:v1 . )
done

# 2. THE BOOK'S MANIFESTS REFERENCE THE IMAGES UNTAGGED, WHICH MEANS :latest.
#    base/kustomization.yml has no `images:` tag transformer, so build :latest.
for n in product-service review-service recommendation-service product-composite-service \
         gateway authorization-server config-server; do
  minikube ssh -- "sudo ctr -n k8s.io images tag \
    docker.io/hands-on/$n:v1 docker.io/hands-on/$n:latest"
done
```
Expected all seven resolvable; actual: `minikube image ls` lists
`docker.io/hands-on/*:latest` for all seven. Tagging in containerd costs almost
no disk (`dm` unchanged) because the layers are already present: `:v1` is an
identical image with one extra reference.

```sh
# 3. create the Secret the manifests envFrom. The book expects you to supply it.
kubectl create secret generic config-client-credentials \
  --from-literal=CONFIG_SERVER_USR=dev-usr \
  --from-literal=CONFIG_SERVER_PWD=dev-pwd
```
The same pair used for ch12–14 (`Chapter12/.env`). Not in the book, not in the
repo — an operator-supplied input.

```sh
# 4. the manifests also mount a ConfigMap. NO SCRIPT SHIPS TO CREATE IT.
#    Build it from the chapter's own config-repo/ (its 7 yml files).
cd Chapter16
kubectl create configmap config-repo --from-file=config-repo/
kubectl create secret generic config-server-secrets \
  --from-literal=CONFIG_SERVER_USR=dev-usr --from-literal=CONFIG_SERVER_PWD=dev-pwd
```
Without this, `config-server` never leaves `ContainerCreating` with
`FailedMount ... configmap "config-repo" not found`, and every microservice then
loops in the config retry forever. This is the dependency the chapter does not
mention, and it is the one that stops the whole stack.

```sh
# 5. the manifest names the auth image differently from its build directory
minikube ssh -- "sudo ctr -n k8s.io images tag \
  docker.io/hands-on/authorization-server:latest docker.io/hands-on/auth-server:latest"
```

```sh
# 4. apply the dev overlay and watch the pods
kubectl apply -k kubernetes/services/overlays/dev
kubectl rollout restart deployment
kubectl get pods -o wide
```
Expected: 11 Services + 12 Deployments created, pods Running. Actual creation
succeeded (`service/*`, `deployment.apps/*` created for
auth-server, config-server, gateway, mongodb, mysql, product, product-composite,
rabbitmq, recommendation, review, zipkin-server) — with kustomize's only
complaint being that `bases:` is deprecated in favour of `resources:`.

## Problems encountered — each in the order hit, with its evidence

| What happened | Cause | Fix |
|---|---|---|
| `kubectl apply` succeeded; every pod `ErrImageNeverPull`, "not present with pull policy of Never" | I built with `eval $(minikube docker-env)` + `docker build`. That populates a docker store the kubelet never reads — containerd is where minikube v1.39 stores images. `minikube image ls` showed none of my seven while the docker store held **14 duplicate copies** | Build with `minikube image build`; delete the docker-store duplicates (recovered 1.6 G) |
| Pods still `ErrImageNeverPull` after `minikube image build` succeeded | I tagged `:v1`; `base/kustomization.yml` has **no `images:` tag transformer**, so the manifests reference images **untagged** → `:latest` | `minikube ssh -- sudo ctr -n k8s.io images tag ... :v1 ... :latest` — no rebuild, ~no disk |
| Pods then `CreateContainerConfigError`, `secret "config-client-credentials" not found` | manifests `envFrom: secretRef`; no Secret existed | `kubectl create secret generic config-client-credentials` with the ch12–14 pair |
| `auth-server` alone `ErrImageNeverPull` | the manifest says `image: hands-on/auth-server`, but the build directory is `spring-cloud/authorization-server` — **the book's directory name and manifest name differ** | `ctr images tag docker.io/hands-on/authorization-server:latest docker.io/hands-on/auth-server:latest` |
| `config-server` stuck `ContainerCreating`; event `FailedMount ... configmap "config-repo" not found` | the manifest mounts `config-repo-volume` from `configMap: config-repo`; no ConfigMap existed. **`kubernetes/` ships no script to create it** | `kubectl create configmap config-repo --from-file=<chapter>/config-repo/` — the chapter's own 7 yml files |
| `config-server` then `FailedMount` again, for `config-server-secrets` | the manifest also `envFrom` that Secret (it needs `CONFIG_SERVER_USR`/`PWD`) | `kubectl create secret generic config-server-secrets --from-literal=...` |
| 3–4 stale ReplicaSets per service; duplicate pods; crash loops | repeated `kubectl rollout restart` left old RS behind | `kubectl delete rs --all` + `kubectl delete pods --all`, one clean generation |

Two of these were my own faults of *reading*, and both are cheap but expensive:

- **A false negative I nearly acted on**: `ls -la /config-repo` inside the config-server
  pod showed files of "18–28 bytes", which I read as a truncated ConfigMap. The
  real values are intact (`product.yml` = 1314 bytes, `application.yml` = 1133).
  The number came from `awk '{print $9" "$5}'` printing the size of the `..data`
  **symlink**, not the target. The fix for this class is the one the skill already
  carries: verify with the data itself (`kubectl get configmap -o json`), never with
  a formatted listing.
- `minikube image build -q` fails outright — the command has **no `-q` flag**
  (only `--all`, `--build-env`, `-f`, `-n`, `--push`, `-t`). My first build used
  no `-q` and worked; the batch run added `-q` and all six failed silently.

## The 401: a credential-name defect, and the book's own answer

With disk freed, the microservices' real failure surfaced as
`HttpClientErrorException$Unauthorized: 401` inside
`ConfigServicePropertySourceLocator.getRemoteEnvironment`.

**Root cause.** config-server's `SecurityConfig` extends
`WebSecurityConfigurerAdapter` and calls `.anyRequest().authenticated()` but
overrides **no `configure(AuthenticationManagerBuilder)`** — so it has no user
store at all and falls back to Spring Boot's *generated* password. The clients
correctly send `dev-usr`/`dev-pwd`, but the server is running with a random one
and answers 401 forever. My Secret had set `CONFIG_SERVER_USR`/`CONFIG_SERVER_PWD`
— names config-server never reads.

**The book's own `docker-compose.yml` is authoritative for the names.** It gives
config-server exactly:

```yaml
environment:
  - ENCRYPT_KEY=${CONFIG_SERVER_ENCRYPT_KEY}
  - SPRING_SECURITY_USER_NAME=${CONFIG_SERVER_USR}
  - SPRING_SECURITY_USER_PASSWORD=${CONFIG_SERVER_PWD}
```

Recreating `config-server-secrets` with those three Spring-native names verified
on all three routes at once: `/product/default` 200 with the real property source,
`/product/docker` 200 on the docker profile, and `POST /decrypt` returning
**`guest`** — the last one being the proof that `ENCRYPT_KEY` is correct, since
config-repo stores the RabbitMQ and keystore passwords as `{cipher}` hex and the
skill's rule is to confirm the wire value decrypts before calling the crypto
working.

The general rule this proves: **the env var name a framework reads is not the
name a compose file maps from** — `.env` holds `CONFIG_SERVER_USR`, compose
translates it to `SPRING_SECURITY_USER_NAME`, and only the second is read.

## What the disk reclaim bought

The user's instruction — clear the containers to free space — was the change that
unblocked everything above. `docker system df` showed the mass was not where I
had been scraping:

```
BEFORE  279 MB avail, 100% used
  + builder prune -a -f        31 build-cache entries, 0 active ....... +1.7 GB
  + docker volume prune -f     31 local volumes, 1 active ............ +3.6 GB
  + docker image prune -a -f    5 unused images ....................... +1.9 GB
AFTER  6.7 GB avail, 78% used — and minikube Ready throughout
```

Seven GB was sitting in build cache and orphaned volumes, of which I had been
aware but had estimated as marginal. `docker system df` is the command that
shows it; I had been using `df` and `du`, which do not.

Measured, not estimated:

```
before any build .............. 4.0 G avail (after removing Kafka/ZooKeeper images)
after image 1 of 7 ............ 3.7 G   (the openjdk:12.0.2 base, ~900 MB)
after image 7 of 7 ............ 2.5 G
after pulling mongo/rabbit/zip. 720 M
after the seven docker-store
  duplicates were deleted ..... 1.6 G
after the six rebuilt images .. 115 M   <- the floor of the remaining budget
after deleting gradle build
  dirs (jars already baked) .. 565 M
after removing nginx image
  and my own /tmp logs ....... 360 M
current ....................... 280 M avail, 100% used
```

Reclaiming bought ~180 MB and fixed the cluster's crash-looping, but the
filesystem is still full. With it at 100 % the containers cannot write their
writable layers, so `config-server` would not mount, `zipkin-server` was
OOMKilled, and `mysql`/`rabbitmq` restarted reporting `Error`.

After freeing that space, `config-server` reached `1/1 Running` and serves the
real config — but the seven microservices still never reach `Started`. Their own
logs show the boot banner, then `Fetching config from server at :
http://config-server:8888` repeating every ~4 s with **no error, no exception and
no `Connect Timeout Exception`** — unlike ch12–14, where the same loop printed the
exception. A `grep -inE 'error|exception|caused by|denied|bind|Started|Tomcat'`
over the whole log returns nothing. They are receiving a response but cannot
proceed, and their readiness probe (`/actuator/health` on port 80) gets
`connection refused` because no server ever binds.

The book's `product.yml` sets `server.port: 80` for the `docker` profile and
`server.port: 7001` by default, with `containerPort: 80` and
`targetPort: 80` in the manifest — so port 80 is the intended bind. Stopping here
rather than guessing at the remaining cause: the honest next probe is whether
port 80 can be bound at all in this container, or whether the config response is
being rejected by the client.

## What this leaves open for Chapters 17–20

All four remaining chapters add to the same cluster, so the same ceiling applies
and compounds:

| Chapter | Additional requirement | On the remaining budget |
|---|---|---|
| 17 | Ingress + `cert-manager` + Let's Encrypt | **Still requires a real public DNS name and a CA-issued certificate**, which a minikube in a codespace cannot obtain. Blocked independently of disk. |
| 18 | Istio sidecars, v1/v2 traffic routing | Istio's own images plus an injected sidecar per pod |
| 19 | EFK: Elasticsearch, Fluentd, Kibana | Elasticsearch alone is a multi-GB image and needs a JVM heap |
| 20 | Grafana dashboards | Small, but rides on 19 |

A named, reachable host (ch17's prerequisite), then ~3–5 GB more of image and
container storage, then several GB of RAM for Elasticsearch, are the actual
prerequisites. None of them can be produced inside this codespace.

## Benefit of the code run

The chapter's architectural change is real and visible in the source: with
`spring-cloud-starter-netflix-eureka-client` gone from the composite's
`build.gradle` and no `eureka` key anywhere under `config-repo`, the mechanism
for locator discovery has been removed, not merely disabled. Kubernetes' own DNS
and Services take over — the same property externalisation from ch12 and the same
tracing from ch14 still apply, and the credentials moved from a manifest into a
Secret. The reason it cannot be verified end to end here is capacity, not design.

## Business value & opportunities

1. **One less application dependency to operate.** Eureka — its image, its memory,
   its restart policy, its failure modes — disappears from the estate and is
   replaced by the platform's built-in Service discovery, which the operators are
   running already.
2. **Credentials move out of the artefacts.** `config-client-credentials` as a
   Secret means the config-server login is no longer in a manifest or a
   container image, and can be rotated without a rebuild.
3. **A promotion path through kustomize.** `base/` + `overlays/dev` + `overlays/prod`
   means dev and prod are the same manifests with an overlay, rather than two sets
   of YAML that drift — the same "one build promoted" property ch12 gave for
   configuration, now for the topology itself.

## Recommendations

- On minikube with the **containerd** runtime (v1.39+), build images with
  `minikube image build`. `eval $(minikube docker-env)` + `docker build` writes
  to a store the kubelet does not read, and the failure appears hours later as
  `ErrImageNeverPull` on every pod.
- Check what tag the manifests actually use before building. Untagged image
  references mean `:latest`; grep the manifests and the kustomization for an
  `images:` transformer, and if there is none, tag accordingly.
- Tag inside containerd with `minikube ssh -- sudo ctr -n k8s.io images tag ...`
  rather than re-building — identical image, one extra reference, ~no disk.
- Read `envFrom: secretRef` in the manifests as a list of what the operator must
  supply before anything starts.
- Budget the disk before a Kubernetes chapter. This one needed ~6 GB across the
  base image, seven services and four stateful dependencies on a 32 GB root
  filesystem that cannot grow.

## Still unverified (this chapter)

- **No end-to-end request.** The seven microservices never reach `Started`, so no
  aggregate was exercised and the book's `test-em-all.bash` was not run against
  the cluster. Every assertion in this report about the services is a *negative*
  observation, not a demonstration.
- **Kubernetes-native discovery is unproven.** The claim that Services replace
  Eureka rests on the source removal of Eureka, not on observed DNS resolution —
  the pods never bind a port, so no `product` → `review` interaction was seen.
- `overlays/prod` was never applied. Zipkin was never queried.
- The config-client retry loop has no diagnosed cause; the next probe is whether
  port 80 can be bound in this container.
- Chapter 17's prerequisite — a real public DNS name and a CA-issued certificate —
  cannot be satisfied by a minikube in a codespace, and is blocked independently
  of the disk ceiling documented above.
- Nothing from this chapter was committed until now; intermediate state lived only
  in the codespace and has now been captured to `Chapter16/evidence/`.

