# Setting Up an S3 Remote Backend (Step-by-Step)

This document walks through creating a production-ready S3 + DynamoDB remote backend for Terraform state, and wiring your project to use it.

## Why S3 + DynamoDB Specifically?

- **S3** — durable, versioned, encryptable object storage; the industry-standard place to park a Terraform state file on AWS.
- **DynamoDB** — provides the locking mechanism S3 lacks natively (see `state-locking.md`).

## The Chicken-and-Egg Problem

You need an S3 bucket and DynamoDB table to *store* your state — but creating them *is itself* infrastructure. The standard solution: create these two resources using Terraform **with local state** (a one-time "bootstrap" step), then switch your *other* projects to use them as a remote backend.

```
Step 1: Bootstrap project (local state)
    │  creates S3 bucket + DynamoDB table
    ▼
Step 2: Your real projects (remote state)
    │  point their backend config at the bucket/table created in Step 1
    ▼
All future applies use the shared, locked, remote state
```

## Step 1: Create the Backend Infrastructure (Bootstrap)

In a small, separate directory (e.g. `bootstrap/`), with **local** state:

```hcl
# bootstrap/main.tf
provider "aws" {
  region = "ap-south-1"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "my-company-terraform-state"   # must be globally unique across all of AWS

  lifecycle {
    prevent_destroy = true   # safety net: refuse to destroy this via `terraform destroy`
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"   # keeps every past version of the state file — lets you roll back
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Run it:
```bash
cd bootstrap
terraform init
terraform apply
```

This creates the bucket and lock table using ordinary **local** state (stored right there in `bootstrap/terraform.tfstate` — that's fine and expected; this bootstrap project is small, rarely changed, and typically only ever run by one or two senior engineers).

## Step 2: Point Your Real Project at the New Backend

In your actual project (e.g., `webapp/`):

```hcl
# webapp/backend.tf
terraform {
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "webapp/terraform.tfstate"     # unique path per project
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

- **`bucket`** — the S3 bucket created in Step 1.
- **`key`** — the "file path" inside the bucket for *this specific project's* state. Different projects use different keys so they don't collide, e.g. `networking/terraform.tfstate`, `webapp/terraform.tfstate`, `database/terraform.tfstate`.
- **`dynamodb_table`** — the lock table from Step 1.
- **`encrypt`** — ensures the state object itself is encrypted at rest in S3.

Then initialize:
```bash
terraform init
```

If this project previously had local state, Terraform will prompt to migrate it:
```
Do you want to copy existing state to the new backend?
  Enter "yes" to copy and "no" to start with an empty state.
```

## Step 3: Verify

```bash
terraform state list
```
This should now read from S3, not from a local file. You can also check the AWS Console → S3 → your bucket → you'll see an object at `webapp/terraform.tfstate`.

Try acquiring a lock manually to confirm it's wired up — run `terraform plan` in two terminals at once; the second one should show the "Error acquiring the state lock" message from `state-locking.md`.

## Recommended Bucket Structure for Multiple Projects/Environments

```
s3://my-company-terraform-state/
├── networking/
│   ├── dev/terraform.tfstate
│   ├── staging/terraform.tfstate
│   └── prod/terraform.tfstate
├── webapp/
│   ├── dev/terraform.tfstate
│   ├── staging/terraform.tfstate
│   └── prod/terraform.tfstate
└── database/
    ├── dev/terraform.tfstate
    ├── staging/terraform.tfstate
    └── prod/terraform.tfstate
```

Corresponding backend key:
```hcl
backend "s3" {
  bucket = "my-company-terraform-state"
  key    = "webapp/prod/terraform.tfstate"
  region = "ap-south-1"
  dynamodb_table = "terraform-locks"
  encrypt = true
}
```

One DynamoDB table can safely be shared across **all** of these — the `LockID` DynamoDB uses is derived from the full bucket+key path, so locks never collide between different projects/environments.

## IAM Permissions Needed

Whoever (or whatever CI role) runs Terraform needs at minimum:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-company-terraform-state",
        "arn:aws:s3:::my-company-terraform-state/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:ap-south-1:<account-id>:table/terraform-locks"
    }
  ]
}
```

## Common Gotchas

| Issue | Cause / Fix |
|---|---|
| `BucketAlreadyExists` | S3 bucket names are globally unique across *all* AWS accounts — pick a more specific name (e.g., include your company + a random suffix) |
| `AccessDenied` on init | The IAM identity running Terraform lacks the S3/DynamoDB permissions above |
| State not updating between team members | Check everyone is using the exact same `bucket` + `key` — a typo creates a *separate* state file silently |
| Accidentally deleted the S3 state object | This is why **versioning** is enabled — restore the previous version from the bucket's version history |
| `Error: Backend configuration changed` | You edited the `backend` block — re-run `terraform init -reconfigure` |

## Next
See working, ready-to-run code for this exact setup in [`examples/remote-backend/`](./examples/remote-backend/).
