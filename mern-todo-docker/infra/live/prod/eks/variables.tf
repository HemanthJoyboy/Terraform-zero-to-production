variable "kubernetes_version" {
  type    = string
  default = "1.29"
}
variable "instance_types" {
  type    = list(string)
  default = ["m5.xlarge"]
}
variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"   # prod: SPOT nodes can be reclaimed by AWS with 2 minutes notice - not worth the risk here
}
variable "desired_size" {
  type    = number
  default = 6
}
variable "min_size" {
  type    = number
  default = 6
}
variable "max_size" {
  type    = number
  default = 12
}
