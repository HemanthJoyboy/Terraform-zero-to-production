output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_group_status" {
  value = aws_eks_node_group.this.status
}
