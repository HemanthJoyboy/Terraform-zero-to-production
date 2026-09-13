# How to Add Remote State + State Locking to Your Existing EC2 Terraform Setup

A simple guide for when you already have an EC2 instance created with Terraform (using local state), and want to move it to remote state with locking.

---

## What We're Doing (In Simple Terms)

Right now, your `terraform.tfstate` file — the file that keeps track of your EC2 instance — lives only on your machine.

**Goal:** Move that file to Amazon S3 (so it's safe and shareable), and add a "lock" (using DynamoDB) so two people can't run Terraform at the same time and break things.

```
BEFORE:  terraform.tfstate  →  sits on your local disk only

AFTER:   terraform.tfstate  →  sits in an S3 bucket (safe, shared)
                            →  protected by a DynamoDB lock
```

---

## Step 1: Create a New Folder for the Backend Setup

This is a one-time setup step. Keep it separate from your EC2 project.

```bash
mkdir ~/backend-setup
cd ~/backend-setup
```

---

## Step 2: Create the S3 Bucket + Lock Table (Write the Code)

Create a file called `main.tf` inside `~/backend-setup/`:

```hcl
provider "aws" {
  region = "ap-south-1"
}

resource "aws_s3_bucket" "state_bucket" {
  bucket = "yourname-terraform-state-2026"   # must be unique, change this
}

resource "aws_s3_bucket_versioning" "state_bucket" {
  bucket = aws_s3_bucket.state_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_dynamodb_table" "lock_table" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

> `aws_s3_bucket` = where the state file will live.
> `aws_dynamodb_table` = the "lock" that stops two people applying at once.

---

## Step 3: Create the Bucket and Table

```bash
terraform init
terraform apply
```

Type `yes` when asked. Wait for it to finish — this creates the bucket and the lock table in your AWS account.

---

## Step 4: Go to Your EC2 Project Folder

```bash
cd ~/terraform-ec2-demo
```

(This is the folder where you already have `main.tf` for your EC2 instance.)

---

## Step 5: Tell Terraform to Use the S3 Bucket

Create a new file here called `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "yourname-terraform-state-2026"   # same name as Step 2
    key            = "ec2-demo/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

This file just says: **"store my state in this bucket, and use this table for locking."**

---

## Step 6: Re-run Init to Switch to Remote State

```bash
terraform init
```

Terraform will ask:

```
Do you want to copy existing state to the new backend?
  Enter "yes" to copy and "no" to start with an empty state.
```

Type **`yes`**.

Your EC2 instance's state now moves from your local file into the S3 bucket. Nothing changes about the EC2 instance itself — only *where the record of it lives*.

---

## Step 7: Check It Worked

```bash
terraform state list
```

You should see your EC2 instance listed, same as before.

Then go to **AWS Console → S3 → your bucket** — you'll see a file there named `ec2-demo/terraform.tfstate`.

You can now delete the old local copy:

```bash
rm terraform.tfstate terraform.tfstate.backup
```

---

## What Is State Locking? (Simple Explanation)

**Problem:** If two people run `terraform apply` at the same time, they can overwrite each other's changes and confuse Terraform about what actually exists.

**Solution:** Before Terraform makes any change, it "locks" the state — like taking the only key to a door. Nobody else can apply until the lock is released.

```
Person A runs apply  →  🔒 Lock taken
Person B runs apply  →  ❌ "Error: state is locked" (has to wait)
Person A finishes     →  🔓 Lock released
Person B can now apply
```

This is exactly what the DynamoDB table from Step 2 does — it holds the lock.

---

## Step 8: Test the Lock (Optional but Fun)

Open **two terminal windows** into your EC2 machine.

**Terminal 1:**
```bash
cd ~/terraform-ec2-demo
terraform apply
```
Don't type `yes` yet — leave it waiting.

**Terminal 2 (while Terminal 1 is still waiting):**
```bash
cd ~/terraform-ec2-demo
terraform plan
```

Terminal 2 should show an error like:

```
Error: Error acquiring the state lock
```

That confirms locking is working — Terraform is stopping a second command from running while the first one is still in progress.

---

## Summary

| Step | What Happened |
|---|---|
| 1–3 | Created an S3 bucket (to store state) and a DynamoDB table (to lock it) |
| 4–6 | Told your EC2 project to use that bucket instead of a local file |
| 7 | Confirmed the state moved successfully |
| 8 | Proved the lock stops two people applying at once |

Your EC2 infrastructure is untouched — only how Terraform tracks and protects its own records has changed.
