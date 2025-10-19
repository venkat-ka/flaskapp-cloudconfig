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

# -------------------------------
# 1️⃣  Create SSH key pair automatically
# -------------------------------
resource "aws_key_pair" "flask_key" {
  key_name   = "flask-key"
  public_key = file(pathexpand("~/.ssh/id_rsa.pub")) # Adjust path if needed
}

# -------------------------------
# 2️⃣  Security Group (SSH + HTTP)
# -------------------------------
resource "aws_security_group" "flask_sg" {
  name        = "flask_sg"
  description = "Allow SSH and Flask (via Nginx on port 80)"
  
  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 🔒 Optional: replace with your IP /32 for security
  }

  ingress {
    description = "HTTP for Flask app via Nginx"
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

# -------------------------------
# 3️⃣  Get latest Ubuntu AMI
# -------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu official)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# -------------------------------
# 4️⃣  CloudWatch Log Group
# -------------------------------
resource "aws_cloudwatch_log_group" "flask_logs" {
  name              = "/ec2/flask-app"
  retention_in_days = 7

  tags = {
    Environment = "prod"
    Application = "flask-app"
  }
}

# -------------------------------
# 5️⃣  EC2 Instance Setup
# -------------------------------
resource "aws_instance" "flask_ec2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.flask_key.key_name
  vpc_security_group_ids = [aws_security_group.flask_sg.id]
  depends_on             = [aws_cloudwatch_log_group.flask_logs]

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail
exec > /var/log/user-data.log 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "🚀 Starting full Flask + Nginx setup"

# --- Wait for apt locks ---
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "🔒 Waiting for apt lock..."
    sleep 5
done

# --- Update and install packages ---
apt-get update -y
apt-get install -y python3-pip git nginx

# --- Ensure nginx directories exist ---
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

systemctl enable nginx
systemctl start nginx

# --- Flask setup ---
cd /home/ubuntu
git clone https://github.com/venkat-ka/flask-app.git
cd flask-app

# Fix Flask run host/port safely
if ! grep -q 'host="0.0.0.0"' main.py; then
  sed -i 's/app.run(/app.run(host="0.0.0.0",/' main.py || true
fi
sed -i 's/port=80/port=5000/' main.py || true
sed -i 's/port = 80/port = 5000/' main.py || true

pip3 install -r requirements_clean.txt

# --- systemd service for Flask ---
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

# --- Wait until Flask port is up ---
for i in {1..20}; do
    if ss -tuln | grep -q ":5000"; then
        echo "✅ Flask is listening on port 5000"
        break
    else
        echo "⏳ Waiting for Flask to start..."
        sleep 10
    fi
done

# --- Nginx reverse proxy ---
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
systemctl enable nginx



echo "✅ Flask + Nginx setup completed successfully!" > /var/log/flask-nginx-setup.log
EOF

  tags = {
    Name = "flask-instance"
  }
}

# -------------------------------
# 6️⃣  Elastic IP
# -------------------------------
resource "aws_eip" "flask_ip" {
  instance = aws_instance.flask_ec2.id
  domain   = "vpc"

  tags = {
    Name = "flask-app-eip"
  }
}

# -------------------------------
# 7️⃣  Flask Health Check (Improved)
# -------------------------------
resource "null_resource" "health_check" {
  depends_on = [aws_eip.flask_ip]

  provisioner "local-exec" {
    command = <<EOT
      echo "🕐 Waiting 90 seconds before starting health check..."
      sleep 90
      echo "🔍 Checking Flask /health endpoint..."
      for i in {1..60}; do
        if curl -s -f http://${aws_eip.flask_ip.public_ip}/health >/dev/null; then
          echo "✅ Flask API is healthy after $i attempts!"
          exit 0
        fi
        echo "⏳ Attempt $i: Flask not ready yet, retrying in 10s..."
        sleep 10
      done
      echo "❌ Flask health check failed after 10 minutes!"
      exit 1
    EOT
  }
}

# -------------------------------
# 8️⃣  Outputs
# -------------------------------
output "elastic_ip" {
  value       = aws_eip.flask_ip.public_ip
  description = "Permanent Elastic IP assigned to Flask instance"
}

output "ssh_command" {
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.flask_ip.public_ip}"
  description = "SSH into your EC2 instance"
}

output "flask_url" {
  value       = "http://${aws_eip.flask_ip.public_ip}"
  description = "Access your Flask app via Nginx reverse proxy"
}
