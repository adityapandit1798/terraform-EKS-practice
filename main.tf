terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.26.0"
    }
  }
}

provider "aws" {
	region= var.region
}

resource "aws_vpc" "main" {
  cidr_block       =  var.vpc_cidr
  instance_tenancy = "default"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags = {
    Name = "eks-terraform-vpc"
  }
}

# get lists of AZs in the region
data "aws_availability_zones" "available" {
  state = "available"
}

#attach internet gateway to VPC
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "eks-terraform-igw"
  }
}


#create 2 public subnets in different AZs
resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  count     = 2
  tags = {
    "kubernetes.io/role/elb" = "1"  
  }
}

#create 2 private subnets in different AZs
resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  count     = 2
  tags = {
    "kubernetes.io/role/internal-elb" = "1"  
  }
}


#elastic IP for NAT Gateway
resource "aws_eip" "lb" {
  domain   = "vpc"
}
#NAT Gateway in public subnet
resource "aws_nat_gateway" "nat1" {
  allocation_id = aws_eip.lb.id
  subnet_id     = aws_subnet.public[0].id
  depends_on = [aws_internet_gateway.main]
}

#route table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"    # internet access
    gateway_id = aws_internet_gateway.main.id    # route via internet gateway
  }
  tags = {
    Name = "eks-terraform-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"    # internet access
    nat_gateway_id = aws_nat_gateway.nat1.id    # should route via NAT gateway
  }
  tags = {
    Name = "eks-terraform-private-rt"
  }
}

# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id  # 
}



# --- 1. CLUSTER ROLE (Control Plane) ---

# Trust Policy: Allow EKS Service to assume this role
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Create the Cluster Role
resource "aws_iam_role" "cluster_role" {
  name               = "eks-terraform-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}

# Attach the Cluster Policy
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- 2. NODE ROLE (Worker Nodes) ---

# Trust Policy: Allow EC2 Service to assume this role
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Create the Node Role
resource "aws_iam_role" "node_role" {
  name               = "eks-terraform-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

# Attach the 3 Node Policies using a Loop (for_each)
resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])

  role       = aws_iam_role.node_role.name
  policy_arn = each.value
}




#EKS Cluster
resource "aws_eks_cluster" "main" {
  name = "eks-terraform-cluster"
  role_arn = aws_iam_role.cluster_role.arn

  vpc_config {
    subnet_ids = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
  }
  depends_on = [ aws_iam_role_policy_attachment.cluster_policy ]
}

# --- WORKER NODES ---
resource "aws_eks_node_group" "node-group" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "node-group-1"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.node_policies["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"],
    aws_iam_role_policy_attachment.node_policies["arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"],
    aws_iam_role_policy_attachment.node_policies["arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"],
  ]
}


output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}
