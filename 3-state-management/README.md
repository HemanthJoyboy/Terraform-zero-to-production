# 03 — Terraform State Management

This module covers everything about how Terraform tracks the infrastructure it manages: what state is, why it exists, local vs. remote storage, locking to prevent conflicts, and how to set up a production-grade S3 remote backend.

## Contents

| File | What it covers |
|---|---|
| [`terraform-state.md`](./terraform-state.md) | What state is, why Terraform needs it, what's inside the state file, core state commands |
| [`local-vs-remote-state.md`](./local-vs-remote-state.md) | Local backend vs. remote backends, when to use each, migration between them |
| [`state-locking.md`](./state-locking.md) | Why concurrent applies are dangerous, how locking prevents corruption, DynamoDB locking mechanics |
| [`s3-backend.md`](./s3-backend.md) | Step-by-step: setting up an S3 + DynamoDB remote backend, bucket policies, encryption, versioning |
| [`examples/remote-backend/`](./examples/remote-backend/) | Working `.tf` code: creates the S3 bucket + DynamoDB table, and a sample config that uses them as a backend |

## Suggested Reading Order

```
terraform-state.md
        │
        ▼
local-vs-remote-state.md
        │
        ▼
state-locking.md
        │
        ▼
s3-backend.md
        │
        ▼
examples/remote-backend/  (hands-on)
```

## Why This Module Matters

State is the single most misunderstood — and most operationally critical — part of Terraform. Nearly every serious Terraform incident (corrupted infrastructure, two engineers overwriting each other's changes, "Terraform wants to destroy everything") traces back to a state management mistake. This module exists to make sure that never happens to you.
