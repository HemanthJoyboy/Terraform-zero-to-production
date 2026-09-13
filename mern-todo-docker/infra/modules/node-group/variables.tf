variable "cluster_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "instance_types" {
  type        = list(string)
  description = "e.g. [\"t3.medium\"] for dev, [\"m5.xlarge\"] for prod"
  default     = ["t3.medium"]
}

variable "capacity_type" {
  type        = string
  description = "ON_DEMAND or SPOT. Prod should almost always be ON_DEMAND (or a mix); SPOT nodes can be reclaimed by AWS with 2 minutes' notice."
  default     = "ON_DEMAND"
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

variable "labels" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
