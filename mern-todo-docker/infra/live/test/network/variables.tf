variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}
variable "az_count" {
  type    = number
  default = 2
}
variable "single_nat_gateway" {
  type    = bool
  default = true   # test: still cost-optimized like dev, not yet prod-grade HA
}
