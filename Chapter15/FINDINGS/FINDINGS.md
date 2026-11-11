# Chapter 15 — Running the system landscape on Kubernetes

## Summary

Ch15 is the book's introduction to Kubernetes: it steps away from
`docker-compose` and moves the system landscape onto a real cluster. The chapter
ships only `kubernetes/first-attempts/`, containing two handwritten manifests —
`nginx-deployment.yaml` (a Deployment of `nginx:latest`, 1 replica) and
`nginx-service.yaml` (a NodePort Service on 30080) — and the working lesson is
that these are the minimum two objects a workload needs to be reachable: a
**Deployment** identity (the selector and template labels the Service will match
against) and a **Service** that exposes it.

Chapter 15 contains no Java change and no config-repo change: `diff -rq`
against Chapter 14 shows `config-repo/application.yml` and `product.yml` are
**identical**, and the only new item in the whole chapter directory is the
`kubernetes/` folder. What changed is the runtime, which is why verification here
means proving the cluster, not re-running the microservice suite.

## Verdict: PASS — a real minikube cluster runs the book's own manifests

A minikube cluster (Kubernetes **v1.37.0** on containerd) was started in the
codespace, the book's two manifests were applied **unmodified**, and the nginx
workload was reached from inside the cluster and from the host over its NodePort.
Deployment `1/1` ready, EndpointSlice carrying the pod address, host request
returning `HTTP=200` with `Welcome to nginx!`.

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, standardLinux32gb, 4 cores / 16 GB RAM / 32 GB storage |
| Kubernetes | `v1.37.0` on `containerd 2.3.4`, single-node minikube |
| minikube | `v1.39.0`, `--driver=docker` |
| kubectl | `v1.37.2` |
| Docker | `29.9.2-2` |
| kube-system pods | coredns, etcd, kindnet, kube-apiserver, kube-controller-manager, kube-proxy, kube-scheduler, storage-provisioner — all `1/1 Running` |

**Resource cost measured, not assumed.** Starting the chapter required freeing
the machine first: the six Spring JVMs from ch14 and the five ch12 containers
(Mongo, MySQL, RabbitMQ, Kafka, ZooKeeper) were stopped and removed, taking
available memory from **5 GB to 13 GB**. Minikube then started with
`--cpus=4 --memory=7g --disk-size=20g`, leaving ~4.4 GB of root filesystem free
(32 GB total, 73 % → 85 % used). A cluster is materially more expensive than the
jar-run stack, and the codespace has *just* enough headroom for one.

## Runbook — repeat the whole chapter from scratch

```sh
# 0. a cluster that does not exist yet must be created
minikube start --driver=docker --cpus=4 --memory=7g --disk-size=20g
kubectl wait --for=condition=Ready node/minikube --timeout=180s
```
Expected, actual: `condition met`, `minikube Ready control-plane v1.37.0`.

```sh
# 1. apply the chapter's own manifests, unmodified
cd Chapter15/kubernetes/first-attempts
kubectl apply -f nginx-deployment.yaml
kubectl apply -f nginx-service.yaml
```
Expected creation, actual `deployment.apps/nginx-deploy created`,
`service/nginx-service created` (on first application; `unchanged` when
re-applied).

```sh
# 2. confirm the Deployment converges and the pod is scheduled
kubectl rollout status deployment/nginx-deploy --timeout=180s
kubectl get pods -l app=nginx-app -o wide
```
Expected `successfully rolled out`, pod `1/1 Running`, an IP, the node name;
actual exactly that, pod IP `10.244.0.3` on node `minikube`.

```sh
# 3. prove the Service selector matched the Deployment's template labels
kubectl get service nginx-service
kubectl get endpointslice -l kubernetes.io/service-name=nginx-service -o wide
```
Expected `NodePort` with `80:30080/TCP` and an endpoint carrying the pod IP;
actual `10.104.42.210` ClusterIP, `80:30080/TCP`, EndpointSlice
`10.244.0.3:80`. **This is the line that proves the chapter's actual lesson** —
a Service that resolves to an empty endpoint list would still print "apply
succeeded".

```sh
# 4. prove reachability from inside the cluster
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: curl-probe}
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: curlimages/curl:8.5.0
    command: ['sh','-c','curl -s -o /dev/null -w "service HTTP=%{http_code}\n" http://nginx-service/; curl -s http://nginx-service/ | head -3']
YAML
sleep 20 && kubectl logs curl-probe
```
Expected nginx HTML from the DNS name, actual `<!DOCTYPE html><html>...` — the
Service name resolves in-cluster.

