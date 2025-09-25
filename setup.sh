#!/bin/bash

# Generate SSH key pair for Jenkins agents
echo "Generating SSH key pair for Jenkins agents..."
ssh-keygen -t rsa -b 4096 -f jenkins_key -N ""

# Get the public key
PUBLIC_KEY=$(cat jenkins_key.pub)

# Update docker-compose.yml with the actual public key
sed -i "s|ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7...|$PUBLIC_KEY|g" docker-compose.yml

echo "SSH key generated and docker-compose.yml updated"
echo "Private key saved as: jenkins_key"
echo "Public key: $PUBLIC_KEY"

echo ""
echo "To start Jenkins:"
echo "1. Run: docker-compose up -d"
echo "2. Access Jenkins at: http://localhost:8080"
echo "3. Get initial admin password: docker exec jenkins-master cat /var/jenkins_home/secrets/initialAdminPassword"
echo "4. Configure agents using SSH with private key: jenkins_key"
