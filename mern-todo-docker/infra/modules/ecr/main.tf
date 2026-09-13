# Note this module is called from global/ecr-repos, NOT from live/dev,
# live/test, live/prod individually - one shared registry, tagged by
# version, used by every environment. You don't want a separate copy of
# every image per environment; you want the SAME built artifact promoted
# through environments (see README-terraform.md Section 4).

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repository_names)
  name                 = "mern-todo/${each.value}"
  image_tag_mutability = "IMMUTABLE"   # once pushed, a tag like "1.0" can never be overwritten - forces a new tag per build, which is what makes rollback-by-tag reliable

  image_scanning_configuration {
    scan_on_push = true   # automatic vulnerability scanning on every push - standard practice, catches known CVEs in base images before deploy
  }

  tags = var.tags
}

# Automatically deletes untagged images older than 14 days, so old build
# layers don't quietly accumulate storage cost forever.
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
