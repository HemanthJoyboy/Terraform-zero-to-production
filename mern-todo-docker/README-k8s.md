# MERN Todo on Kubernetes (AWS EKS)

This document picks up where `README.md` (Docker/Compose) leaves off. Same
app, same 5 pieces (`client`, `api-gateway`, `auth-service`, `todo-service`,
`postgres`) — now running on a real, multi-node Kubernetes cluster on AWS
(EKS = Elastic Kubernetes Service) instead of a single Docker host.

```
mern-todo-docker/
├── README.md            # Docker / Compose (unchanged)
├── README-k8s.md         # this file
└── k8s/                  # Kubernetes manifests, apply in this numeric order
    ├── 00-namespace.yaml
    ├── 01-configmap.yaml
    ├── 02-secret.yaml
    ├── 03-postgres-init-configmap.yaml
    ├── 04-postgres.yaml           # StatefulSet + headless Service
    ├── 05-auth-service.yaml       # Deployment + Service
    ├── 06-todo-service.yaml       # Deployment + Service
    ├── 07-api-gateway.yaml        # Deployment + Service
    ├── 08-client.yaml             # Deployment + Service
    └── 09-ingress.yaml            # ALB Ingress - the one public entry point
```

**Table of contents**
1. [Why Kubernetes? What problem does it actually solve?](#1-why-kubernetes-what-problem-does-it-actually-solve)
2. [Kubernetes architecture, request flow, and pod lifecycle](#2-kubernetes-architecture-request-flow-and-pod-lifecycle)
3. [Every concept, explained and mapped to this app](#3-every-concept-explained-and-mapped-to-this-app)
4. [Deploying to AWS EKS, step by step](#4-deploying-to-aws-eks-step-by-step)
5. [Volumes, networking, ingress/load balancing, service-to-service communication](#5-volumes-networking-ingressload-balancing-service-to-service-communication)
6. [A request, end to end, under the hood](#6-a-request-end-to-end-under-the-hood)

---

## 1. Why Kubernetes? What problem does it actually solve?

Everything up to now — manual `docker run`, then `docker-compose.yml` — ran
on **one machine**. That's the ceiling Kubernetes exists to break through.

### What Compose genuinely can't do, no matter how you configure it

| Limitation | Why it's structural, not a config issue |
|---|---|
| **One host = one point of failure** | If that EC2 instance dies (hardware fault, AZ outage, you fat-fingered a reboot), every container dies with it. `restart: unless-stopped` only helps if the *container* crashes — it does nothing if the *machine* is gone. |
| **Can't scale past one machine's capacity** | Compose has no concept of "add another server." If `todo-service` needs 10 replicas to handle load, they'd all have to somehow fit on that one box. |
| **No real load balancing across replicas** | You *can* run `docker compose up --scale todo-service=3`, but nothing distributes traffic across those 3 automatically — you'd have to build that yourself. |
| **Rolling updates aren't zero-downtime by default** | `docker compose up -d --build` recreates containers more or less all at once; there's a real gap where the new version isn't up yet and the old one's already gone. |
| **No self-healing beyond the container level** | If the box itself is unhealthy (disk full, kernel panic, out of memory at the OS level), nothing moves your workload elsewhere — there's nowhere else for Compose to move it *to*. |
| **You're the scheduler** | You manually decided which service runs where via your `docker run`/compose file. At any real scale (tens/hundreds of services, multiple teams), deciding "which of N machines has room for this container right now" by hand stops being feasible. |

### The real-world scenario this actually matters for

Picture this Todo app going viral, or an e-commerce site during a flash
sale: traffic jumps 20x for a few hours, then drops back down. On a single
Compose host, your options are "hope the one box can take it" or "manually
provision a bigger box and migrate everything," live, under load. On
Kubernetes: you (or an autoscaler) bump `replicas: 2` to `replicas: 20` on
`api-gateway`, new pods get scheduled across whichever nodes have room —
including newly added nodes, if the *cluster's* autoscaler is also on — and
traffic starts flowing to them within seconds, no migration, no downtime.
When traffic drops, scale back down and stop paying for capacity you're not
using.

Or: a worker node in your cluster hits a hardware fault at 3 AM. On
Compose, that's a page-you-awake outage. On Kubernetes, the control plane
notices that node stopped reporting in, and reschedules every pod that was
on it onto healthy nodes — often before anyone's even looked at an alert.

### What Kubernetes actually is, in one sentence

**You declare the state you want** ("I want 2 copies of `auth-service`
running, using this image, with this config") **and Kubernetes
continuously works to make reality match that declaration** — across
however many machines it takes, moving things around as needed, forever,
without you re-running a command each time something changes. Compose
executes a file once, when you run it. Kubernetes *watches* your desired
state permanently and keeps reconciling toward it. That one shift —
imperative "run this now" vs. declarative "make this always true" — is the
root of almost every capability above.

---

## 2. Kubernetes architecture, request flow, and pod lifecycle

### The two halves of a cluster

```
┌───────────────────────────── CONTROL PLANE ─────────────────────────────┐
│                  (on EKS: fully managed by AWS - you never SSH into it)  │
│                                                                          │
│   ┌──────────┐      ┌────────────┐      ┌───────────┐    ┌───────────┐ │
│   │kube-apiserver│──▶│    etcd    │      │ scheduler │    │ controller│ │
│   │ (the front  │◀──│ (key-value │      │ (decides  │    │  manager  │ │
│   │  door - ALL │   │  store -   │      │  WHICH    │    │(reconciles│ │
│   │  reads/     │   │  the ONE   │      │  node a   │    │ desired vs│ │
│   │  writes go  │   │  source of │      │  new pod  │    │  actual   │ │
│   │  through it)│   │  truth)    │      │  runs on) │    │  state)   │ │
│   └──────┬───────┘   └────────────┘      └───────────┘    └───────────┘ │
└──────────┼───────────────────────────────────────────────────────────────┘
           │  (all node-level components only ever talk to the API server,
           │   never to each other directly, never to etcd directly)
┌──────────┼──────────────────── DATA PLANE (worker nodes) ────────────────┐
│          │                                                               │
│  ┌───────▼──── Node 1 (an EC2 instance) ─────┐  ┌── Node 2 ───────────┐  │
│  │  ┌────────┐   ┌───────────┐               │  │  ┌────────┐        │  │
│  │  │kubelet │   │kube-proxy │  [pod] [pod]  │  │  │kubelet │  [pod] │  │
│  │  │(talks  │   │(programs  │  containerd    │  │  │        │        │  │
│  │  │to API  │   │ iptables/ │  runs the      │  │  │        │        │  │
│  │  │server, │   │ IPVS rules│  actual         │  │  │        │        │  │
│  │  │runs    │   │for Service│  containers)   │  │  │        │        │  │
│  │  │pods)   │   │ routing)  │                │  │  │        │        │  │
│  │  └────────┘   └───────────┘               │  │  └────────┘        │  │
│  └────────────────────────────────────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**On EKS specifically:** AWS runs and manages the entire control plane row
for you — you never see or patch those machines; you just get an API
endpoint to talk to. You *do* manage the worker nodes' underlying EC2
instances (or use Fargate to not even do that). This is the main thing
"managed Kubernetes" (EKS/AKS/GKE) buys you over running your own — the
hardest, most failure-sensitive part (etcd consistency, API server HA) is
someone else's problem.

**Who does what, precisely:**
- **`kube-apiserver`** — the only component anything talks to. `kubectl`,
  every other control-plane component, and every node's `kubelet` all go
  through it. It validates requests and is the sole component allowed to
  read/write `etcd`.
- **`etcd`** — a distributed key-value store holding the *entire* cluster
  state: every object you've ever `kubectl apply`'d, current pod statuses,
  everything. If you've ever wondered "where does Kubernetes 'remember'
  anything" — it's here.
- **`scheduler`** — watches for pods that exist in etcd but haven't been
  assigned to a node yet, picks the best-fit node (based on requested
  CPU/memory, taints/tolerations, affinity rules), and writes that
  assignment back via the API server.
- **`controller-manager`** — runs many small control loops (one per
  resource type: Deployments, ReplicaSets, Services...), each constantly
  comparing "what's declared" vs. "what's actually running" and issuing
  corrections. This is the literal mechanism behind "declarative, self-
  healing" — there is no single thing called "the reconciler," it's dozens
  of these loops running forever.
- **`kubelet`** (one per node) — the node's agent. Watches the API server
  for pods assigned to *its* node, tells the container runtime to
  start/stop containers to match, and reports status back up.
- **`kube-proxy`** (one per node) — programs each node's `iptables` (or
  IPVS) rules so that traffic sent to a Service's virtual IP gets
  transparently rewritten to one of that Service's actual pod IPs. This is
  the literal mechanism behind Service-based load balancing — see Section 6.
- **container runtime** (`containerd` on EKS) — actually pulls images and
  runs containers, same job Docker's engine does, just driven by the
  kubelet instead of the `docker` CLI.

### What happens the moment you run `kubectl apply -f k8s/05-auth-service.yaml`

```
you (kubectl) ──1──▶ kube-apiserver ──2──▶ etcd
                            │                (writes: "desired state now
                            │                 includes a Deployment called
                            │                 auth-service, 2 replicas")
                            │
                            ▼ 3
                    Deployment controller
                    (part of controller-manager) notices the new/changed
                    Deployment, creates a ReplicaSet object for it
                            │
                            ▼ 4
                    ReplicaSet controller notices it has 0 of 2 desired
                    Pods, creates 2 Pod objects (still unscheduled -
                    no node assigned yet)
                            │
                            ▼ 5
                        scheduler
                    notices 2 unscheduled Pods, picks a node for each
                    based on available CPU/memory, writes the assignment
                            │
                            ▼ 6
                  kubelet (on the assigned node)
                  notices a Pod is now assigned to ITS node, tells
                  containerd to pull the image and start the container
                            │
                            ▼ 7
                  kubelet reports container status back to the API
                  server (Running, plus readiness probe results)
                            │
                            ▼ 8
                  kube-proxy (on every node) notices the new pod's IP
                  and updates its iptables rules so the auth-service
                  Service now includes it as a valid destination
```

Nothing in this chain happened because you told any single component "go
do X" — you only ever declared a desired state to the API server once, and
five or six independent, always-running control loops each reacted to that
change within their own narrow responsibility. That's the declarative model
from Section 1, made concrete.

### Pod lifecycle

```
Pending ──▶ ContainerCreating ──▶ Running ──▶ (container exits)
   │              │                  │                │
   │              │                  │        exit code 0 & no restartPolicy: Always
   │              │                  │                │
   │       image pull fails,         │                ▼
   │       or scheduling             │            Succeeded
   │       impossible (no            │
   │       node has room)            │        exit code != 0, or crash
   │              │                  │                │
   │              ▼                  │                ▼
   │        ImagePullBackOff /       │           CrashLoopBackOff
   │        Pending (stuck)          │        (kubelet keeps restarting it,
   │                                 │         with exponential backoff -
   ▼                                 │         10s, 20s, 40s...)
(stays Pending until the             │
 scheduler CAN place it,             ▼
 or you fix what's blocking    readinessProbe passing?
 it - e.g. add nodes,          ──────┬─────────────
 fix a bad image name)               │
                              YES ◀──┴──▶ NO
                               │            │
                               ▼            ▼
                    Pod is "Ready" -   Pod stays Running but is
                    kube-proxy adds    REMOVED from the Service's
                    it to Service      pool of valid destinations -
                    routing, real      it gets NO traffic until the
                    traffic can        probe passes again
                    reach it
```

**The subtlety that trips people up:** `Running` and `Ready` are **not the
same thing**. A pod can be `Running` (its container process is alive) while
being *not Ready* (its readiness probe is failing) — Kubernetes will keep
it alive but stop routing Service traffic to it. This is exactly what
happens during `auth-service`'s first few seconds of startup, or if it
temporarily can't reach `postgres` — the pod doesn't get killed for that,
it just quietly stops receiving requests until it recovers. See Section 3's
"Probes" entry for the three probe types and why this app uses two of them.

---

## 3. Every concept, explained and mapped to this app

### Pod
The smallest deployable unit — one or more containers that always get
scheduled together, onto the same node, sharing one network namespace (so
they can talk over `localhost` to each other) and optionally shared
volumes. In this app, every pod runs exactly one container — you don't
*need* multi-container pods until you reach for sidecars (e.g. a logging
agent bolted onto every pod), which this app doesn't use.
**Where:** every `spec.template` block in `05-`, `06-`, `07-`, `08-`, and
`04-postgres.yaml` describes a pod template.

### ReplicaSet
Ensures a specified *number* of identical pod replicas are running at all
times — if one dies, it creates a replacement; if there are too many
(e.g. after a scale-down), it deletes the extras. **You don't write these
directly** — a Deployment creates and manages one for you automatically.
**Where:** invisible in our YAML, but run `kubectl get replicasets -n
mern-todo` after deploying and you'll see one per Deployment, named like
`auth-service-7d8f9c6b5d`.

### Deployment
Manages a ReplicaSet on your behalf, and adds the thing a bare ReplicaSet
can't do: **rolling updates**. When you change the image tag and
`kubectl apply` again, the Deployment creates a *new* ReplicaSet at the new
version and gradually shifts pods from old to new (default: one at a time,
new pod must pass its readiness probe before the next old one is killed) —
zero-downtime by construction, not by luck.
**Where:** `05-auth-service.yaml`, `06-todo-service.yaml`,
`07-api-gateway.yaml`, `08-client.yaml` are all Deployments.

### StatefulSet
Like a Deployment, but for workloads where pod *identity* and *storage*
must stick together across restarts — pod names are stable (`postgres-0`,
not a random suffix), and each replica gets its own PersistentVolumeClaim
that follows it specifically, not a shared/interchangeable one.
**Where:** `04-postgres.yaml`. See that file's comments for exactly why
Postgres needs this and a plain Deployment doesn't cut it for a database.

### Service
A stable virtual IP + DNS name in front of a *set* of pods, selected by
label — not by pod name, since pod names/IPs are ephemeral and change
every time a pod is recreated. Sending traffic to a Service transparently
load-balances across whichever pods currently match its selector.
Three flavors matter here:
- **ClusterIP** (the default) — reachable only from inside the cluster.
  Used for `auth-service`, `todo-service`, `api-gateway`, and `client` —
  none of them are meant to be reached directly from outside; only the
  Ingress is.
- **Headless** (`clusterIP: None`) — no load-balancing, just stable
  per-pod DNS. Used for `postgres`, required by StatefulSets.
- **LoadBalancer** — not used directly in this app's manifests; the
  AWS Load Balancer Controller creates the equivalent (an ALB) for you when
  it sees the Ingress object instead.
**Where:** the second document in each of `04-`, `05-`, `06-`, `07-`,
`08-*.yaml`.

### Labels & selectors
Plain key-value tags (`app: auth-service`) attached to objects, and the
mechanism (`selector: matchLabels: app: auth-service`) everything above
uses to find "which pods am I talking about." This is *the* connective
tissue of Kubernetes — a Service doesn't know pod names, it just says
"anything labeled `app: auth-service`, send it here," and stays correct
automatically as pods are replaced.
**Where:** every `metadata.labels` + `spec.selector` pair in every file.

### Namespace
A logical partition inside one cluster — object names only need to be
unique *within* a namespace, and you can apply resource quotas, network
policies, and access control per-namespace. Not a Docker Compose concept at
all (Compose's closest equivalent is "a project," which is really just a
naming prefix, with no isolation).
**Where:** `00-namespace.yaml` creates `mern-todo`; every other manifest
declares `namespace: mern-todo` so it lands inside it.

### ConfigMap
Non-sensitive configuration, injected into pods as environment variables
(what this app uses) or mounted as files (what the Postgres init-scripts
ConfigMap does instead — see below). Directly equivalent to the non-secret
lines from the old `.env` files.
**Where:** `01-configmap.yaml` (`AUTH_SERVICE_URL`, `TODO_SERVICE_URL`,
`POSTGRES_DB`, `POSTGRES_USER`) and `03-postgres-init-configmap.yaml` (the
actual `schema.sql` contents, mounted as files into
`/docker-entrypoint-initdb.d` inside the postgres pod).

### Secret
Same shape as a ConfigMap, but semantically for sensitive values — and
handled slightly differently by tooling (e.g. `kubectl get secret -o yaml`
doesn't print values in plaintext by default the way ConfigMaps do).
**Important nuance:** Secret values are only **base64-encoded** in `etcd`
by default, not encrypted — base64 is an encoding, not encryption, trivial
to reverse (`echo <value> | base64 -d`). "Secret" here means "Kubernetes
treats this differently in its API/UI/RBAC," not "this is safe to commit to
git" or "this is unreadable to anyone with cluster access." Real production
setups add **encryption at rest for etcd** and/or pull secrets from a
dedicated vault (AWS Secrets Manager, HashiCorp Vault) instead of storing
them as Secret objects at all — see the AWS Secrets Manager note in
Section 4.
**Where:** `02-secret.yaml` (`POSTGRES_PASSWORD`, `JWT_SECRET`,
`DATABASE_URL`).

### Volumes, PersistentVolume (PV), PersistentVolumeClaim (PVC), StorageClass
- A **Volume** is storage attached to a pod — can be as simple as an
  in-memory `emptyDir`, or a ConfigMap mounted as files (see the Postgres
  init-scripts above), or persistent block storage.
- A **PersistentVolumeClaim** is a *request* for persistent storage ("I
  need 1Gi, ReadWriteOnce") — decoupled from any specific pod.
- A **PersistentVolume** is the actual provisioned storage that satisfies a
  claim — on EKS, this is an EBS volume under the hood.
- A **StorageClass** is the template describing *how* to dynamically
  provision a PV when a PVC asks for one (which AWS disk type, filesystem,
  etc.) — you almost never hand-create PVs yourself; you create a PVC, and
  the StorageClass's provisioner creates a matching PV automatically.
**Where:** `04-postgres.yaml`'s `volumeClaimTemplates` — the StatefulSet
equivalent of a PVC, one auto-created per replica. See Section 5 for the
full walkthrough of this becoming a real EBS volume.

### Probes (liveness / readiness / startup)
Three questions Kubernetes can ask a container repeatedly, each answered
independently:
- **readinessProbe** — "should this pod receive traffic *right now*?" Fails
  → pod stays alive but is pulled out of its Service's rotation. Used on
  every app container here, hitting each service's existing `/health`
  route.
- **livenessProbe** — "is this container still working, or should it be
  killed and restarted?" Fails (repeatedly) → kubelet kills and restarts
  the container in place.
- **startupProbe** — not used in this app, but worth knowing: exists for
  containers with a slow startup, to avoid the liveness probe killing a
  container that's simply still booting. Not needed here since these are
  lightweight Node/Postgres processes with fast startup.
**Where:** `readinessProbe`/`livenessProbe` blocks in every Deployment and
the StatefulSet. Postgres uses `exec: pg_isready` instead of `httpGet`
since it doesn't speak HTTP.

### Resource requests & limits
`requests` is what a container is *guaranteed* (the scheduler uses this to
decide which node has room) — `limits` is the *ceiling* it can't exceed
(exceeding a memory limit gets a container killed with `OOMKilled`;
exceeding a CPU limit just throttles it, doesn't kill it). Compose has no
real equivalent that the scheduler actually enforces at placement time.
**Where:** `resources:` block in every container spec.

### Ingress + Ingress Controller
An Ingress object is a **declaration** of desired HTTP routing rules — by
itself it does nothing. An **Ingress Controller** (a piece of software you
install into the cluster, separate from Kubernetes core) watches for
Ingress objects and does the actual work of making them real. On EKS, that
controller is the **AWS Load Balancer Controller**, and "making it real"
means provisioning an actual AWS Application Load Balancer and keeping its
routing rules in sync with your Ingress object.
**Where:** `09-ingress.yaml`. Full walkthrough in Section 5.

### HorizontalPodAutoscaler (mentioned, not included)
Not in this app's manifests (kept out to keep the learning surface
focused), but worth knowing it exists: an HPA watches a metric (commonly
CPU %) on a Deployment and automatically adjusts `replicas` up or down
between a min/max you set — the automated version of the "bump replicas
during a traffic spike" scenario from Section 1. If you want to add it
later: `kubectl autoscale deployment api-gateway -n mern-todo --min=2
--max=10 --cpu-percent=70` (requires the `metrics-server` add-on, which
EKS can install as a managed add-on).

---

## 4. Deploying to AWS EKS, step by step

### Prerequisites (install once, on your own machine)
```bash
# AWS CLI - talks to AWS APIs generally
aws --version || curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"

# eksctl - the standard tool for creating/managing EKS clusters
eksctl version || brew install eksctl        # or see eksctl.io for your OS

# kubectl - talks to any Kubernetes cluster, not AWS-specific
kubectl version --client || brew install kubectl

# authenticate the AWS CLI with real credentials
aws configure
# AWS Access Key ID / Secret / default region (e.g. us-east-1) / output format (json)
```

### Step 1 — create an ECR repository per image, and push

ECR (Elastic Container Registry) is AWS's image registry — the EKS
equivalent of what your Docker Hub/local images were for plain Docker.
```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

for repo in auth-service todo-service api-gateway client; do
  aws ecr create-repository --repository-name mern-todo/$repo --region $AWS_REGION
done

aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# Build and push the three plain Node services
for svc in auth-service todo-service api-gateway; do
  docker build -t $ECR_REGISTRY/mern-todo/$svc:1.0 services/$svc
  docker push $ECR_REGISTRY/mern-todo/$svc:1.0
done

# Client is different: build with VITE_API_BASE_URL="" (empty, deliberately -
# see 08-client.yaml's comment for why this makes the single-Ingress
# path-based routing work)
docker build -t $ECR_REGISTRY/mern-todo/client:1.0 \
  --build-arg VITE_API_BASE_URL="" \
  client
docker push $ECR_REGISTRY/mern-todo/client:1.0
```

### Step 2 — create the EKS cluster

```bash
eksctl create cluster \
  --name mern-todo-cluster \
  --region $AWS_REGION \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed \
  --with-oidc
```
This single command does a lot: creates a dedicated VPC and subnets across
multiple Availability Zones, provisions the managed EKS control plane
(the whole top row from Section 2's diagram — you never touch it directly),
launches a managed node group of 2 EC2 instances as worker nodes, and
(because of `--with-oidc`) sets up an IAM OIDC identity provider for the
cluster — required by the next two steps, which both need to hand AWS IAM
permissions to specific in-cluster components without giving every pod on
the cluster god-mode AWS access. **Takes 15-20 minutes** — this is
provisioning real AWS infrastructure, not starting containers.

```bash
# Point kubectl at the new cluster (eksctl usually does this automatically,
# but if you switch machines/shells later):
aws eks update-kubeconfig --name mern-todo-cluster --region $AWS_REGION

kubectl get nodes    # should show 2 nodes, status Ready
```

### Step 3 — install the EBS CSI driver (needed for the postgres volume)

Without this, the `PersistentVolumeClaim` in `04-postgres.yaml` will sit
forever in `Pending`, unable to actually provision a disk.
```bash
# Give the driver's service account permission to manage EBS volumes on your behalf
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster mern-todo-cluster \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

eksctl create addon \
  --cluster mern-todo-cluster \
  --name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole \
  --force
```

### Step 4 — install the AWS Load Balancer Controller (needed for the Ingress)

Same story as the EBS driver: the Ingress object in `09-ingress.yaml` is
inert until something is watching for it. This is that something.
```bash
eksctl create iamserviceaccount \
  --cluster mern-todo-cluster \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve
# (if that IAM policy doesn't exist yet in your account, download and create
# it first - the exact command is in the AWS Load Balancer Controller docs,
# it's a one-time per-account setup)

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=mern-todo-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

### Step 5 — fill in your real values, then apply everything

```bash
cd k8s
sed -i "s#<ECR_REGISTRY>#$ECR_REGISTRY#g" 05-auth-service.yaml 06-todo-service.yaml 07-api-gateway.yaml 08-client.yaml
# Edit 02-secret.yaml by hand: set a real POSTGRES_PASSWORD and JWT_SECRET
# (and update DATABASE_URL's password to match - see Section 3's Secret note)

kubectl apply -f .
# Applies 00 through 09 in order - kubectl reads a directory's files in
# filename order, which is exactly why they're numbered.
```

### Step 6 — watch it come up, then get the public URL

```bash
kubectl get pods -n mern-todo -w
# watch STATUS go Pending -> ContainerCreating -> Running, and
# READY go 0/1 -> 1/1 as each readiness probe starts passing

kubectl get ingress -n mern-todo
# ADDRESS column fills in after a minute or two with something like
# k8s-mernto-mernto-xxxxxxxxxx-yyyyyyyyyy.us-east-1.elb.amazonaws.com
# - that's a real, working AWS Application Load Balancer. Open it in a
# browser - / serves the client, /api/... reaches api-gateway.
```

### Step 7 — redeploying after a code change

```bash
docker build -t $ECR_REGISTRY/mern-todo/auth-service:1.1 services/auth-service
docker push $ECR_REGISTRY/mern-todo/auth-service:1.1

kubectl set image deployment/auth-service \
  auth-service=$ECR_REGISTRY/mern-todo/auth-service:1.1 \
  -n mern-todo

kubectl rollout status deployment/auth-service -n mern-todo   # watch the rolling update happen
kubectl rollout undo deployment/auth-service -n mern-todo     # instantly revert, if the new version is bad
```

### Cleanup (important — this cluster costs real money while it exists)

```bash
kubectl delete -f k8s/         # deletes the app + its EBS volume (the PVC deletion also deletes the underlying EBS disk by default)
eksctl delete cluster --name mern-todo-cluster --region $AWS_REGION   # tears down EVERYTHING - nodes, control plane, VPC
```

---

## 5. Volumes, networking, ingress/load balancing, service-to-service communication

### Volumes — from `volumeClaimTemplates` to a real EBS disk

Walking through what actually happens for `postgres-0`'s storage:

```
04-postgres.yaml's volumeClaimTemplates
         │  (StatefulSet controller creates one PVC per replica, automatically)
         ▼
PersistentVolumeClaim "pgdata-postgres-0" (namespace mern-todo)
requests: 1Gi, ReadWriteOnce, no storageClassName specified
         │  (the "default" StorageClass - gp2, via the EBS CSI driver
         │   installed in Step 3 - picks this up automatically)
         ▼
StorageClass "gp2" (or "gp3" if you set it as default) dynamically
provisions a matching PersistentVolume
         │
         ▼
A real AWS EBS volume gets created in your account, in whichever
Availability Zone postgres-0's pod got scheduled to (EBS volumes are
zone-local - this is also why a StatefulSet's pod-to-volume binding
matters: if that pod gets rescheduled to a different AZ, Kubernetes has to
either move the pod back to the volume's AZ or the pod stays Pending)
         │
         ▼
Mounted into the postgres-0 pod at /var/lib/postgresql/data - from
Postgres's point of view, this looks exactly like local disk
```

**Do you need this, or could you skip persistence?** Without it, exactly
like Docker without the `pgdata` named volume: every time the `postgres-0`
pod is deleted and recreated (a routine event — node maintenance, cluster
upgrades, even just `kubectl delete pod`), you'd lose every user and every
todo. The volume is what makes pod replacement a non-event for your data.

**Check it yourself:**
```bash
kubectl get pvc -n mern-todo         # shows pgdata-postgres-0, Bound
kubectl get pv                       # the actual PersistentVolume, cluster-scoped (not namespaced)
kubectl describe pvc pgdata-postgres-0 -n mern-todo   # shows the underlying EBS volume ID
```

### Networking — how pods actually reach each other

Every pod gets its own real IP address, from a flat, cluster-wide network
(on EKS specifically, via the **AWS VPC CNI** — each pod effectively gets a
real VPC-routable IP, unlike some other Kubernetes networking setups that
use an overlay network). Pod IPs are **not stable** — a replaced pod gets a
new one — which is exactly why nothing in this app ever hardcodes a pod IP;
everything goes through a Service's stable name instead.

```
auth-service pod wants to call... nothing, actually - auth-service never
calls another service in this app. todo-service does, indirectly, via the
gateway. Here's api-gateway calling auth-service:

api-gateway pod ──DNS lookup──▶ "auth-service.mern-todo.svc.cluster.local"
                                  (or just "auth-service" - same namespace,
                                   short name resolves via search domains)
                                        │
                                CoreDNS (cluster's internal DNS server)
                                resolves this to the Service's ClusterIP
                                (a stable virtual IP, e.g. 10.100.45.12)
                                        │
                            traffic sent to that ClusterIP
                                        │
                     kube-proxy's iptables rules on api-gateway's OWN
                     node intercept it and rewrite the destination to
                     one of auth-service's actual pod IPs (round-robin
                     across however many are currently Ready)
                                        │
                              lands on a real auth-service pod
```

This is the direct Kubernetes analogue of Docker's "container name resolves
via the network's embedded DNS" — same underlying idea (name → stable
address → actual instance), implemented differently (CoreDNS + iptables
instead of Docker's embedded DNS server), and now working *across multiple
physical machines* instead of one Docker host.

### Do you need Ingress / a load balancer? Yes — and here's exactly why

Nothing in this app publishes a NodePort or gives any Service type
`LoadBalancer` directly. Every app Service is ClusterIP — meaning, by
itself, **completely unreachable from outside the cluster**, the same "no
`-p` flag = no path in" rule from the Docker README, just at the cluster
level instead of the container level.

The **Ingress + AWS Load Balancer Controller** combination is what
punches the one hole through: it provisions a real AWS ALB with a public
DNS name, and does path-based routing to the right internal Service:
```
Browser ──▶ ALB's public DNS name (e.g. k8s-mernto-...elb.amazonaws.com)
              │
              ├── path starts with /api  ──▶ api-gateway Service (:4000)
              └── everything else (/)    ──▶ client Service (:80)
```
This is exactly the same shape as the host-Nginx-in-front-of-Docker setup
from the Docker README (`todo.crashloop.in`) — one public entry point,
path-based routing to internal services — just running as a managed AWS
resource instead of a process you configured by hand on one server. You
could technically skip Ingress and give `client` and `api-gateway` each
their own `type: LoadBalancer` Service instead (that provisions one ALB per
Service), but that means two separate public addresses, two things to
secure/monitor, and no shared path-based routing — Ingress consolidating
to one is the standard real-world choice once you have more than one thing
to expose.

### How the app's Services actually connect to each other (the full map)

```
                 (public - via Ingress/ALB only)
Browser ──────────────┬───────────────────────┐
                       │ /                     │ /api/*
                       ▼                       ▼
              client Service            api-gateway Service
              (ClusterIP, :80)          (ClusterIP, :4000)
                       │                       │
                                    ┌───────────┴────────────┐
                                    ▼                        ▼
                          auth-service Service       todo-service Service
                          (ClusterIP, :4001)          (ClusterIP, :4002)
                                    │                        │
                                    └───────────┬────────────┘
                                                 ▼
                                       postgres Service
                                       (headless, :5432)
```
Every arrow above is a Service name (from a ConfigMap value or hardcoded in
the app), never a pod IP, never `localhost` between different app
components. `client`'s arrows to the browser aren't shown as Service calls
because the browser talks to it over plain HTTP through the Ingress, same
as with `api-gateway` — `client` and `api-gateway` never call each other
directly; the browser is the thing making both calls.

---

## 6. A request, end to end, under the hood

Following one real action — **submitting the Login form** — through every
layer, from browser to database and back. This is the same journey as the
Docker README's Section 7, one level up the stack.

```
1. Browser has already loaded the app from the ALB's public DNS name.
   User clicks Login. Browser JS calls fetch('/api/auth/login', {...}) -
   a RELATIVE path, because the client image was built with
   VITE_API_BASE_URL="" (see Section 4, Step 1). It resolves against
   whatever host the page was loaded from - the ALB - automatically.

2. Request hits the ALB (a real, physical-ish AWS load balancer, living
   outside the Kubernetes cluster entirely, in your VPC's public subnets).
   The ALB's listener rules - kept in sync with your Ingress object by the
   AWS Load Balancer Controller - match "/api/*" and forward to the
   api-gateway target group.

3. IMPORTANT DETAIL: because 09-ingress.yaml sets
   `alb.ingress.kubernetes.io/target-type: ip`, the ALB sends this request
   DIRECTLY to one of api-gateway's POD IPs - not through the ClusterIP
   Service, not through kube-proxy/iptables at all. (The alternative,
   target-type "instance", would route to a NodePort on some node and let
   kube-proxy do one more hop of load-balancing from there - "ip" mode
   skips that extra hop, which is why it's the recommended default when
   using the AWS VPC CNI, which is EKS's default networking mode.)

4. Request lands inside an api-gateway POD. Express's http-proxy-middleware
   looks at AUTH_SERVICE_URL from its environment (injected from the
   ConfigMap: "http://auth-service:4001") and forwards the request there.

5. "auth-service" is a DNS name now, resolved by CoreDNS (the cluster's
   internal DNS server, itself running as pods in kube-system) to the
   auth-service Service's ClusterIP.

6. Traffic to that ClusterIP gets intercepted by iptables rules that
   kube-proxy programmed on api-gateway's node - rewritten to the real pod
   IP of ONE of auth-service's currently-Ready replicas, chosen essentially
   at random (this is the actual load-balancing mechanism - there's no
   separate "load balancer process" for internal traffic, it's just
   iptables NAT rules, evaluated per-packet).

7. Request lands inside an auth-service pod. It reads DATABASE_URL from
   its environment (injected from the Secret) and opens a connection to
   "postgres:5432".

8. "postgres" resolves via CoreDNS again - this time to the headless
   Service, which (because it has no ClusterIP to load-balance through)
   returns the actual pod IP(s) directly. With one replica, there's only
   one answer: postgres-0's pod IP.

9. Request lands in the postgres-0 pod, reads/writes to
   /var/lib/postgresql/data - physically, an EBS volume attached to
   whichever EC2 instance postgres-0 is scheduled on.

10. Response flows all the way back the same path in reverse:
    postgres-0 -> auth-service pod -> (iptables NAT unwinds automatically,
    it's a stateful connection) -> api-gateway pod -> ALB -> browser.
```

**The single biggest structural difference from the Docker/Compose
version:** every hop above except step 1 and step 2 could be landing on a
**different physical machine** than the previous hop, and nothing in the
application code or configuration changes because of that. `AUTH_SERVICE_URL
=http://auth-service:4001` means exactly the same thing whether
`api-gateway` and `auth-service` happen to be co-located on the same node
or three availability zones apart — the Service abstraction (backed by
CoreDNS + kube-proxy) is what makes "which physical machine is this on"
completely irrelevant to the code calling it. That's the concrete payoff of
everything in Section 1: you get multi-machine reliability and scale
without the application needing to know or care that it's now
multi-machine.

---

*Continue reading `README.md` for the Docker/Compose version this builds
on, including the full Debugging & Troubleshooting section — most of that
still applies conceptually (mismatched credentials, missing readiness,
wrong hostnames), just replace `docker logs` with `kubectl logs`,
`docker exec` with `kubectl exec`, and `docker ps` with `kubectl get
pods -n mern-todo`.*
