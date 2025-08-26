# terraform init -backend-config=backend.hcl

########################################
# Terraform / Provider
########################################
terraform {
  backend "s3" {
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

########################################
# IAM for EC2 SSM
########################################
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2-ssm-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

########################################
# Networking (VPC, IGW, Route table, Subnets)
########################################
resource "aws_vpc" "prod_vpc" {
  cidr_block           = "20.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "production" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.prod_vpc.id
  tags   = { Name = "main" }
}

resource "aws_route_table" "prod_rt" {
  vpc_id = aws_vpc.prod_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.gw.id
  }

  tags = { Name = "prod" }
}

resource "aws_subnet" "subnet_1" {
  vpc_id                  = aws_vpc.prod_vpc.id
  cidr_block              = "20.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "prod-subnet-1" }
}

resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.prod_vpc.id
  cidr_block              = "20.0.2.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "prod-subnet-2" }
}

resource "aws_route_table_association" "subnet_1_assoc" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.prod_rt.id
}

resource "aws_route_table_association" "subnet_2_assoc" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.prod_rt.id
}

########################################
# Security Groups
########################################
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow Web inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.prod_vpc.id
  tags        = { Name = "allow_web" }
}

resource "aws_vpc_security_group_ingress_rule" "allow_https_ipv4" {
  description       = "HTTPS"
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "allow_http_ipv4" {
  description       = "HTTP"
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ipv4" {
  description       = "SSH"
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv6" {
  security_group_id = aws_security_group.allow_web.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

########################################
# ENI + EIP
########################################
resource "aws_network_interface" "web_server_nic" {
  subnet_id       = aws_subnet.subnet_1.id
  private_ips     = ["20.0.1.50"]
  security_groups = [aws_security_group.allow_web.id]
}

resource "aws_eip" "one" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.web_server_nic.id
  associate_with_private_ip = "20.0.1.50"
  depends_on                = [aws_internet_gateway.gw]
}

output "server_public_ip" {
  value = aws_eip.one.public_ip
}

########################################
# EC2 (User data installs Corretto, Nginx, Docker, SSM Agent)
########################################
resource "aws_instance" "web_server" {
  ami               = "ami-05a7f3469a7653972"
  instance_type     = "t2.micro"
  availability_zone = "ap-northeast-2a"
  key_name          = var.key_name

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web_server_nic.id
  }

  depends_on = [
    aws_network_interface.web_server_nic,
    aws_eip.one
  ]

  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  user_data = <<-EOF
              #!/bin/bash
              set -euo pipefail
              export DEBIAN_FRONTEND=noninteractive
              
              # ---------- Base packages ----------
              apt-get update -y
              apt-get install -y curl unzip git
              
              # ---------- Java (OpenJDK 17, headless JDK) ----------
              apt-get install -y openjdk-17-jdk-headless
              
              # ---------- Timezone ----------
              ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
              date
              
              # ---------- Nginx ----------
              apt-get install -y nginx
              systemctl enable nginx
              systemctl start nginx
              
              # ---------- Swap (2GB) ----------
              fallocate -l 2G /swapfile
              chmod 600 /swapfile
              mkswap /swapfile
              swapon /swapfile
              echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
              
              # ---------- Docker ----------
              curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
              sh /tmp/get-docker.sh
              systemctl enable docker
              systemctl start docker
              usermod -aG docker ubuntu || true
              
              # ---------- SSM Agent (Ubuntu 22.04+, via snap) ----------
              snap wait system seed || true
              snap install amazon-ssm-agent --classic || true
              systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
              
              # ---------- Nginx Reverse Proxy -> localhost:8080 ----------
              cat > /etc/nginx/sites-available/default <<'NGINX'
              server {
                listen 80;
                location / {
                  proxy_pass http://localhost:8080;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                }
              }
              NGINX
              
              nginx -t && systemctl reload nginx
              
              EOF

  tags = { Name = "web-server" }
}

output "server_private_ip" {
  value = aws_instance.web_server.private_ip
}

output "server_id" {
  value = aws_instance.web_server.id
}

########################################
# RDS (Subnet Group, SG, Instance)
########################################
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  tags       = { Name = "RDS subnet group" }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Allow DB access from EC2"
  vpc_id      = aws_vpc.prod_vpc.id
  tags        = { Name = "rds_sg" }
}

