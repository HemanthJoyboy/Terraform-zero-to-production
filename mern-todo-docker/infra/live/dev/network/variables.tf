variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "az_count" {
  type    = number
  default = 2
}
variable "single_nat_gateway" {
  type    = bool
  default = true   # dev: save cost, one shared NAT gateway is fine
}
