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
  default = "ON_DEMAND"   # test: unlike dev, avoid SPOT here - test needs to behave predictably for QA sign-off
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
