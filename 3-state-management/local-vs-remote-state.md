# Local vs. Remote State

Terraform supports storing state in different places, controlled by the **backend** configuration. The two broad categories are **local** and **remote**.

## Local State (the default)

If you don't configure a backend at all, Terraform stores state as a plain file, `terraform.tfstate`, in your current working directory.

```
your-project/
├── main.tf
├── variables.tf
└── terraform.tfstate     <-- lives right here, on your machine
```

### How it works
```
terraform apply
      │
      ▼
Terraform Core reads/writes -> ./terraform.tfstate (local disk)
```

### Pros
- Zero setup — works immediately, nothing to configure.
- Fine for solo learning, personal projects, throwaway experiments.

### Cons
- **Not shareable** — lives only on your machine. A teammate running `terraform apply` has no idea what you already created.
- **No locking** — two people (or you, from two terminals) running `apply` at the same time can corrupt the file or create duplicate/conflicting resources.
- **Not durable** — if your laptop dies or the disk is wiped, your *only* record of what exists is gone (the infrastructure itself still exists in AWS, but Terraform "forgets" about it — you'd have to `import` everything back).
- **Security risk** — the file often contains secrets in plaintext, sitting unencrypted on a laptop or CI runner's disk.

## Remote State

With a remote backend, Terraform stores the state file in a shared, durable, often-encrypted location — commonly:

| Backend | Typical Use Case |
|---|---|
| `s3` (+ DynamoDB for locking) | Classic, most common AWS setup |
| `azurerm` | Azure Storage Account container |
| `gcs` | Google Cloud Storage bucket |
| `remote` (Terraform Cloud/Enterprise) | HashiCorp-managed state + locking + remote execution + policy checks |
| `consul` | HashiCorp Consul KV store (less common today) |

### How it works

```
                     ┌─────────────────────────┐
   Engineer A  ────► │                         │ ◄──── Engineer B
                     │   Remote Backend         │
   CI/CD Pipeline ─► │   (e.g. S3 bucket)      │ ◄──── CI/CD Pipeline
                     │   terraform.tfstate      │
                     └─────────────────────────┘
```

Everyone — every human and every automated pipeline — reads and writes the **same** state file, so everyone has a consistent view of what infrastructure exists.

### Pros
- **Shared source of truth** across the whole team.
- **Locking support** (e.g., via DynamoDB) prevents simultaneous applies from corrupting state — see `state-locking.md`.
- **Durability** — S3/GCS/Azure Storage have built-in replication and versioning; losing your laptop doesn't lose your state.
- **Encryption at rest** — remote backends typically support server-side encryption.
- **Access control** — IAM policies restrict who can read/write state (important since state may contain secrets).
- **Enables automation** — CI/CD pipelines can run Terraform without needing someone's local state file.

### Cons
- Slightly more setup (you need to create the bucket/table first — see `s3-backend.md`).
- Requires network access to the backend to run any Terraform command.

## Configuration Example

**Local (default) — no backend block needed:**
```hcl
# nothing to write — this is what happens if you omit a backend block
```

**Remote (S3):**
```hcl
terraform {
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "projects/webapp/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

## Migrating from Local to Remote

If you started with local state and want to move to remote (a very common real-world step):

1. Create the S3 bucket + DynamoDB table (see `s3-backend.md`).
2. Add the `backend "s3" { ... }` block to your `terraform` configuration block.
3. Run:
   ```bash
   terraform init
   ```
4. Terraform detects the backend change and asks:
   ```
   Do you want to copy existing state to the new backend?
     Enter "yes" to copy and "no" to start with an empty state.
   ```
5. Type `yes`. Terraform copies your local `terraform.tfstate` content into the S3 bucket.
6. Verify with `terraform state list` — you should see the same resources as before.
7. You can now safely delete (or `.gitignore`) the local `terraform.tfstate` file — the S3 bucket is the source of truth going forward.

## Decision Guide

```
Are you the only person ever running Terraform, on one machine, for a throwaway/learning project?
        │
        ├── YES ──► Local state is fine
        │
        └── NO  ──► Use a remote backend (S3 + DynamoDB, or Terraform Cloud)
                     - Any team project
                     - Anything running in CI/CD
                     - Anything you care about not losing
                     - Anything with more than one contributor
```

## Next
Read [`state-locking.md`](./state-locking.md) to understand *why* remote backends need locking, and how it actually works.
