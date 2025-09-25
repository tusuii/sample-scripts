#!/bin/bash

echo "Stopping and removing Jenkins containers..."
docker-compose down -v

echo "Removing SSH keys..."
rm -f jenkins_key jenkins_key.pub

echo "Removing Docker images..."
docker rmi jenkins/jenkins:lts jenkins/ssh-agent:latest 2>/dev/null || true

echo "Cleaning up Docker system..."
docker system prune -f

echo "Jenkins setup completely destroyed."
