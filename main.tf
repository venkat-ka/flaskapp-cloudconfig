terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1" # Mumbai region
}

# ---------------------------------
# 🔑 SSH Key for EC2 Access
# ---------------------------------
# GitHub Actions passes this as Base64-encoded secret
variable "ssh_public_key_b64" {
  description = "Base64-encoded SSH public key"
  type        = string
}

# Decode base64 to plaintext key
locals {
  ssh_public_key = base64decode(var.ssh_public_key_b64)
}

# Use existing key pair (already created manually)
data "aws_key_pair" "flask_key" {
  key_name = "flask-key"
}

# ---------------------------------
# 🌐 Custom VPC (so we never rely on default)
# ---------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "custom-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------
# 🔐 Security Group
# ---------------------------------
resource "aws_security_group" "flask_sg" {
  name        = "flask_sg"
  description = "Allow SSH and HTTP"
  vpc_id      = aws_vpc.main.id   # ✅ use custom VPC

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "flask_sg"
  }
}

# ---------------------------------
# 🪵 CloudWatch Log Group
# ---------------------------------
resource "random_id" "suffix" {
  byte_length = 2
}

resource "aws_cloudwatch_log_group" "flask_logs" {
  name              = "/ec2/flask-app-${random_id.suffix.hex}"
  retention_in_days = 7

  tags = {
    Application = "flask-app"
  }

  lifecycle {
    prevent_destroy       = false
    create_before_destroy = true
  }
}

# ---------------------------------
# 🐧 Get latest Ubuntu AMI
# ---------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---------------------------------
# ☁️ EC2 Instance
# ---------------------------------
resource "aws_instance" "flask_ec2" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  key_name                    = data.aws_key_pair.flask_key.key_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.flask_sg.id]
  associate_public_ip_address = true
  depends_on                  = [aws_cloudwatch_log_group.flask_logs]

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "🚀 Starting Flask + Nginx setup"

apt-get update -y
apt-get install -y python3-pip git nginx

cd /home/ubuntu
git clone https://github.com/venkat-ka/flask-app.git
cd flask-app

if ! grep -q 'host="0.0.0.0"' main.py; then
  sed -i 's/app.run(/app.run(host="0.0.0.0",/' main.py || true
fi
sed -i 's/port=80/port=5000/' main.py || true
sed -i 's/port = 80/port = 5000/' main.py || true

pip3 install -r requirements_clean.txt

cat <<EOT > /etc/systemd/system/flask-app.service
[Unit]
Description=Flask ML Prediction API
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/flask-app
ExecStart=/usr/bin/python3 main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable flask-app
systemctl start flask-app

cat <<EOT > /etc/nginx/sites-available/flask-proxy
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOT

ln -sf /etc/nginx/sites-available/flask-proxy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx

echo "✅ Flask + Nginx setup complete!" > /var/log/flask-setup.log
EOF

  tags = {
    Name = "flask-instance"
  }
}

# ---------------------------------
# 🌐 Elastic IP
# ---------------------------------
resource "aws_eip" "flask_ip" {
  instance = aws_instance.flask_ec2.id
  domain   = "vpc"
}

# ---------------------------------
# 🧠 Outputs
# ---------------------------------
output "elastic_ip" {
  value       = aws_eip.flask_ip.public_ip
  description = "Elastic IP assigned to Flask instance"
}

output "ssh_command" {
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.flask_ip.public_ip}"
  description = "SSH into EC2 instance"
}

output "flask_url" {
  value       = "http://${aws_eip.flask_ip.public_ip}"
  description = "Flask app URL"
}
