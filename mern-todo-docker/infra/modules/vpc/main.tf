# Generic VPC module: public + private subnets across N AZs, one NAT
# gateway (or one per AZ, for prod-grade HA - see var.single_nat_gateway),
# and the route tables wiring it together. Every environment calls this
# SAME module with different `vpc_cidr` / `az_count` / `single_nat_gateway`
# values - see live/dev/network vs live/prod/network.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
    # Required tag for the AWS Load Balancer Controller to auto-discover this VPC
    "kubernetes.io/cluster/${var.name_prefix}" = "shared"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# --- Public subnets (one per AZ) - for the ALB / NAT gateways ---
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-public-${count.index}"
    "kubernetes.io/cluster/${var.name_prefix}"  = "shared"
    "kubernetes.io/role/elb"                    = "1"   # tells the ALB controller "put internet-facing load balancers here"
  })
}

# --- Private subnets (one per AZ) - where EKS worker nodes and pods actually run ---
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-private-${count.index}"
    "kubernetes.io/cluster/${var.name_prefix}"  = "shared"
    "kubernetes.io/role/internal-elb"           = "1"   # tells the ALB controller "put internal load balancers here"
  })
}

# --- NAT gateway(s): lets private-subnet nodes reach the internet (pull images, call AWS APIs) ---
resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : var.az_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.single_nat_gateway ? 1 : var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ (each pointing at its own or the shared NAT gateway),
# so a NAT gateway failure in one AZ doesn't take down every AZ's egress -
# only matters when single_nat_gateway = false (prod).
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
