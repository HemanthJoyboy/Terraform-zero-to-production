variable "vpc_cidr" {
  type    = string
  default = "10.2.0.0/16"
}
variable "az_count" {
  type    = number
  default = 3   # prod: spread across 3 AZs, not 2 - survives a full AZ outage
}
variable "single_nat_gateway" {
  type    = bool
  default = false   # prod: one NAT gateway per AZ - an AZ outage should not kill egress cluster-wide
}
