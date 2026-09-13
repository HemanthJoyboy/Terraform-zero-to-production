variable "name_prefix" {
  type        = string
  description = "e.g. \"mern-todo-dev\" - used in resource Name tags and the EKS cluster-discovery tags"
}

variable "vpc_cidr" {
  type        = string
  description = "e.g. \"10.0.0.0/16\" for dev, \"10.1.0.0/16\" for test, \"10.2.0.0/16\" for prod - MUST NOT overlap across environments if you ever peer them"
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to spread subnets across. 2 for dev/test, 3 for prod is a common split."
  default     = 2
}

variable "single_nat_gateway" {
  type        = bool
  description = "true = one shared NAT gateway (cheaper, used for dev/test). false = one NAT gateway per AZ (higher availability, used for prod - an AZ outage doesn't kill egress for the other AZs)."
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
