#!/bin/bash

JENKINS_URL="http://localhost:8080"
JENKINS_USER="admin"

# Wait for Jenkins to be fully ready and get password
echo "Waiting for Jenkins to be ready..."
while true; do
    if docker exec jenkins-master test -f /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null; then
        JENKINS_PASSWORD=$(docker exec jenkins-master cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null)
        if [ ! -z "$JENKINS_PASSWORD" ] && curl -s $JENKINS_URL/login > /dev/null; then
            break
        fi
    fi
    echo "Still waiting..."
    sleep 10
done

echo "Jenkins is ready. Password: $JENKINS_PASSWORD"

# Download Jenkins CLI using curl
docker exec jenkins-master curl -o /tmp/jenkins-cli.jar $JENKINS_URL/jnlpJars/jenkins-cli.jar

# Wait a bit more for plugins to load
sleep 30

# Create SSH credential
PRIVATE_KEY=$(cat jenkins_key | sed ':a;N;$!ba;s/\n/\\n/g')
CREDENTIAL_XML="<com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>
  <scope>GLOBAL</scope>
  <id>jenkins-ssh-key</id>
  <username>jenkins</username>
  <privateKeySource class=\"com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey\$DirectEntryPrivateKeySource\">
    <privateKey>$PRIVATE_KEY</privateKey>
  </privateKeySource>
</com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>"

echo "$CREDENTIAL_XML" | docker exec -i jenkins-master java -jar /tmp/jenkins-cli.jar -s $JENKINS_URL -auth $JENKINS_USER:$JENKINS_PASSWORD create-credentials-by-xml system::system::jenkins _ 2>/dev/null

# Create agents
for i in 1 2; do
    AGENT_XML="<slave>
  <name>jenkins-agent-$i</name>
  <description>Jenkins Agent $i</description>
  <remoteFS>/home/jenkins/agent</remoteFS>
  <numExecutors>2</numExecutors>
  <mode>NORMAL</mode>
  <launcher class=\"hudson.plugins.sshslaves.SSHLauncher\">
    <host>jenkins-agent-$i</host>
    <port>22</port>
    <credentialsId>jenkins-ssh-key</credentialsId>
    <launchTimeoutSeconds>60</launchTimeoutSeconds>
    <maxNumRetries>10</maxNumRetries>
    <retryWaitTime>15</retryWaitTime>
  </launcher>
</slave>"

    echo "$AGENT_XML" | docker exec -i jenkins-master java -jar /tmp/jenkins-cli.jar -s $JENKINS_URL -auth $JENKINS_USER:$JENKINS_PASSWORD create-node jenkins-agent-$i 2>/dev/null
    echo "Added jenkins-agent-$i"
done

echo "Setup complete! Check nodes at: $JENKINS_URL/computer/"
