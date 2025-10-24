# Jenkins Declarative Pipeline Guide for Multi-Branch Microservices CI/CD

## Table of Contents
1. [Introduction to Declarative Pipelines](#introduction)
2. [Basic Pipeline Structure](#basic-structure)
3. [Multi-Branch Pipeline Setup](#multi-branch-setup)
4. [Microservices Pipeline Patterns](#microservices-patterns)
5. [Environment Management](#environment-management)
6. [Build Strategies](#build-strategies)
7. [Testing Strategies](#testing-strategies)
8. [Deployment Patterns](#deployment-patterns)
9. [Advanced Features](#advanced-features)
10. [Best Practices](#best-practices)

## 1. Introduction to Declarative Pipelines {#introduction}

Declarative pipelines use a structured syntax defined in a `Jenkinsfile` that describes your entire CI/CD process. Unlike scripted pipelines, declarative syntax is more readable and has built-in error handling.

### Key Benefits:
- Version controlled with your code
- Consistent across branches
- Built-in syntax validation
- Better error handling
- Easier to maintain

## 2. Basic Pipeline Structure {#basic-structure}

### Minimal Pipeline Structure
```groovy
pipeline {
    agent any
    
    stages {
        stage('Build') {
            steps {
                echo 'Building application...'
            }
        }
    }
}
```

### Complete Pipeline Structure
```groovy
pipeline {
    agent {
        label 'linux'
    }
    
    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        skipStagesAfterUnstable()
    }
    
    environment {
        APP_NAME = 'my-microservice'
        DOCKER_REGISTRY = 'your-registry.com'
        KUBECONFIG = credentials('kubeconfig')
    }
    
    parameters {
        choice(
            name: 'ENVIRONMENT',
            choices: ['dev', 'staging', 'prod'],
            description: 'Target environment'
        )
        booleanParam(
            name: 'SKIP_TESTS',
            defaultValue: false,
            description: 'Skip test execution'
        )
    }
    
    triggers {
        pollSCM('H/5 * * * *')
        cron('H 2 * * *')
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        
        stage('Build') {
            steps {
                sh 'make build'
            }
        }
        
        stage('Test') {
            when {
                not { params.SKIP_TESTS }
            }
            steps {
                sh 'make test'
            }
            post {
                always {
                    publishTestResults testResultsPattern: 'test-results.xml'
                }
            }
        }
        
        stage('Deploy') {
            steps {
                sh "make deploy ENV=${params.ENVIRONMENT}"
            }
        }
    }
    
    post {
        always {
            cleanWs()
        }
        success {
            echo 'Pipeline succeeded!'
        }
        failure {
            emailext (
                subject: "Pipeline Failed: ${env.JOB_NAME} - ${env.BUILD_NUMBER}",
                body: "Build failed. Check console output at ${env.BUILD_URL}",
                to: "${env.CHANGE_AUTHOR_EMAIL}"
            )
        }
    }
}
```

## 3. Multi-Branch Pipeline Setup {#multi-branch-setup}

### Jenkins Configuration
1. Create a new "Multibranch Pipeline" job
2. Configure branch sources (Git, GitHub, Bitbucket)
3. Set branch discovery strategies
4. Configure build triggers

### Branch-Specific Logic
```groovy
pipeline {
    agent any
    
    stages {
        stage('Branch Logic') {
            steps {
                script {
                    if (env.BRANCH_NAME == 'main') {
                        echo 'Main branch - full deployment'
                        sh 'make deploy-prod'
                    } else if (env.BRANCH_NAME == 'develop') {
                        echo 'Develop branch - staging deployment'
                        sh 'make deploy-staging'
                    } else if (env.BRANCH_NAME.startsWith('feature/')) {
                        echo 'Feature branch - dev deployment'
                        sh 'make deploy-dev'
                    } else if (env.BRANCH_NAME.startsWith('PR-')) {
                        echo 'Pull request - run tests only'
                        sh 'make test'
                    }
                }
            }
        }
    }
}
```

### Environment-Based Deployment
```groovy
pipeline {
    agent any
    
    environment {
        DEPLOY_ENV = "${env.BRANCH_NAME == 'main' ? 'prod' : env.BRANCH_NAME == 'develop' ? 'staging' : 'dev'}"
    }
    
    stages {
        stage('Deploy') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                    branch 'feature/*'
                }
            }
            steps {
                sh "kubectl apply -f k8s/${DEPLOY_ENV}/ --namespace=${DEPLOY_ENV}"
            }
        }
    }
}
```

## 4. Microservices Pipeline Patterns {#microservices-patterns}

### Monorepo with Multiple Services
```groovy
pipeline {
    agent any
    
    environment {
        CHANGED_SERVICES = ''
    }
    
    stages {
        stage('Detect Changes') {
            steps {
                script {
                    def changedFiles = sh(
                        script: "git diff --name-only HEAD~1 HEAD",
                        returnStdout: true
                    ).trim().split('\n')
                    
                    def services = ['user-service', 'order-service', 'payment-service']
                    def changedServices = []
                    
                    services.each { service ->
                        if (changedFiles.any { it.startsWith("${service}/") }) {
                            changedServices.add(service)
                        }
                    }
                    
                    env.CHANGED_SERVICES = changedServices.join(',')
                    echo "Changed services: ${env.CHANGED_SERVICES}"
                }
            }
        }
        
        stage('Build Services') {
            when {
                expression { env.CHANGED_SERVICES != '' }
            }
            steps {
                script {
                    def services = env.CHANGED_SERVICES.split(',')
                    def buildSteps = [:]
                    
                    services.each { service ->
                        buildSteps[service] = {
                            dir(service) {
                                sh 'docker build -t ${DOCKER_REGISTRY}/${service}:${BUILD_NUMBER} .'
                                sh 'docker push ${DOCKER_REGISTRY}/${service}:${BUILD_NUMBER}'
                            }
                        }
                    }
                    
                    parallel buildSteps
                }
            }
        }
    }
}
```

### Service-Specific Pipeline
```groovy
// Jenkinsfile for individual microservice
pipeline {
    agent any
    
    environment {
        SERVICE_NAME = 'user-service'
        IMAGE_TAG = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}"
        DOCKER_IMAGE = "${DOCKER_REGISTRY}/${SERVICE_NAME}:${IMAGE_TAG}"
    }
    
    stages {
        stage('Build') {
            steps {
                sh 'mvn clean package -DskipTests'
            }
        }
        
        stage('Unit Tests') {
            steps {
                sh 'mvn test'
            }
            post {
                always {
                    publishTestResults testResultsPattern: 'target/surefire-reports/*.xml'
                    publishCoverage adapters: [jacocoAdapter('target/site/jacoco/jacoco.xml')]
                }
            }
        }
        
        stage('Integration Tests') {
            steps {
                sh 'docker-compose -f docker-compose.test.yml up --abort-on-container-exit'
            }
            post {
                always {
                    sh 'docker-compose -f docker-compose.test.yml down'
                }
            }
        }
        
        stage('Security Scan') {
            steps {
                sh 'trivy image --exit-code 1 --severity HIGH,CRITICAL ${DOCKER_IMAGE}'
            }
        }
        
        stage('Deploy to Dev') {
            when {
                not { branch 'main' }
            }
            steps {
                sh """
                    helm upgrade --install ${SERVICE_NAME} ./helm-chart \\
                        --namespace dev \\
                        --set image.tag=${IMAGE_TAG} \\
                        --set environment=dev
                """
            }
        }
        
        stage('Deploy to Prod') {
            when {
                branch 'main'
            }
            steps {
                input message: 'Deploy to production?', ok: 'Deploy'
                sh """
                    helm upgrade --install ${SERVICE_NAME} ./helm-chart \\
                        --namespace prod \\
                        --set image.tag=${IMAGE_TAG} \\
                        --set environment=prod
                """
            }
        }
    }
}
```

## 5. Environment Management {#environment-management}

### Dynamic Environment Creation
```groovy
pipeline {
    agent any
    
    environment {
        FEATURE_ENV = "${env.BRANCH_NAME.replaceAll('/', '-').toLowerCase()}"
    }
    
    stages {
        stage('Create Feature Environment') {
            when {
                branch 'feature/*'
            }
            steps {
                sh """
                    kubectl create namespace ${FEATURE_ENV} --dry-run=client -o yaml | kubectl apply -f -
                    helm upgrade --install ${SERVICE_NAME} ./helm-chart \\
                        --namespace ${FEATURE_ENV} \\
                        --set image.tag=${BUILD_NUMBER} \\
                        --set ingress.host=${FEATURE_ENV}.dev.company.com
                """
            }
        }
        
        stage('Cleanup Feature Environment') {
            when {
                allOf {
                    branch 'feature/*'
                    expression { env.CHANGE_TARGET != null } // PR merged
                }
            }
            steps {
                sh "kubectl delete namespace ${FEATURE_ENV} --ignore-not-found=true"
            }
        }
    }
}
```

### Environment Promotion Pipeline
```groovy
pipeline {
    agent any
    
    parameters {
        choice(
            name: 'SOURCE_ENV',
            choices: ['dev', 'staging'],
            description: 'Source environment'
        )
        choice(
            name: 'TARGET_ENV',
            choices: ['staging', 'prod'],
            description: 'Target environment'
        )
        string(
            name: 'IMAGE_TAG',
            description: 'Image tag to promote'
        )
    }
    
    stages {
        stage('Validate Promotion') {
            steps {
                script {
                    if (params.SOURCE_ENV == 'dev' && params.TARGET_ENV == 'prod') {
                        error('Cannot promote directly from dev to prod')
                    }
                }
            }
        }
        
        stage('Run Smoke Tests') {
            steps {
                sh """
                    kubectl run smoke-test --rm -i --restart=Never \\
                        --image=smoke-test:latest \\
                        --env="TARGET_URL=https://${params.SOURCE_ENV}.company.com"
                """
            }
        }
        
        stage('Promote') {
            steps {
                sh """
                    helm upgrade ${SERVICE_NAME} ./helm-chart \\
                        --namespace ${params.TARGET_ENV} \\
                        --set image.tag=${params.IMAGE_TAG} \\
                        --reuse-values
                """
            }
        }
    }
}
```

## 6. Build Strategies {#build-strategies}

### Docker Multi-Stage Build
```groovy
pipeline {
    agent any
    
    stages {
        stage('Build Docker Image') {
            steps {
                script {
                    def image = docker.build("${SERVICE_NAME}:${BUILD_NUMBER}")
                    
                    // Multi-stage build optimization
                    sh """
                        docker build \\
                            --target production \\
                            --build-arg BUILD_NUMBER=${BUILD_NUMBER} \\
                            --build-arg GIT_COMMIT=${GIT_COMMIT} \\
                            -t ${DOCKER_REGISTRY}/${SERVICE_NAME}:${BUILD_NUMBER} .
                    """
                }
            }
        }
        
        stage('Optimize Image') {
            steps {
                sh """
                    # Use dive to analyze image layers
                    dive ${DOCKER_REGISTRY}/${SERVICE_NAME}:${BUILD_NUMBER} --ci
                    
                    # Scan for vulnerabilities
                    trivy image ${DOCKER_REGISTRY}/${SERVICE_NAME}:${BUILD_NUMBER}
                """
            }
        }
    }
}
```

### Parallel Build Strategy
```groovy
pipeline {
    agent none
    
    stages {
        stage('Parallel Builds') {
            parallel {
                stage('Backend Build') {
                    agent { label 'java' }
                    steps {
                        dir('backend') {
                            sh 'mvn clean package'
                            archiveArtifacts artifacts: 'target/*.jar'
                        }
                    }
                }
                
                stage('Frontend Build') {
                    agent { label 'node' }
                    steps {
                        dir('frontend') {
                            sh 'npm ci'
                            sh 'npm run build'
                            archiveArtifacts artifacts: 'dist/**'
                        }
                    }
                }
                
                stage('Database Migration') {
                    agent any
                    steps {
                        dir('database') {
                            sh 'flyway migrate'
                        }
                    }
                }
            }
        }
    }
}
```
## 7. Testing Strategies {#testing-strategies}

### Comprehensive Testing Pipeline
```groovy
pipeline {
    agent any
    
    stages {
        stage('Unit Tests') {
            steps {
                sh 'mvn test'
            }
            post {
                always {
                    publishTestResults testResultsPattern: 'target/surefire-reports/*.xml'
                    publishCoverage adapters: [jacocoAdapter('target/site/jacoco/jacoco.xml')]
                }
            }
        }
        
        stage('Integration Tests') {
            steps {
                sh '''
                    docker-compose -f docker-compose.test.yml up -d
                    sleep 30
                    mvn verify -Dtest.profile=integration
                '''
            }
            post {
                always {
                    sh 'docker-compose -f docker-compose.test.yml down'
                    publishTestResults testResultsPattern: 'target/failsafe-reports/*.xml'
                }
            }
        }
        
        stage('Contract Tests') {
            steps {
                sh '''
                    # Provider contract tests
                    mvn test -Dtest.profile=contract-provider
                    
                    # Consumer contract tests
                    mvn test -Dtest.profile=contract-consumer
                '''
            }
        }
        
        stage('Performance Tests') {
            when {
                anyOf {
                    branch 'main'
                    branch 'develop'
                }
            }
            steps {
                sh '''
                    # JMeter performance tests
                    jmeter -n -t performance-tests.jmx -l results.jtl
                    
                    # K6 load tests
                    k6 run --out influxdb=http://influxdb:8086/k6 load-test.js
                '''
            }
            post {
                always {
                    perfReport sourceDataFiles: 'results.jtl'
                }
            }
        }
        
        stage('Security Tests') {
            steps {
                sh '''
                    # OWASP ZAP security scan
                    zap-baseline.py -t http://localhost:8080 -r zap-report.html
                    
                    # Dependency check
                    mvn org.owasp:dependency-check-maven:check
                '''
            }
            post {
                always {
                    publishHTML([
                        allowMissing: false,
                        alwaysLinkToLastBuild: true,
                        keepAll: true,
                        reportDir: '.',
                        reportFiles: 'zap-report.html',
                        reportName: 'ZAP Security Report'
                    ])
                }
            }
        }
    }
}
```

### Test Environment Management
```groovy
pipeline {
    agent any
    
    environment {
        TEST_DB_URL = credentials('test-db-url')
        TEST_REDIS_URL = credentials('test-redis-url')
    }
    
    stages {
        stage('Setup Test Environment') {
            steps {
                sh '''
                    # Start test dependencies
                    docker-compose -f docker-compose.test.yml up -d postgres redis
                    
                    # Wait for services to be ready
                    ./scripts/wait-for-services.sh
                    
                    # Run database migrations
                    flyway -url=${TEST_DB_URL} migrate
                '''
            }
        }
        
        stage('Parallel Test Execution') {
            parallel {
                stage('API Tests') {
                    steps {
                        sh 'newman run api-tests.postman_collection.json'
                    }
                }
                
                stage('UI Tests') {
                    steps {
                        sh '''
                            # Start Selenium Grid
                            docker run -d --name selenium-hub selenium/hub:latest
                            
                            # Run Cypress tests
                            cypress run --record --key $CYPRESS_RECORD_KEY
                        '''
                    }
                }
                
                stage('Load Tests') {
                    steps {
                        sh 'artillery run load-test.yml'
                    }
                }
            }
        }
        
        stage('Cleanup Test Environment') {
            post {
                always {
                    sh '''
                        docker-compose -f docker-compose.test.yml down
                        docker rm -f selenium-hub || true
                    '''
                }
            }
        }
    }
}
```

## 8. Deployment Patterns {#deployment-patterns}

### Blue-Green Deployment
```groovy
pipeline {
    agent any
    
    environment {
        CURRENT_COLOR = sh(
            script: "kubectl get service ${SERVICE_NAME} -o jsonpath='{.spec.selector.color}' || echo 'blue'",
            returnStdout: true
        ).trim()
        NEW_COLOR = "${env.CURRENT_COLOR == 'blue' ? 'green' : 'blue'}"
    }
    
    stages {
        stage('Deploy New Version') {
            steps {
                sh """
                    # Deploy to inactive color
                    helm upgrade --install ${SERVICE_NAME}-${NEW_COLOR} ./helm-chart \\
                        --namespace ${ENVIRONMENT} \\
                        --set image.tag=${BUILD_NUMBER} \\
                        --set color=${NEW_COLOR} \\
                        --set service.enabled=false
                """
            }
        }
        
        stage('Health Check') {
            steps {
                sh """
                    # Wait for deployment to be ready
                    kubectl wait --for=condition=available --timeout=300s \\
                        deployment/${SERVICE_NAME}-${NEW_COLOR}
                    
                    # Run health checks
                    ./scripts/health-check.sh ${SERVICE_NAME}-${NEW_COLOR}
                """
            }
        }
        
        stage('Switch Traffic') {
            steps {
                input message: 'Switch traffic to new version?', ok: 'Switch'
                sh """
                    # Update service selector to point to new color
                    kubectl patch service ${SERVICE_NAME} \\
                        -p '{"spec":{"selector":{"color":"${NEW_COLOR}"}}}'
                """
            }
        }
        
        stage('Cleanup Old Version') {
            steps {
                sh """
                    # Remove old deployment after successful switch
                    helm uninstall ${SERVICE_NAME}-${CURRENT_COLOR} || true
                """
            }
        }
    }
}
```

### Canary Deployment
```groovy
pipeline {
    agent any
    
    parameters {
        choice(
            name: 'CANARY_PERCENTAGE',
            choices: ['10', '25', '50', '100'],
            description: 'Percentage of traffic for canary'
        )
    }
    
    stages {
        stage('Deploy Canary') {
            steps {
                sh """
                    # Deploy canary version
                    helm upgrade --install ${SERVICE_NAME}-canary ./helm-chart \\
                        --namespace ${ENVIRONMENT} \\
                        --set image.tag=${BUILD_NUMBER} \\
                        --set replicaCount=1 \\
                        --set canary.enabled=true \\
                        --set canary.weight=${params.CANARY_PERCENTAGE}
                """
            }
        }
        
        stage('Monitor Canary') {
            steps {
                sh '''
                    # Monitor metrics for 10 minutes
                    for i in {1..10}; do
                        echo "Monitoring canary deployment... ($i/10)"
                        
                        # Check error rate
                        ERROR_RATE=$(curl -s "http://prometheus:9090/api/v1/query?query=rate(http_requests_total{status=~\"5..\"}[5m])" | jq -r '.data.result[0].value[1]')
                        
                        if (( $(echo "$ERROR_RATE > 0.01" | bc -l) )); then
                            echo "Error rate too high: $ERROR_RATE"
                            exit 1
                        fi
                        
                        sleep 60
                    done
                '''
            }
        }
        
        stage('Promote or Rollback') {
            steps {
                script {
                    def promote = input(
                        message: 'Promote canary to production?',
                        parameters: [
                            choice(
                                name: 'ACTION',
                                choices: ['promote', 'rollback'],
                                description: 'Action to take'
                            )
                        ]
                    )
                    
                    if (promote == 'promote') {
                        sh """
                            # Promote canary to full production
                            helm upgrade ${SERVICE_NAME} ./helm-chart \\
                                --namespace ${ENVIRONMENT} \\
                                --set image.tag=${BUILD_NUMBER}
                            
                            # Remove canary deployment
                            helm uninstall ${SERVICE_NAME}-canary
                        """
                    } else {
                        sh "helm uninstall ${SERVICE_NAME}-canary"
                        error('Canary deployment rolled back')
                    }
                }
            }
        }
    }
}
```

### Rolling Deployment with Rollback
```groovy
pipeline {
    agent any
    
    stages {
        stage('Deploy') {
            steps {
                sh """
                    # Record current deployment for rollback
                    kubectl annotate deployment ${SERVICE_NAME} \\
                        deployment.kubernetes.io/revision-history-limit=10
                    
                    # Perform rolling update
                    kubectl set image deployment/${SERVICE_NAME} \\
                        ${SERVICE_NAME}=${DOCKER_REGISTRY}/${SERVICE_NAME}:${BUILD_NUMBER}
                    
                    # Wait for rollout to complete
                    kubectl rollout status deployment/${SERVICE_NAME} --timeout=300s
                """
            }
        }
        
        stage('Verify Deployment') {
            steps {
                sh '''
                    # Run smoke tests
                    ./scripts/smoke-tests.sh
                    
                    # Check application metrics
                    ./scripts/verify-metrics.sh
                '''
            }
            post {
                failure {
                    sh """
                        echo "Deployment verification failed, rolling back..."
                        kubectl rollout undo deployment/${SERVICE_NAME}
                        kubectl rollout status deployment/${SERVICE_NAME} --timeout=300s
                    """
                }
            }
        }
    }
}
```
## 9. Advanced Features {#advanced-features}

### Matrix Builds
```groovy
pipeline {
    agent none
    
    stages {
        stage('Matrix Build') {
            matrix {
                axes {
                    axis {
                        name 'JAVA_VERSION'
                        values '11', '17', '21'
                    }
                    axis {
                        name 'OS'
                        values 'linux', 'windows'
                    }
                }
                excludes {
                    exclude {
                        axis {
                            name 'JAVA_VERSION'
                            values '21'
                        }
                        axis {
                            name 'OS'
                            values 'windows'
                        }
                    }
                }
                stages {
                    stage('Build') {
                        agent {
                            label "${OS}"
                        }
                        steps {
                            sh "java -version"
                            sh "mvn clean package -Djava.version=${JAVA_VERSION}"
                        }
                    }
                }
            }
        }
    }
}
```

### Shared Libraries Usage
```groovy
// vars/deployMicroservice.groovy (in shared library)
def call(Map config) {
    pipeline {
        agent any
        
        stages {
            stage('Build') {
                steps {
                    buildApplication(config.buildTool)
                }
            }
            
            stage('Test') {
                steps {
                    runTests(config.testSuite)
                }
            }
            
            stage('Deploy') {
                steps {
                    deployToKubernetes(config.serviceName, config.namespace)
                }
            }
        }
    }
}

// Jenkinsfile using shared library
@Library('company-jenkins-library') _

deployMicroservice([
    serviceName: 'user-service',
    buildTool: 'maven',
    testSuite: 'integration',
    namespace: 'production'
])
```

### Dynamic Pipeline Generation
```groovy
pipeline {
    agent any
    
    stages {
        stage('Generate Pipelines') {
            steps {
                script {
                    def services = ['user-service', 'order-service', 'payment-service']
                    def parallelStages = [:]
                    
                    services.each { service ->
                        parallelStages[service] = {
                            build job: "microservices/${service}/main",
                                  parameters: [
                                      string(name: 'IMAGE_TAG', value: env.BUILD_NUMBER),
                                      string(name: 'ENVIRONMENT', value: 'staging')
                                  ]
                        }
                    }
                    
                    parallel parallelStages
                }
            }
        }
    }
}
```

### Conditional Deployments with Approvals
```groovy
pipeline {
    agent any
    
    stages {
        stage('Deploy to Staging') {
            steps {
                sh "helm upgrade ${SERVICE_NAME} ./chart --namespace staging"
            }
        }
        
        stage('Integration Tests') {
            steps {
                sh './scripts/integration-tests.sh staging'
            }
        }
        
        stage('Production Approval') {
            when {
                branch 'main'
            }
            steps {
                script {
                    def approvers = ['team-lead@company.com', 'devops@company.com']
                    def approver = input(
                        message: 'Deploy to production?',
                        submitterParameter: 'APPROVER',
                        submitter: approvers.join(','),
                        parameters: [
                            choice(
                                name: 'DEPLOYMENT_TYPE',
                                choices: ['blue-green', 'canary', 'rolling'],
                                description: 'Deployment strategy'
                            )
                        ]
                    )
                    
                    env.APPROVED_BY = approver.APPROVER
                    env.DEPLOYMENT_TYPE = approver.DEPLOYMENT_TYPE
                }
            }
        }
        
        stage('Deploy to Production') {
            when {
                branch 'main'
            }
            steps {
                sh """
                    echo "Deploying to production using ${env.DEPLOYMENT_TYPE} strategy"
                    echo "Approved by: ${env.APPROVED_BY}"
                    ./scripts/deploy-${env.DEPLOYMENT_TYPE}.sh production
                """
            }
        }
    }
}
```

### Pipeline as Code with Configuration
```groovy
// pipeline-config.yaml
services:
  - name: user-service
    path: services/user
    buildTool: maven
    testCommand: mvn test
    deploymentStrategy: blue-green
  - name: order-service
    path: services/order
    buildTool: gradle
    testCommand: ./gradlew test
    deploymentStrategy: canary

// Jenkinsfile
pipeline {
    agent any
    
    stages {
        stage('Load Configuration') {
            steps {
                script {
                    def config = readYaml file: 'pipeline-config.yaml'
                    env.SERVICES_CONFIG = writeJSON returnText: true, json: config.services
                }
            }
        }
        
        stage('Process Services') {
            steps {
                script {
                    def services = readJSON text: env.SERVICES_CONFIG
                    def parallelStages = [:]
                    
                    services.each { service ->
                        parallelStages[service.name] = {
                            dir(service.path) {
                                sh service.testCommand
                                sh "docker build -t ${service.name}:${BUILD_NUMBER} ."
                                sh "./deploy-${service.deploymentStrategy}.sh"
                            }
                        }
                    }
                    
                    parallel parallelStages
                }
            }
        }
    }
}
```

## 10. Best Practices {#best-practices}

### Security Best Practices
```groovy
pipeline {
    agent any
    
    environment {
        // Use credentials binding
        DB_PASSWORD = credentials('database-password')
        API_KEY = credentials('external-api-key')
        
        // Avoid hardcoded secrets
        DOCKER_REGISTRY = credentials('docker-registry-url')
    }
    
    stages {
        stage('Security Checks') {
            steps {
                // Scan for secrets in code
                sh 'truffleHog --regex --entropy=False .'
                
                // Dependency vulnerability scan
                sh 'safety check'
                
                // Container image scan
                sh 'trivy image --severity HIGH,CRITICAL ${DOCKER_IMAGE}'
            }
        }
    }
    
    post {
        always {
            // Clean up sensitive data
            sh 'rm -f .env || true'
            cleanWs()
        }
    }
}
```

### Performance Optimization
```groovy
pipeline {
    agent any
    
    options {
        // Optimize build performance
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        skipDefaultCheckout()
        parallelsAlwaysFailFast()
    }
    
    stages {
        stage('Optimized Checkout') {
            steps {
                // Shallow clone for faster checkout
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: "*/${env.BRANCH_NAME}"]],
                    extensions: [
                        [$class: 'CloneOption', depth: 1, shallow: true],
                        [$class: 'CheckoutOption', timeout: 20]
                    ],
                    userRemoteConfigs: [[url: env.GIT_URL]]
                ])
            }
        }
        
        stage('Cache Dependencies') {
            steps {
                // Use build cache
                cache(maxCacheSize: 250, caches: [
                    arbitraryFileCache(
                        path: '.m2/repository',
                        includes: '**/*',
                        fingerprinting: true
                    )
                ]) {
                    sh 'mvn dependency:go-offline'
                }
            }
        }
    }
}
```

### Error Handling and Notifications
```groovy
pipeline {
    agent any
    
    stages {
        stage('Build with Retry') {
            retry(3) {
                steps {
                    sh 'mvn clean package'
                }
            }
        }
        
        stage('Deploy with Timeout') {
            timeout(time: 10, unit: 'MINUTES') {
                steps {
                    sh 'kubectl apply -f deployment.yaml'
                    sh 'kubectl rollout status deployment/myapp'
                }
            }
        }
    }
    
    post {
        always {
            // Archive logs and artifacts
            archiveArtifacts artifacts: 'target/*.jar', allowEmptyArchive: true
            publishTestResults testResultsPattern: 'target/surefire-reports/*.xml'
        }
        
        success {
            slackSend(
                channel: '#deployments',
                color: 'good',
                message: "✅ ${env.JOB_NAME} - ${env.BUILD_NUMBER} deployed successfully"
            )
        }
        
        failure {
            script {
                def logUrl = "${env.BUILD_URL}console"
                def changeAuthor = env.CHANGE_AUTHOR_EMAIL ?: 'team@company.com'
                
                emailext(
                    subject: "❌ Build Failed: ${env.JOB_NAME} - ${env.BUILD_NUMBER}",
                    body: """
                        Build failed for ${env.JOB_NAME} - ${env.BUILD_NUMBER}
                        
                        Branch: ${env.BRANCH_NAME}
                        Commit: ${env.GIT_COMMIT}
                        
                        Console Output: ${logUrl}
                        
                        Please check the logs and fix the issues.
                    """,
                    to: changeAuthor
                )
                
                slackSend(
                    channel: '#alerts',
                    color: 'danger',
                    message: "❌ ${env.JOB_NAME} - ${env.BUILD_NUMBER} failed. Check ${logUrl}"
                )
            }
        }
        
        unstable {
            slackSend(
                channel: '#alerts',
                color: 'warning',
                message: "⚠️ ${env.JOB_NAME} - ${env.BUILD_NUMBER} is unstable"
            )
        }
    }
}
```

### Monitoring and Observability
```groovy
pipeline {
    agent any
    
    stages {
        stage('Deploy with Monitoring') {
            steps {
                sh '''
                    # Deploy application
                    kubectl apply -f deployment.yaml
                    
                    # Wait for deployment
                    kubectl rollout status deployment/myapp
                    
                    # Setup monitoring
                    kubectl apply -f monitoring/servicemonitor.yaml
                    
                    # Create Grafana dashboard
                    curl -X POST http://grafana:3000/api/dashboards/db \\
                         -H "Content-Type: application/json" \\
                         -d @monitoring/dashboard.json
                '''
            }
        }
        
        stage('Health Check') {
            steps {
                script {
                    def healthCheckPassed = false
                    def attempts = 0
                    def maxAttempts = 10
                    
                    while (!healthCheckPassed && attempts < maxAttempts) {
                        try {
                            sh 'curl -f http://myapp/health'
                            healthCheckPassed = true
                        } catch (Exception e) {
                            attempts++
                            sleep(30)
                        }
                    }
                    
                    if (!healthCheckPassed) {
                        error('Health check failed after ${maxAttempts} attempts')
                    }
                }
            }
        }
    }
}
```

### Key Takeaways

1. **Start Simple**: Begin with basic pipeline structure and gradually add complexity
2. **Use Shared Libraries**: Create reusable components for common patterns
3. **Implement Proper Testing**: Include unit, integration, and security tests
4. **Plan for Rollbacks**: Always have a rollback strategy
5. **Monitor Everything**: Implement comprehensive monitoring and alerting
6. **Security First**: Never hardcode secrets, use proper credential management
7. **Optimize Performance**: Use caching, parallel execution, and shallow clones
8. **Document Everything**: Keep pipeline documentation up to date

This guide provides a comprehensive foundation for implementing Jenkins declarative pipelines for microservices CI/CD. Adapt these patterns to your specific technology stack and organizational requirements.
