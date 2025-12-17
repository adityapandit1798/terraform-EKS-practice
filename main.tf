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



#We need a policy that says: "Allow the service eks.amazonaws.com to assume this role."
data aws_iam_policy_document "eks_assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

#Role 
resource "aws_iam_role" "eks-cluster-role" {
  assume_role_policy = data.eks_assume_role_policy.eks.json
  name = "eks-cluster-role"
}

#attach managed policies to the role
resource "aws_iam_role_policy_attachment" "attach-cluster-role-policy" {
  role       = aws_iam_role.eks-cluster-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

#policy document for Node group role
data aws_iam_policy_document "eks_assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks-nodegroup-role" {
  assume_role_policy = data.eks_assume_role_policy.eks.json
  name = "eks-nodegroup-role"
}

#attach managed policies to the role
resource "aws_iam_role_policy_attachment" "attach-nodegroup-role-policy" {
  role       = aws_iam_role.eks-cluster-role.name
  policy_arn = ["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" ,"arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"]
}