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
# Make sure you already have a local SSH public key (e.g., ~/.ssh/id_rsa.pub)
# You can generate one using: ssh-keygen -t rsa -b 4096
resource "aws_key_pair" "flask_key" {
  key_name   = "flask-key"
  public_key = file("/home/venkatesh/.ssh/id_rsa.pub")  # adjust path if needed
}

# -------------------------------
# 2️⃣  Security group (SSH + Flask)
# -------------------------------
resource "aws_security_group" "flask_sg" {
  name        = "flask_sg"
  description = "Allow SSH and Flask (port 5000)"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Flask app"
    from_port   = 5000
    to_port     = 5000
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
# 4️⃣  EC2 Instance (Flask)
# -------------------------------
resource "aws_instance" "flask_ec2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.flask_key.key_name
  vpc_security_group_ids = [aws_security_group.flask_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y python3-pip git
              cd /home/ubuntu
              git clone https://github.com/venkat-ka/flask-app.git
              cd flask-app
              pip3 install -r requirements_clean.txt
               # Create systemd service file
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

              # Enable and start the Flask service
              systemctl daemon-reload
              systemctl enable flask-app
              systemctl start flask-app
              
              # Log confirmation
              echo "✅ Flask service installed and started successfully" > /var/log/flask-setup.log
              EOF

  tags = {
    Name = "flask-instance"
  }
}

# -------------------------------
# 5️⃣  Outputs
# -------------------------------
output "public_ip" {
  value = aws_instance.flask_ec2.public_ip
  description = "Public IP of your Flask EC2 instance"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.flask_ec2.public_ip}"
  description = "Use this command to connect to your EC2 instance"
}

output "flask_url" {
  value = "http://${aws_instance.flask_ec2.public_ip}:5000"
  description = "Open this URL in your browser to access the Flask app"
}
