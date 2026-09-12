# Example: Remote Backend (S3 + DynamoDB)

Working Terraform code for the setup described in [`../../s3-backend.md`](../../s3-backend.md).

## Folder Contents

```
remote-backend/
├── README.md              # this file
├── bootstrap/              # Step 1: creates the S3 bucket + DynamoDB table (uses LOCAL state)
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── app/                     # Step 2: an example project that USES the remote backend created above
    ├── backend.tf
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    └── outputs.tf
```

## How to Run This Example

### 1. Bootstrap the backend infrastructure (one-time, run this first)

```bash
cd bootstrap
terraform init
terraform apply
```

Note the outputs — you'll see the bucket name and DynamoDB table name printed. If you changed `bucket_name` in `bootstrap/variables.tf`, update `app/backend.tf` to match.

> This step intentionally uses **local** state — it's the "chicken and egg" bootstrap step explained in `s3-backend.md`. Keep this `bootstrap/terraform.tfstate` file safe (or migrate it to remote state too, once the bucket exists, if you want full consistency).

### 2. Use the remote backend in a real project

```bash
cd ../app
terraform init
terraform plan
terraform apply
```

`app/backend.tf` already points at the bucket/table created in step 1. After `terraform init`, check:

```bash
terraform state list
```

Then look in the AWS Console → S3 → your bucket — you'll see the state object at the path defined by `key` in `backend.tf`.

### 3. Test locking

Open two terminals in `app/`, and run `terraform apply` in both at (roughly) the same time. The second one should fail fast with:
```
Error: Error acquiring the state lock
```
This confirms DynamoDB locking is working.

### 4. Clean up

```bash
# tear down the example app resources first
cd app
terraform destroy

# then the bootstrap backend infra (only if you're fully done experimenting)
cd ../bootstrap
terraform destroy
```

> ⚠️ The bootstrap `main.tf` sets `prevent_destroy = true` on the S3 bucket as a safety measure (mirroring real-world practice, where you never want to accidentally delete your team's entire state history). You'll need to remove that lifecycle block before `terraform destroy` will succeed on it — this is deliberate friction, not a bug.