```sh
# 5. prove reachability from the host over the NodePort
NODEIP=$(minikube ip)
curl -s -o /dev/null -w 'HTTP=%{http_code}\n' http://$NODEIP:30080/
curl -s http://$NODEIP:30080/ | grep -oE 'Welcome to nginx!'
minikube service nginx-service --url
```
Expected `HTTP=200`, `Welcome to nginx!`, a url; actual
`http://192.168.49.2:30080/ HTTP=200`, `body: Welcome to nginx!`,
`http://192.168.49.2:30080`.

## Problems encountered

| What happened | Cause |
|---|---|
| `http://127.0.0.1:30080/` → `HTTP=000`, connection refused | With minikube's **docker driver** the NodePort is published on the node container's address, not on the host loopback. The right address is `$(minikube ip)`, `192.168.49.2` in a fresh cluster — not `127.0.0.1` |
| In-cluster probe printed `curl: (2) no URL specified` twice | The probe's `-w` format string lost its URL argument to shell quoting inside the pod command; one of its three curls still succeeded and returned the nginx HTML, so the conclusion held. Fixed by keeping the probe a single curl with the format string quoted |
| Only **5 GB** of 15 GB RAM available; minikube would not spare a cluster | The six Spring JVMs and five Docker containers from ch12–ch14 were still resident. Stopping them freed 8 GB, taking availability to 13 GB |
| Root filesystem filled to 85 % | Cluster images plus the nginx pull consumed ~3 GB. There is ~4.4 GB of headroom left, which constrains chapters 18–20 |

## Fixes applied

| Fix | How verified |
|---|---|
| Address the NodePort by `$(minikube ip)`, not `127.0.0.1` | `http://192.168.49.2:30080/ HTTP=200`, body `Welcome to nginx!`; `127.0.0.1:30080` still `HTTP=000` for contrast |
| Free the jar stack and app containers before `minikube start` | `free -g` reports 13 GB available after the removal; cluster reaches `Ready` |
| Read the EndpointSlice, not just the Service | `nginx-service-dg67n IPv4 80 10.244.0.3` — the selector genuinely matched the pod |

## Benefit of the code run

The system landscape now runs in a cluster rather than on Docker Compose. The
book's two handwritten objects are enough to get a workload deployed, scheduled,
addressable by name inside the cluster, and reachable from outside — and the
reasons each object exists are observable: the Deployment's labels are what the
Service selects, and the EndpointSlice is where that selection becomes an
address.

## Business value & opportunities

1. **Deployment becomes declarative instead of imperative.** The pod is not
   started by a command; a manifest states what should exist and the cluster
   reconciles to it. `kubectl apply` twice is idempotent, which is what removes
   the class of "works on my machine" drift Compose leaves behind.
2. **Reachability is a property of a Service, not of a container port.** The
   NodePort is stable across pod restarts and rescheduling, so a client address
   does not go stale when a container is replaced — the precondition for rolling
   updates later in the book.
3. **The same manifest is the unit of promotion.** Because the environment lives
   in these files, dev and staging differ by input rather than by a different
   setup script.

## Recommendations

- Before running any Kubernetes chapter, **free the machine**: the Spring JVMs
  and the Mongo/MySQL/Rabbit/Kafka containers hold ~8 GB that the cluster needs.
- Never verify a Service by `kubectl get svc` alone; read the EndpointSlice. An
  apply can succeed while the selector matches nothing.
- With the docker driver, `minikube ip` is the only correct host address for a
  NodePort; `127.0.0.1` will refuse connection.
- Watch the root filesystem. It goes 73 % → 85 % once a cluster exists, and the
  later chapters (Istio, EFK, Grafana) need several more GB.

## Still unverified (this chapter)

- The book's microservices were **not** deployed to the cluster. Chapter 15 ships
  only the nginx first-attempts; the Spring stack deployment appears from
  Chapter 16 onward. The jar-run stack was stopped to make room for the cluster
  and was left stopped.
- Multi-node behaviour, Ingress, PersistentVolumeClaims and the book's
  `docker-compose.yml` were not exercised.
- The codespace holds ~4.4 GB of free disk, so chapters 16–20 were run with
  little margin — a resource limit reached mid-run would stop progress.