resource "aws_vpc_security_group_ingress_rule" "allow_db_from_ec2" {
  security_group_id            = aws_security_group.rds_sg.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.allow_web.id
}

resource "aws_vpc_security_group_ingress_rule" "allow_db_from_local" {
  security_group_id = aws_security_group.rds_sg.id
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0" # 데모 전용, 실제 배포시는 삭제 필요
}

resource "aws_vpc_security_group_egress_rule" "allow_all_db_out" {
  security_group_id = aws_security_group.rds_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_parameter_group" "custom_mysql_parameters" {
  name        = "custom-mysql-parameters"
  family      = "mysql8.0"
  description = "Custom parameter group with timezone and UTF-8MB4 settings"

  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_connection"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_database"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_filesystem"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_results"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_connection"
    value = "utf8mb4_general_ci"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_general_ci"
  }

  tags = { Name = "custom-mysql-parameters" }
}

resource "aws_db_instance" "mydb" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true # (option) RDS 인스턴스를 삭제할 때 최종 스냅샷을 만들지 말기
  publicly_accessible    = true # 데모 전용, DB 인스턴스가 퍼블릭 IP를 받아 인터넷에서 직접 접근 가능
  parameter_group_name   = aws_db_parameter_group.custom_mysql_parameters.name
}

output "rds_endpoint" {
  value = aws_db_instance.mydb.endpoint
}

########################################
# CI/CD IAM (User + Access Key)
########################################
resource "aws_iam_user" "cicd_user" {
  name = "cicd-deploy-user"
  tags = { Purpose = "CI/CD deployment" }
}

resource "aws_iam_user_policy_attachment" "cicd_user_ec2_attach" {
  user       = aws_iam_user.cicd_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_user_policy_attachment" "cicd_user_ssm_attach" {
  user       = aws_iam_user.cicd_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

resource "aws_iam_access_key" "cicd_user_key" {
  user = aws_iam_user.cicd_user.name
}

output "cicd_aws_access_key_id" {
  value     = aws_iam_access_key.cicd_user_key.id
  sensitive = true
}

output "cicd_aws_secret_access_key" {
  value     = aws_iam_access_key.cicd_user_key.secret
  sensitive = true
}

########################################
# S3 (Bucket + Policy + Dedicated User)
########################################
resource "aws_s3_bucket" "bucket" {
  bucket        = var.bucket_name
  force_destroy = true
  tags = {
    Name        = var.bucket_name
    Environment = "Production"
  }
}

resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket = aws_s3_bucket.bucket.id
  # 퍼블릭 액세스를 허용
  # 개발/데모 환경에서는 퍼블릭 액세스를 허용할 수 있지만, 실제 운영 환경에서는 주의 필요.
  # 실 배포환경에서는 아래 설정을 true로 변경하여 퍼블릭 액세스를 차단 후 cloudfront와 연동하는 방법이 있음.
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_iam_user" "s3_user" {
  name = "s3-access-user"
  tags = { Purpose = "S3 access" }
}

resource "aws_iam_user_policy_attachment" "s3_user_s3_attach" {
  user       = aws_iam_user.s3_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_s3_bucket_policy" "public_read_policy" {
  bucket     = aws_s3_bucket.bucket.id
  depends_on = [aws_s3_bucket_public_access_block.public_access_block]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadGetObject",
      Effect    = "Allow",
      Principal = "*",
      Action    = ["s3:GetObject"],
      Resource = [
        "${aws_s3_bucket.bucket.arn}/*" # 기본적으로 S3 버킷에 있는 모든 객체에 대한 읽기 권한을 부여 
      ]
    }]
  })
}

resource "aws_iam_access_key" "s3_user_key" {
  user = aws_iam_user.s3_user.name
}

output "s3_aws_access_key_id" {
  value     = aws_iam_access_key.s3_user_key.id
  sensitive = true
}

output "s3_aws_secret_access_key" {
  value     = aws_iam_access_key.s3_user_key.secret
  sensitive = true
}
output "rds_db_name" {
  value = var.db_name
}