# Terraform State — Deep Dive

## What Is Terraform State?

Terraform state is a **JSON file** (by default named `terraform.tfstate`) that Terraform creates and maintains to keep track of every resource it manages. It is the "source of truth" that maps your human-readable configuration (`.tf` files) to the real, physical resources that exist in the cloud.

```
Your Config                    State File                      Real World
─────────────                  ──────────                      ──────────
resource "aws_instance"   -->  aws_instance.web ->      -->    EC2 instance
"web" { ... }                  { id: "i-0abc123",              i-0abc123
                                  ami: "ami-xyz",
                                  public_ip: "3.1.2.3",
                                  ... }
```

Without state, Terraform would have **no way of knowing**:
- Which real-world resources correspond to which blocks in your `.tf` files
- What attributes those resources currently have (so it can detect drift)
- What order resources were created in (for correct destroy ordering)
- What to delete when you remove a resource block from your code

## Why Does Terraform Need State?

### 1. Mapping configuration to reality
Cloud APIs don't know anything about your `.tf` files. When you write:
```hcl
resource "aws_instance" "web" {
  ami           = "ami-0c101f26f147fa7fd"
  instance_type = "t2.micro"
}
```
AWS just sees "create an EC2 instance" and returns an ID like `i-0abc123def456`. Terraform stores that ID in state under the key `aws_instance.web` — that's the *only* link between your code and that specific real resource.

### 2. Performance
Without state, Terraform would need to query every single resource from the cloud API on every command, for every resource in your configuration. For large infrastructures (hundreds/thousands of resources), that would be extremely slow. State acts as a cache Terraform trusts (and optionally refreshes) instead of always calling the API fresh.

### 3. Detecting drift
On `terraform plan`, Terraform (by default) does a "refresh" — it re-checks real infrastructure against what's recorded in state, and flags any manual changes ("drift") someone made outside of Terraform — e.g., someone changed an instance's tag directly in the console.

### 4. Dependency tracking
State stores a dependency graph so Terraform destroys/updates resources in the correct order — e.g., delete an EC2 instance before deleting the subnet it lives in.

### 5. Enabling collaboration
When state is stored remotely (see `local-vs-remote-state.md`), every team member and every CI/CD pipeline run works from the **same shared source of truth**, rather than each having their own disconnected view of "what exists."

## What's Actually Inside a State File?

A simplified look at `terraform.tfstate`:

```json
{
  "version": 4,
  "terraform_version": "1.9.8",
  "serial": 3,
  "lineage": "a1b2c3d4-...",
  "outputs": {
    "instance_public_ip": {
      "value": "3.110.45.201",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "aws_instance",
      "name": "web",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "attributes": {
            "id": "i-0abc123def456",
            "ami": "ami-0c101f26f147fa7fd",
            "instance_type": "t2.micro",
            "public_ip": "3.110.45.201",
            "tags": { "Name": "MyWebServer" }
          }
        }
      ]
    }
  ]
}
```

Key fields:
- **`serial`** — increments every time state changes; used to detect if two people are working from an outdated copy.
- **`lineage`** — a unique ID for this state file's "history" — protects against accidentally applying an unrelated state file to your infrastructure.
- **`resources`** — the actual inventory: every managed resource, its type, and **all its attributes** as they exist in the real world right now (not just what you wrote in `.tf` — the *complete* returned attributes, including ones AWS auto-generated).

> ⚠️ **State can contain secrets in plaintext** — e.g., a database password set via a resource argument will appear in state attributes unencrypted. This is a major reason state must never be committed to Git and should be stored in an encrypted remote backend.

## Core State Commands

| Command | What it does |
|---|---|
| `terraform show` | Human-readable dump of the current state |
| `terraform state list` | List every resource address currently tracked |
| `terraform state show <address>` | Show all attributes of one specific resource, e.g. `terraform state show aws_instance.web` |
| `terraform state mv <src> <dst>` | Rename/move a resource within state (e.g., after refactoring code) without destroying/recreating it |
| `terraform state rm <address>` | Remove a resource from state **without destroying it in real life** (Terraform "forgets" about it) |
| `terraform state pull` | Download and print the raw remote state JSON |
| `terraform state push` | Upload a local state file to overwrite remote state (dangerous — rarely needed) |
| `terraform import <address> <id>` | Bring an existing, manually-created resource under Terraform's management by writing it into state |
| `terraform refresh` (or `plan -refresh-only`) | Reconcile state with real infrastructure without changing anything |

### Example: renaming a resource safely

If you rename a resource block in code:
```diff
- resource "aws_instance" "web" {
+ resource "aws_instance" "web_server" {
```
...without updating state, Terraform would think the old one should be **destroyed** and a new one **created**. Instead, run:
```bash
terraform state mv aws_instance.web aws_instance.web_server
```
This tells Terraform "these are the same real resource, just renamed in code" — no destroy/recreate happens.

## Common Mistakes

- ❌ Committing `terraform.tfstate` to Git — leaks secrets and causes merge conflicts (JSON files can't be "merged" meaningfully).
- ❌ Manually editing the state file by hand — always use `terraform state` subcommands instead.
- ❌ Running `terraform apply` from two places at once without a remote backend + locking — see `state-locking.md`.
- ❌ Deleting the state file because "it's confusing" — Terraform will then think nothing exists and try to recreate everything (potential duplicate resources or naming conflicts).

## Next
Read [`local-vs-remote-state.md`](./local-vs-remote-state.md) to understand where this file should actually live.
