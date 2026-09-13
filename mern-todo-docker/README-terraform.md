# Terraform Infrastructure for the MERN Todo App (real-world MNC pattern)

This document covers the `infra/` folder in this repo — the Terraform code
that provisions the actual AWS account resources (VPC, EKS cluster, node
groups, IAM, ECR) that `README-k8s.md`'s Kubernetes manifests then get
deployed onto. Read `README-k8s.md` first if you haven't — this picks up
right where "Step 2: create the EKS cluster" was previously a single
`eksctl` command, and turns it into proper, reviewable, environment-aware
Terraform.

```
mern-todo-docker/
├── README.md              # Docker / Compose
├── README-k8s.md          # Kubernetes manifests + concepts
├── README-terraform.md    # this file
├── k8s/                   # Kubernetes manifests (unchanged)
├── .github/workflows/     # CI/CD - see Section 6
│   ├── terraform-plan.yml
│   ├── terraform-apply.yml
│   └── app-deploy.yml
└── infra/                 # Terraform - this file's subject
    ├── bootstrap/
    ├── modules/
    ├── global/
    └── live/
```

**Table of contents**
1. [Where this actually starts: requirements, before any code](#1-where-this-actually-starts-requirements-before-any-code)
2. [Folder structure, walked through file by file](#2-folder-structure-walked-through-file-by-file)
3. [One cluster or three? The decision encoded in this repo](#3-one-cluster-or-three-the-decision-encoded-in-this-repo)
4. [Bootstrapping and deploying, in the actual order](#4-bootstrapping-and-deploying-in-the-actual-order)
5. [Making a change: the real workflow](#5-making-a-change-the-real-workflow)
6. [Why infra and app have separate pipelines — with the actual files](#6-why-infra-and-app-have-separate-pipelines--with-the-actual-files)

---

## 1. Where this actually starts: requirements, before any code

Nobody on a real platform team opens `main.tf` first. Before this `infra/`
folder existed, the actual first step was conversations across several
teams, each answering a specific question that then became a concrete
decision baked into this code:

| Question asked | Who answers it | What it became in this repo |
|---|---|---|
| How many environments, and how different are they? | App/product team | dev, test, prod — see `live/dev`, `live/test`, `live/prod` |
| Separate AWS accounts, or one account? | Security/compliance | This repo assumes separate accounts (see Section 3) — `assume_role` placeholders in each `live/*/*/main.tf` |
| What CIDR ranges are already in use elsewhere in the company? | Network/platform team | `10.0.0.0/16` (dev) / `10.1.0.0/16` (test) / `10.2.0.0/16` (prod) — chosen to never overlap, so future VPC peering is possible |
| What's prod's availability requirement? | SRE/on-call | 3 AZs + one NAT gateway per AZ for prod vs. 2 AZs + one shared NAT for dev/test — see `live/*/network/terraform.tfvars` |
| Mandatory tags for cost allocation? | Finance/FinOps | Every module accepts a `tags` map; every `live/*` root passes `Environment` and `ManagedBy` |
| Where does Terraform's own state live? | Platform team (usually decided once, for the whole org) | `infra/bootstrap/` — a real S3 bucket + DynamoDB table, provisioned once, manually |

**Nothing above is unique to Kubernetes or Terraform** — this is the same
discovery process for any real infrastructure project. What Terraform (and
this folder structure) buys you is a place to put the *answers* to these
questions as reviewable, versioned code, instead of tribal knowledge or a
wiki page that drifts out of date.

---

## 2. Folder structure, walked through file by file

```
infra/
├── bootstrap/
│   └── main.tf                       # RUN ONCE, MANUALLY. Creates the S3 bucket + DynamoDB table every other
│                                      # component's state lives in. Can't use a remote backend itself - nothing
│                                      # exists yet for it to point at (chicken-and-egg).
│
├── modules/                          # reusable building blocks - ZERO environment-specific values in here.
│   │                                  # Every value that differs between dev/test/prod is a variable, not a
│   │                                  # hardcoded literal. This is what lets one module serve all 3 environments.
│   ├── vpc/                {main,variables,outputs}.tf
│   ├── eks-cluster/        {main,variables,outputs}.tf
│   ├── node-group/         {main,variables,outputs}.tf
│   ├── irsa/               {main,variables,outputs}.tf   # generic - reused by BOTH addons below
│   ├── ebs-csi/            {main,variables}.tf            # calls modules/irsa internally
│   ├── alb-controller/     {main,variables}.tf, iam-policy.json   # calls modules/irsa internally
│   └── ecr/                {main,variables,outputs}.tf
│
├── global/
│   └── ecr-repos/main.tf             # calls modules/ecr ONCE - one shared registry, not one per environment.
│                                      # State key: global/ecr-repos/terraform.tfstate
│
└── live/                             # the actual, deployable environments
    ├── dev/
    │   ├── network/  {main,variables}.tf, terraform.tfvars   # calls modules/vpc.        state key: dev/network/...
    │   ├── eks/      {main,variables}.tf, terraform.tfvars   # calls modules/eks-cluster
    │   │                                                     # + modules/node-group.     state key: dev/eks/...
    │   └── k8s-addons/main.tf                                # calls modules/ebs-csi
    │                                                          # + modules/alb-controller. state key: dev/k8s-addons/...
    ├── test/       (identical shape to dev/, different terraform.tfvars values)
    └── prod/       (identical shape to dev/, different terraform.tfvars values,
                      and one real code difference: endpoint_public_access = false)
```

**What each layer is actually responsible for, and why they're split into
three separate state files per environment rather than one:**

- **`network`** — VPC, subnets, NAT gateways, route tables. Changes maybe
  a handful of times a year. If you ran `terraform apply` on the wrong
  file and it only has network resources in its state, the absolute worst
  case is networking breaks — it *cannot* accidentally delete your EKS
  cluster or node group, because those resources aren't in this state file
  at all.
- **`eks`** — the control plane + node group. Depends on `network`'s
  outputs (VPC ID, subnet IDs) via `data "terraform_remote_state"` — see
  `live/dev/eks/main.tf`. Changes more often (node count, instance type,
  Kubernetes version bumps).
- **`k8s-addons`** — the EBS CSI driver and ALB controller, both installed
  *inside* the cluster `eks` just created. Depends on `eks`'s outputs the
  same way. Changes most often of the three (controller version bumps,
  Helm chart updates).

Each depends on the one before it, strictly one direction — `network`
knows nothing about `eks`, `eks` knows nothing about `k8s-addons`. That's
what makes it safe to, say, re-run `k8s-addons`'s apply without any risk of
it touching your VPC.

**Where the actual per-environment differences live:** almost entirely in
`terraform.tfvars` files — 3-6 lines each. `main.tf` and `variables.tf` in
`live/dev/network` and `live/prod/network` are close to identical (only
the state `key` and hardcoded `name_prefix`/`Environment` tag differ) —
the module call is the same, only the numbers passed to it change. This is
deliberate: if the *logic* were different per environment, you'd have no
guarantee that what you tested in dev actually reflects what runs in prod.

---

## 3. One cluster or three? The decision encoded in this repo

`live/dev/eks`, `live/test/eks`, and `live/prod/eks` each call
`modules/eks-cluster` **once**, and each produces a completely separate
`aws_eks_cluster` resource — three real clusters, in what would be three
separate AWS accounts in a real deployment (see the `assume_role` comments
in each `live/*/*/main.tf` provider block). This isn't a shortcut taken to
keep the example simple — it's the actual industry-standard pattern, for
the reasons covered in depth in the earlier conversation on this repo:
blast-radius isolation, independent upgrade cadence, hard IAM boundaries,
and clean cost tracking per environment.

**What you can see concretely, comparing the tfvars:**

| | dev | test | prod |
|---|---|---|---|
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` | `10.2.0.0/16` |
| Availability Zones | 2 | 2 | 3 |
| NAT gateways | 1 shared | 1 shared | 1 per AZ |
| Node instance type | `t3.medium` | `t3.medium` | `m5.xlarge` |
| Node capacity type | SPOT | ON_DEMAND | ON_DEMAND |
| Node count (desired/min/max) | 2 / 2 / 4 | 2 / 2 / 4 | 6 / 6 / 12 |
| EKS API endpoint | public | public | **private only** |

That last row is the one real *behavioral* difference, not just sizing:
`live/prod/eks/main.tf` sets `endpoint_public_access = false`, meaning
`kubectl` against prod only works from inside the VPC (via VPN or a
bastion) — a deliberate hardening step that dev/test skip to keep
day-to-day work simple. This is exactly the kind of difference that
namespace-based "isolation" inside one shared cluster could never express
— there's no such thing as "this namespace has a private-only API server."

---

## 4. Bootstrapping and deploying, in the actual order

```bash
# ONE-TIME, for the whole org - not per environment
cd infra/bootstrap
terraform init
terraform apply
# note the bucket name it creates, then replace every
# "mern-todo-terraform-state-CHANGE-ME" placeholder across infra/ with it

# ONE-TIME per environment's AWS account
# (create the ECR registry - shared, so this only needs doing once total)
cd infra/global/ecr-repos
terraform init && terraform apply

# THEN, per environment, strictly in this order (each depends on the last):
cd infra/live/dev/network
terraform init && terraform apply

cd ../eks
terraform init && terraform apply
# this step alone takes 15-20 minutes - it's provisioning a real EKS control plane

cd ../k8s-addons
terraform init && terraform apply

# Now point kubectl at it and deploy the actual application:
aws eks update-kubeconfig --name mern-todo-dev --region us-east-1
kubectl apply -f ../../../../k8s/
```

Repeat the `live/dev/...` block with `live/test/...` and `live/prod/...`
once dev is verified working — never skip straight to prod. This exact
sequence is what `.github/workflows/terraform-apply.yml` automates (see
Section 6) — the manual commands above are what that workflow is running
on your behalf, environment by environment, job by job.

**One placeholder you must fill in before any of this works for real:**
`infra/modules/alb-controller/iam-policy.json` is a stub. Before applying
`k8s-addons` anywhere, replace it with the real, current AWS-published
policy:
```bash
curl -o infra/modules/alb-controller/iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```
It's fetched from upstream rather than hand-written because AWS updates
this policy as the controller gains features — pinning a stale copy in
this repo would go stale.

---

## 5. Making a change: the real workflow

Say you need to bump prod's max node count from 12 to 20 ahead of an
expected traffic spike. Here's exactly what happens, file by file:

1. **Branch, edit one file:** `infra/live/prod/eks/terraform.tfvars`,
   change `max_size = 12` to `max_size = 20`. You do not touch `main.tf`
   or `variables.tf` — the module already supports this, only the input
   changes.
2. **Open a PR.** `terraform-plan.yml` (Section 6) runs automatically,
   authenticates to the **prod AWS account specifically** (via
   `secrets.AWS_ROLE_PROD`, scoped only to that one matrix entry), and
   posts the plan as a PR comment — reviewers see `1 to change, 0 to add,
   0 to destroy` before approving, not after.
3. **Review.** Because this touches `infra/live/prod/**`, a CODEOWNERS
   rule (configured separately, in `.github/CODEOWNERS`) requires sign-off
   from the platform team specifically, not just any teammate.
4. **Merge.** `terraform-apply.yml` runs — `apply-dev` and `apply-test`
   jobs run first automatically (this specific tfvars change doesn't touch
   them, so their `terraform apply` is a no-op, but the jobs still run, as
   part of the standard promotion order), then `apply-prod` — which
   **pauses and waits** for a specific person to click Approve in GitHub's
   Environment protection UI, because `apply-prod`'s job declares
   `environment: prod-infra`.
5. **State locking** (the DynamoDB table from `bootstrap/`) means if
   someone else's PR also touches `live/prod/eks` and merges around the
   same time, the second apply queues instead of racing the first.

**What you'd never do in a real setup:** SSH into a node and change the
autoscaling group by hand in the AWS Console. Even if it's faster in the
moment, the next `terraform apply` would detect that drift and either
silently revert your manual change back to `max_size = 12`, or — worse —
show a confusing plan that doesn't match what anyone expects. Every change
goes through this file, every time, specifically so `terraform plan`
always tells the truth about what's about to happen.

---

## 6. Why infra and app have separate pipelines — with the actual files

Three workflow files exist under `.github/workflows/`, split exactly along
the infra/app line described earlier in this project:

```
.github/workflows/
├── terraform-plan.yml    # triggers on: pull_request touching infra/**
├── terraform-apply.yml   # triggers on: push to main touching infra/**
└── app-deploy.yml        # triggers on: push to main touching services/** or client/**
```

**`terraform-plan.yml`** — runs `fmt`/`validate`/`plan` for every
environment × component combination, each authenticated with a
**separate, narrowly-scoped AWS role per environment**
(`AWS_ROLE_DEV`/`AWS_ROLE_TEST`/`AWS_ROLE_PROD`) — a PR that only intended
to touch dev physically cannot plan against the prod account's
credentials, because the workflow picks the role based on which matrix
entry is running, and each role is scoped (via IAM trust policy, outside
this repo) to only that one AWS account.

**`terraform-apply.yml`** — runs on merge, applies dev automatically, then
test, then prod — and prod's job has `environment: prod-infra`, which is
what makes the GitHub required-reviewer gate from Section 5 actually real,
not just documentation. This is the concrete mechanism behind "prod
deployments need manual approval" — it's a checkbox in Settings →
Environments, not a policy someone has to remember to follow.

**`app-deploy.yml`** — notice everything different about it:
- Triggers on `services/**`/`client/**`, never `infra/**` — an infra PR
  never runs this, an app code PR never runs the two files above it.
- Uses `AWS_ROLE_APP_DEPLOY`, a role that can push to ECR and run
  `kubectl set image` — and nothing resembling `eks:CreateCluster` or
  `ec2:CreateVpc`. A compromised or buggy app pipeline literally cannot
  provision or delete infrastructure, by IAM policy, not by convention.
- No `environment:` gate, no manual approval — it's expected to run many
  times a day, safely, because a bad app deploy is a `kubectl rollout undo`
  away from being fixed, unlike a bad VPC change.
- Deploys straight to dev on every merge; promoting the same image tag to
  test/prod is deliberately a separate, manually-triggered step (a
  `workflow_dispatch` or tag-based release workflow) — left out of this
  example to keep the infra-vs-app contrast the focus, but the same
  environment-promotion principle from Section 5 applies here too: the
  same built image gets promoted, never rebuilt per environment.

**The one-sentence version, if you remember nothing else:** app code and
infrastructure code differ in blast radius, reviewer expertise, and
reversibility — different enough that in every real MNC setup, they get
different repos or at minimum different pipelines, different IAM roles,
and different approval gates, even when (as here) they end up deploying to
the exact same Kubernetes cluster.
