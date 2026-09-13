# Only file most changes touch. main.tf/variables.tf rarely change once the
# module is stable - see README-terraform.md's "modules vs live" explanation.
vpc_cidr           = "10.0.0.0/16"
az_count           = 2
single_nat_gateway = true
