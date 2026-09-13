variable "kubernetes_version" {
  type    = string
  default = "1.29"
}
variable "instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}
variable "capacity_type" {
  type    = string
  default = "SPOT"   # dev: cheaper, occasional reclaim is an acceptable tradeoff
}
variable "desired_size" {
  type    = number
  default = 2
}
variable "min_size" {
  type    = number
  default = 2
}
variable "max_size" {
  type    = number
  default = 4
}
