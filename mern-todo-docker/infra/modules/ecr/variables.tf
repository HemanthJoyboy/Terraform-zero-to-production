variable "repository_names" {
  type    = list(string)
  default = ["auth-service", "todo-service", "api-gateway", "client"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
