# Create an EC2 Instance Using Terraform — Step-by-Step Guide

This guide walks you through installing Terraform **on your existing EC2 machine** and using it to launch a **new EC2 instance**, end-to-end. Follow the steps in order.

---

## Prerequisites

- An EC2 instance already running (Amazon Linux 2023 assumed — Ubuntu commands noted where different) that you can SSH into.
- That EC2 instance needs permission to talk to the AWS API — see **Step 4** for two ways to do this.
- Basic comfort with the Linux terminal.

---

## Overview of What We're Doing

```
Your Practice EC2 (has Terraform installed)
        |
        |  terraform apply
        v
   AWS API  ---->  New EC2 Instance created (this is what Terraform manages)
```

You are **not** installing Terraform on AWS itself — you install the Terraform CLI binary on your practice EC2 machine, and Terraform then calls AWS's API to create a **separate, new** EC2 instance for you.

---

## Step 1: SSH into Your Practice EC2 Instance

```bash
ssh -i /path/to/your-key.pem ec2-user@<your-ec2-public-ip>
```

(Use `ubuntu@` instead of `ec2-user@` if it's an Ubuntu AMI.)

---

## Step 2: Install Terraform on the EC2 Instance

### For Amazon Linux 2023 / Amazon Linux 2 / RHEL / CentOS (yum-based)

```bash
sudo yum install -y yum-utils shadow-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform
```

### For Ubuntu / Debian (apt-based)

```bash
sudo apt update && sudo apt install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

### Manual method (works on any Linux, if the repo approach fails)

```bash
# Check latest version at https://developer.hashicorp.com/terraform/install
curl -O https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
sudo yum install -y unzip   # or: sudo apt install -y unzip
unzip terraform_1.9.8_linux_amd64.zip
sudo mv terraform /usr/local/bin/
rm terraform_1.9.8_linux_amd64.zip
```

### Verify installation

```bash
terraform -version
```

You should see output like:
```
Terraform v1.9.8
on linux_amd64
```

---

## Step 3: Give Your EC2 Instance Permission to Call AWS APIs

Terraform needs AWS credentials to create resources on your behalf. Pick **one** option.

### ✅ Option A (Recommended): Attach an IAM Role to the EC2 Instance

This is the safest method — no access keys stored on disk.

1. Go to **AWS Console → IAM → Roles → Create role**.
2. Trusted entity: **AWS service → EC2**.
3. Attach policy: `AmazonEC2FullAccess` (for practice/learning; in real projects use a narrower custom policy).
4. Name it e.g. `terraform-ec2-role` and create it.
5. Go to **EC2 Console → select your practice instance → Actions → Security → Modify IAM role → attach `terraform-ec2-role`**.

That's it — Terraform running on this EC2 instance will automatically pick up credentials from the **instance metadata service**, no extra config needed.

### Option B: Use an IAM User's Access Keys (simpler to understand, less secure)

1. **AWS Console → IAM → Users → your user → Security credentials → Create access key**.
2. On the EC2 instance, install the AWS CLI (if not already present) and configure it:

```bash
# Amazon Linux
sudo yum install -y awscli
# Ubuntu
sudo apt install -y awscli

aws configure
# AWS Access Key ID:     <paste>
# AWS Secret Access Key: <paste>
# Default region name:   ap-south-1
# Default output format: json
```

This writes credentials to `~/.aws/credentials`, which Terraform reads automatically.

> ⚠️ Never commit access keys to Git. Option A (IAM role) avoids this risk entirely and is what real projects use.

---

## Step 4: Create Your Terraform Project Directory

```bash
mkdir -p ~/terraform-ec2-demo
cd ~/terraform-ec2-demo
```

You'll create these files inside it (all provided in this project — see the accompanying `.tf` files):

```
terraform-ec2-demo/
├── providers.tf      # tells Terraform which cloud + region to use
├── variables.tf      # input parameters (region, instance type, etc.)
├── main.tf           # the actual EC2 instance + security group + key pair
├── outputs.tf         # values printed after creation (public IP, etc.)
└── terraform.tfvars  # your actual values for the variables (optional)
```

Copy the 5 files provided alongside this guide into `~/terraform-ec2-demo/` on your EC2 instance (e.g. via `scp`, or just create them with `nano`/`vim` and paste the content).

Example using `scp` from your local machine:
```bash
scp -i your-key.pem ./providers.tf ./variables.tf ./main.tf ./outputs.tf ./terraform.tfvars \
    ec2-user@<your-ec2-public-ip>:~/terraform-ec2-demo/
```

---

## Step 5: Understand What Each File Does (read before applying)

| File | Purpose |
|---|---|
| `providers.tf` | Declares we're using the AWS provider and which region |
| `variables.tf` | Declares configurable inputs (region, instance type, AMI, project name) with sensible defaults |
| `main.tf` | Defines the actual resources: a security group (allows SSH) + a new key pair (auto-generated) + the EC2 instance itself |
| `outputs.tf` | Prints the new instance's public IP and SSH command after apply |
| `terraform.tfvars` | Where you can override defaults (e.g., change instance_type to t3.micro) without editing the other files |

The `main.tf` in this project **auto-generates a brand-new SSH key pair** for you (using the `tls_private_key` resource) and saves the private key locally as `new-ec2-key.pem`, so you don't need to create a key pair manually in the console first.

---

## Step 6: Initialize Terraform

```bash
cd ~/terraform-ec2-demo
terraform init
```

This downloads the AWS provider plugin (and the `tls` and `local` provider plugins used for key-pair generation). You'll see:

```
Terraform has been successfully initialized!
```

---

## Step 7: Preview the Plan

```bash
terraform plan
```

Review the output carefully — it should show something like:

```
Plan: 3 to add, 0 to change, 0 to destroy.
```

(3 resources: the EC2 instance, the security group, and the key pair.)

---

## Step 8: Apply — Actually Create the EC2 Instance

```bash
terraform apply
```

Terraform will show the plan again and prompt:

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value:
```

Type `yes` and press Enter.

After a minute, you'll see:

```
Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

Outputs:

instance_public_ip = "13.234.xx.xx"
ssh_command = "ssh -i new-ec2-key.pem ec2-user@13.234.xx.xx"
```

---

## Step 9: Verify

1. **AWS Console → EC2 → Instances** — you should see a new instance named `terraform-demo-instance`.
2. Secure and use the auto-generated private key, then SSH into your **new** instance:

```bash
chmod 400 new-ec2-key.pem
ssh -i new-ec2-key.pem ec2-user@<instance_public_ip_from_output>
```

You are now inside the EC2 instance that **Terraform created for you** — separate from the practice EC2 machine you ran Terraform on.

---

## Step 10: Clean Up (Important — Avoid Ongoing Charges)

When you're done practicing, destroy the resources Terraform created:

```bash
terraform destroy
```

Confirm with `yes`. This removes the new EC2 instance, its security group, and key pair — but leaves your original practice EC2 machine (where Terraform is installed) untouched, since that one was never managed by this Terraform config.

---

## Quick Command Recap

```bash
# One-time setup
terraform -version          # confirm install
terraform init              # download providers

# Every time you change .tf files
terraform plan               # preview
terraform apply              # create/update
terraform destroy            # tear down when done
```

---

## Common Issues & Fixes

| Problem | Fix |
|---|---|
| `Error: No valid credential sources found` | Complete Step 3 (attach IAM role or run `aws configure`) |
| `UnauthorizedOperation` when applying | Your IAM role/user policy doesn't have EC2 permissions — attach `AmazonEC2FullAccess` (or a scoped policy) |
| `Error: InvalidAMIID.NotFound` | The AMI ID in `variables.tf` doesn't exist in your region — the provided config uses a **data source** to auto-find the latest Amazon Linux AMI, so this shouldn't happen unless you hardcode an AMI ID yourself |
| Terraform hangs on `apply` | Check your security group / VPC config; also check AWS Console → EC2 → Instances for the actual status |
| `terraform: command not found` after install | Re-check Step 2, or restart your shell session (`source ~/.bashrc`) |

---

You're all set. Next time, you'll only need Steps 6–10 (init → plan → apply → verify → destroy) since Terraform is already installed and your `.tf` files already exist.
