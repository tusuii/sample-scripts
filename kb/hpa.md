# Horizontal Pod Autoscaler (HPA) Implementation Guide for GKE

## Table of Contents
1. [Introduction to HPA](#introduction)
2. [Prerequisites and Requirements](#prerequisites)
3. [Zero-Downtime Implementation Strategy](#zero-downtime)
4. [Basic HPA Configuration](#basic-hpa)
5. [Advanced HPA with Custom Metrics](#advanced-hpa)
6. [Multi-Metric HPA](#multi-metric)
7. [VPA Integration](#vpa-integration)
8. [Monitoring and Observability](#monitoring)
9. [Testing and Validation](#testing)
10. [Troubleshooting](#troubleshooting)
11. [Best Practices](#best-practices)

## 1. Introduction to HPA {#introduction}

HPA automatically scales the number of pods in a deployment based on observed CPU utilization, memory usage, or custom metrics. It ensures your application can handle varying loads while optimizing resource costs.

### How HPA Works:
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Metrics API   │───▶│       HPA       │───▶│   Deployment    │
│  (CPU/Memory/   │    │   Controller    │    │   (Pod Scaling) │
│  Custom)        │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         ▲                       │                       │
         │                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │    │   Scale Up/Down │    │   Pod Replicas  │
│     Pods        │    │   Decisions     │    │   1 → 2 → 3 → N │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Benefits:
- **Cost Optimization**: Scale down during low traffic
- **Performance**: Scale up during high traffic
- **Automation**: No manual intervention required
- **Resource Efficiency**: Right-size your application

## 2. Prerequisites and Requirements {#prerequisites}

### GKE Cluster Requirements
```bash
# Verify cluster has metrics server
kubectl get deployment metrics-server -n kube-system

# Enable HPA if not already enabled
gcloud container clusters update YOUR_CLUSTER_NAME \
    --enable-autoscaling \
    --min-nodes 1 \
    --max-nodes 10 \
    --zone YOUR_ZONE

# Verify HPA API version
kubectl api-versions | grep autoscaling
```

### Application Requirements Checklist
```yaml
# deployment-requirements.yaml
requirements:
  resource_requests:
    cpu: "100m"      # REQUIRED for CPU-based HPA
    memory: "128Mi"  # REQUIRED for memory-based HPA
  
  health_checks:
    readiness_probe: true  # REQUIRED for safe scaling
    liveness_probe: true   # RECOMMENDED
  
  graceful_shutdown:
    termination_grace_period: 30s  # REQUIRED for zero-downtime
  
  pod_disruption_budget:
    min_available: 1  # REQUIRED for zero-downtime
```

### Enable Metrics Server (if not present)
```yaml
# metrics-server.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
      - name: metrics-server
        image: k8s.gcr.io/metrics-server/metrics-server:v0.6.1
        args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
        ports:
        - containerPort: 4443
          name: https
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          periodSeconds: 10
        securityContext:
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
      serviceAccountName: metrics-server
      volumes:
      - name: tmp-dir
        emptyDir: {}
```

## 3. Zero-Downtime Implementation Strategy {#zero-downtime}

### Phase 1: Prepare Application for HPA
```yaml
# Step 1: Update deployment with resource requests
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 3  # Start with minimum desired replicas
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: my-app
        image: my-app:v1.0.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m      # CRITICAL: Required for HPA
            memory: 128Mi  # CRITICAL: Required for memory-based HPA
          limits:
            cpu: 500m      # Prevent resource starvation
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]  # Graceful shutdown
      terminationGracePeriodSeconds: 30
```

### Phase 2: Create Pod Disruption Budget
```yaml
# pod-disruption-budget.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
  namespace: default
spec:
  minAvailable: 1  # Always keep at least 1 pod running
  selector:
    matchLabels:
      app: my-app
---
# Alternative: Use percentage
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb-percentage
  namespace: default
spec:
  minAvailable: 50%  # Keep at least 50% of pods running
  selector:
    matchLabels:
      app: my-app
```

### Phase 3: Gradual HPA Rollout Script
```bash
#!/bin/bash
# gradual-hpa-rollout.sh

set -e

APP_NAME="my-app"
NAMESPACE="default"
MIN_REPLICAS=3
MAX_REPLICAS=10
TARGET_CPU=70

echo "🚀 Starting zero-downtime HPA implementation for $APP_NAME"

# Step 1: Verify current deployment
echo "📊 Checking current deployment status..."
kubectl get deployment $APP_NAME -n $NAMESPACE
kubectl get pods -l app=$APP_NAME -n $NAMESPACE

# Step 2: Verify resource requests are set
echo "🔍 Verifying resource requests..."
RESOURCE_REQUESTS=$(kubectl get deployment $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
if [ -z "$RESOURCE_REQUESTS" ]; then
    echo "❌ ERROR: No CPU resource requests found. Please update deployment first."
    exit 1
fi
echo "✅ CPU resource requests found: $RESOURCE_REQUESTS"

# Step 3: Create PDB if not exists
echo "🛡️ Creating Pod Disruption Budget..."
kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${APP_NAME}-pdb
  namespace: $NAMESPACE
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: $APP_NAME
EOF

# Step 4: Wait for PDB to be active
echo "⏳ Waiting for PDB to be active..."
kubectl wait --for=condition=Ready pdb/${APP_NAME}-pdb -n $NAMESPACE --timeout=60s

# Step 5: Create HPA
echo "📈 Creating HPA..."
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}-hpa
  namespace: $NAMESPACE
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $APP_NAME
  minReplicas: $MIN_REPLICAS
  maxReplicas: $MAX_REPLICAS
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: $TARGET_CPU
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
EOF

# Step 6: Verify HPA is working
echo "🔍 Verifying HPA status..."
sleep 30
kubectl get hpa $APP_NAME-hpa -n $NAMESPACE

# Step 7: Monitor for 5 minutes
echo "👀 Monitoring HPA for 5 minutes..."
for i in {1..10}; do
    echo "Check $i/10:"
    kubectl get hpa $APP_NAME-hpa -n $NAMESPACE
    kubectl get pods -l app=$APP_NAME -n $NAMESPACE --no-headers | wc -l | xargs echo "Current pod count:"
    sleep 30
done

echo "✅ HPA implementation completed successfully!"
echo "📊 Final status:"
kubectl get hpa $APP_NAME-hpa -n $NAMESPACE
kubectl get deployment $APP_NAME -n $NAMESPACE
```

## 4. Basic HPA Configuration {#basic-hpa}

### CPU-Based HPA
```yaml
# cpu-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-cpu-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70  # Scale when CPU > 70%
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60   # Wait 60s before scaling up
      policies:
      - type: Percent
        value: 100    # Double the pods
        periodSeconds: 60
      - type: Pods
        value: 2      # Or add max 2 pods
        periodSeconds: 60
      selectPolicy: Min  # Use the more conservative policy
    scaleDown:
      stabilizationWindowSeconds: 300  # Wait 5min before scaling down
      policies:
      - type: Percent
        value: 10     # Remove 10% of pods
        periodSeconds: 60
```

### Memory-Based HPA
```yaml
# memory-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-memory-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 15
  metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80  # Scale when Memory > 80%
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 120
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 600  # 10 minutes for memory
      policies:
      - type: Percent
        value: 5      # Very conservative memory scale-down
        periodSeconds: 60
```

### Combined CPU and Memory HPA
```yaml
# combined-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-combined-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 3
        periodSeconds: 60
      selectPolicy: Max  # Use the more aggressive policy for scale-up
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
      selectPolicy: Min  # Use the more conservative policy for scale-down
```
## 5. Advanced HPA with Custom Metrics {#advanced-hpa}

### Request-Per-Second (RPS) Based HPA
```yaml
# rps-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-rps-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 50
  metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"  # 100 RPS per pod
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30   # Quick scale-up for traffic spikes
      policies:
      - type: Percent
        value: 200   # Triple the pods if needed
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 600  # Slow scale-down for traffic
      policies:
      - type: Percent
        value: 5
        periodSeconds: 60
```

### Queue Length Based HPA
```yaml
# queue-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: worker-queue-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker-app
  minReplicas: 1
  maxReplicas: 30
  metrics:
  - type: External
    external:
      metric:
        name: pubsub.googleapis.com|subscription|num_undelivered_messages
        selector:
          matchLabels:
            resource.labels.subscription_id: "my-subscription"
      target:
        type: AverageValue
        averageValue: "10"  # 10 messages per pod
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 300  # Scale aggressively for queue buildup
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1    # Remove one pod at a time
        periodSeconds: 60
```

### Custom Application Metrics HPA
```yaml
# custom-metrics-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-custom-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 25
  metrics:
  - type: Pods
    pods:
      metric:
        name: active_connections
      target:
        type: AverageValue
        averageValue: "50"  # 50 active connections per pod
  - type: Pods
    pods:
      metric:
        name: response_time_p95
      target:
        type: AverageValue
        averageValue: "500m"  # 500ms P95 response time
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 15
        periodSeconds: 60
```

### Setup Custom Metrics Server
```yaml
# custom-metrics-server.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-metrics-apiserver
  namespace: custom-metrics
spec:
  replicas: 1
  selector:
    matchLabels:
      app: custom-metrics-apiserver
  template:
    metadata:
      labels:
        app: custom-metrics-apiserver
    spec:
      serviceAccountName: custom-metrics-apiserver
      containers:
      - name: custom-metrics-apiserver
        image: k8s.gcr.io/prometheus-adapter/prometheus-adapter:v0.10.0
        args:
        - --secure-port=6443
        - --tls-cert-file=/var/run/serving-cert/tls.crt
        - --tls-private-key-file=/var/run/serving-cert/tls.key
        - --logtostderr=true
        - --prometheus-url=http://prometheus.monitoring.svc:9090/
        - --metrics-relist-interval=1m
        - --v=4
        - --config=/etc/adapter/config.yaml
        ports:
        - containerPort: 6443
        volumeMounts:
        - mountPath: /var/run/serving-cert
          name: volume-serving-cert
          readOnly: true
        - mountPath: /etc/adapter/
          name: config
          readOnly: true
        - mountPath: /tmp
          name: tmp-vol
      volumes:
      - name: volume-serving-cert
        secret:
          secretName: cm-adapter-serving-certs
      - name: config
        configMap:
          name: adapter-config
      - name: tmp-vol
        emptyDir: {}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: adapter-config
  namespace: custom-metrics
data:
  config.yaml: |
    rules:
    - seriesQuery: 'http_requests_per_second{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)_per_second"
        as: "${1}_per_second"
      metricsQuery: 'sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
    
    - seriesQuery: 'active_connections{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        as: "active_connections"
      metricsQuery: 'sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
    
    - seriesQuery: 'response_time_p95{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        as: "response_time_p95"
      metricsQuery: 'avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
```

## 6. Multi-Metric HPA {#multi-metric}

### Production-Ready Multi-Metric HPA
```yaml
# production-multi-metric-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: production-app-hpa
  namespace: production
  annotations:
    description: "Production HPA with multiple metrics for comprehensive scaling"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: production-app
  minReplicas: 5    # Higher minimum for production
  maxReplicas: 100  # Allow significant scaling
  metrics:
  # Primary metric: CPU utilization
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60  # Conservative for production
  
  # Secondary metric: Memory utilization
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
  
  # Traffic-based metric: Requests per second
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "80"  # 80 RPS per pod
  
  # Performance metric: Response time
  - type: Pods
    pods:
      metric:
        name: response_time_p95
      target:
        type: AverageValue
        averageValue: "800m"  # 800ms P95 response time
  
  # Business metric: Active user sessions
  - type: Pods
    pods:
      metric:
        name: active_user_sessions
      target:
        type: AverageValue
        averageValue: "200"  # 200 active sessions per pod
  
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 50    # Moderate scale-up
        periodSeconds: 60
      - type: Pods
        value: 5     # Add max 5 pods at once
        periodSeconds: 60
      selectPolicy: Min  # Conservative approach
    
    scaleDown:
      stabilizationWindowSeconds: 600  # 10 minutes stabilization
      policies:
      - type: Percent
        value: 5     # Very conservative scale-down
        periodSeconds: 120
      - type: Pods
        value: 1     # Remove max 1 pod at a time
        periodSeconds: 120
      selectPolicy: Min  # Most conservative approach
```

### Microservices HPA Configuration
```yaml
# microservices-hpa-set.yaml
# User Service HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user-service-hpa
  namespace: microservices
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Pods
    pods:
      metric:
        name: database_connections
      target:
        type: AverageValue
        averageValue: "10"  # 10 DB connections per pod
---
# Order Service HPA (CPU intensive)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
  namespace: microservices
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  minReplicas: 2
  maxReplicas: 30
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60  # Lower threshold for order processing
  - type: Pods
    pods:
      metric:
        name: pending_orders
      target:
        type: AverageValue
        averageValue: "5"   # 5 pending orders per pod
---
# Payment Service HPA (Memory intensive)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payment-service-hpa
  namespace: microservices
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  minReplicas: 3  # Higher minimum for critical service
  maxReplicas: 15
  metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 75
  - type: Pods
    pods:
      metric:
        name: payment_queue_length
      target:
        type: AverageValue
        averageValue: "3"   # 3 payments per pod
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30   # Quick scale for payments
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 900  # Very slow scale-down for payments
      policies:
      - type: Pods
        value: 1
        periodSeconds: 180
```

## 7. VPA Integration {#vpa-integration}

### Vertical Pod Autoscaler Setup
```yaml
# vpa-setup.yaml
# Install VPA (run once)
apiVersion: v1
kind: Namespace
metadata:
  name: vpa-system
---
# VPA for resource recommendations
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
  namespace: default
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Off"  # Only provide recommendations, don't auto-update
  resourcePolicy:
    containerPolicies:
    - containerName: my-app
      minAllowed:
        cpu: 50m
        memory: 64Mi
      maxAllowed:
        cpu: 2
        memory: 2Gi
      controlledResources: ["cpu", "memory"]
```

### HPA + VPA Coordination
```yaml
# hpa-vpa-coordination.yaml
# HPA for horizontal scaling
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
---
# VPA for vertical scaling (recommendation mode)
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
  namespace: default
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Off"  # Avoid conflicts with HPA
  resourcePolicy:
    containerPolicies:
    - containerName: my-app
      controlledResources: ["memory"]  # Only recommend memory, let HPA handle CPU
```

### VPA Recommendations Analysis Script
```bash
#!/bin/bash
# vpa-analysis.sh

NAMESPACE="default"
VPA_NAME="my-app-vpa"

echo "📊 VPA Recommendations Analysis"
echo "================================"

# Get current VPA recommendations
kubectl get vpa $VPA_NAME -n $NAMESPACE -o yaml > vpa-recommendations.yaml

# Extract recommendations
CURRENT_CPU=$(kubectl get deployment my-app -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
CURRENT_MEMORY=$(kubectl get deployment my-app -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')

RECOMMENDED_CPU=$(kubectl get vpa $VPA_NAME -n $NAMESPACE -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}')
RECOMMENDED_MEMORY=$(kubectl get vpa $VPA_NAME -n $NAMESPACE -o jsonpath='{.status.recommendation.containerRecommendations[0].target.memory}')

echo "Current Resources:"
echo "  CPU: $CURRENT_CPU"
echo "  Memory: $CURRENT_MEMORY"
echo ""
echo "VPA Recommendations:"
echo "  CPU: $RECOMMENDED_CPU"
echo "  Memory: $RECOMMENDED_MEMORY"
echo ""

# Calculate if update is needed (simplified)
if [ "$CURRENT_CPU" != "$RECOMMENDED_CPU" ] || [ "$CURRENT_MEMORY" != "$RECOMMENDED_MEMORY" ]; then
    echo "⚠️  Resource update recommended"
    echo "💡 Consider updating deployment with new resource requests"
    
    cat > resource-update.yaml <<EOF
spec:
  template:
    spec:
      containers:
      - name: my-app
        resources:
          requests:
            cpu: $RECOMMENDED_CPU
            memory: $RECOMMENDED_MEMORY
          limits:
            cpu: $(echo $RECOMMENDED_CPU | sed 's/m/*2m/g' | bc)  # 2x requests
            memory: $(echo $RECOMMENDED_MEMORY | sed 's/Mi/*2Mi/g' | bc)  # 2x requests
EOF
    echo "📝 Resource update template created: resource-update.yaml"
else
    echo "✅ Current resources are optimal"
fi
```
## 8. Monitoring and Observability {#monitoring}

### HPA Monitoring Dashboard
```yaml
# hpa-monitoring.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-dashboard
  namespace: monitoring
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "HPA Monitoring Dashboard",
        "panels": [
          {
            "title": "HPA Scaling Events",
            "type": "graph",
            "targets": [
              {
                "expr": "kube_horizontalpodautoscaler_status_current_replicas",
                "legendFormat": "Current Replicas - {{horizontalpodautoscaler}}"
              },
              {
                "expr": "kube_horizontalpodautoscaler_status_desired_replicas",
                "legendFormat": "Desired Replicas - {{horizontalpodautoscaler}}"
              }
            ]
          },
          {
            "title": "CPU Utilization vs Target",
            "type": "graph",
            "targets": [
              {
                "expr": "kube_horizontalpodautoscaler_status_current_metrics_average_utilization{metric_name=\"cpu\"}",
                "legendFormat": "Current CPU - {{horizontalpodautoscaler}}"
              },
              {
                "expr": "kube_horizontalpodautoscaler_spec_target_metric_average_utilization{metric_name=\"cpu\"}",
                "legendFormat": "Target CPU - {{horizontalpodautoscaler}}"
              }
            ]
          },
          {
            "title": "Memory Utilization vs Target",
            "type": "graph",
            "targets": [
              {
                "expr": "kube_horizontalpodautoscaler_status_current_metrics_average_utilization{metric_name=\"memory\"}",
                "legendFormat": "Current Memory - {{horizontalpodautoscaler}}"
              },
              {
                "expr": "kube_horizontalpodautoscaler_spec_target_metric_average_utilization{metric_name=\"memory\"}",
                "legendFormat": "Target Memory - {{horizontalpodautoscaler}}"
              }
            ]
          },
          {
            "title": "Scaling Decisions Timeline",
            "type": "table",
            "targets": [
              {
                "expr": "increase(kube_horizontalpodautoscaler_status_desired_replicas[5m])",
                "format": "table"
              }
            ]
          }
        ]
      }
    }
```

### HPA Metrics Collection
```yaml
# hpa-metrics-exporter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hpa-metrics-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hpa-metrics-exporter
  template:
    metadata:
      labels:
        app: hpa-metrics-exporter
    spec:
      serviceAccountName: hpa-metrics-exporter
      containers:
      - name: exporter
        image: prom/node-exporter:latest
        ports:
        - containerPort: 9100
        command:
        - /bin/sh
        - -c
        - |
          while true; do
            # Export HPA metrics
            kubectl get hpa --all-namespaces -o json | jq -r '
              .items[] | 
              "hpa_current_replicas{name=\"" + .metadata.name + "\",namespace=\"" + .metadata.namespace + "\"} " + (.status.currentReplicas | tostring) + "\n" +
              "hpa_desired_replicas{name=\"" + .metadata.name + "\",namespace=\"" + .metadata.namespace + "\"} " + (.status.desiredReplicas | tostring) + "\n" +
              "hpa_min_replicas{name=\"" + .metadata.name + "\",namespace=\"" + .metadata.namespace + "\"} " + (.spec.minReplicas | tostring) + "\n" +
              "hpa_max_replicas{name=\"" + .metadata.name + "\",namespace=\"" + .metadata.namespace + "\"} " + (.spec.maxReplicas | tostring)
            ' > /tmp/hpa_metrics.prom
            sleep 30
          done
        volumeMounts:
        - name: metrics
          mountPath: /tmp
      volumes:
      - name: metrics
        emptyDir: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hpa-metrics-exporter
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hpa-metrics-reader
rules:
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hpa-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hpa-metrics-reader
subjects:
- kind: ServiceAccount
  name: hpa-metrics-exporter
  namespace: monitoring
```

### HPA Alerting Rules
```yaml
# hpa-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hpa-alerts
  namespace: monitoring
spec:
  groups:
  - name: hpa.rules
    rules:
    - alert: HPAScalingDisabled
      expr: kube_horizontalpodautoscaler_status_condition{condition="ScalingDisabled", status="true"} == 1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "HPA scaling is disabled"
        description: "HPA {{ $labels.horizontalpodautoscaler }} in namespace {{ $labels.namespace }} has scaling disabled"
    
    - alert: HPAMaxReplicasReached
      expr: kube_horizontalpodautoscaler_status_current_replicas == kube_horizontalpodautoscaler_spec_max_replicas
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "HPA has reached maximum replicas"
        description: "HPA {{ $labels.horizontalpodautoscaler }} has reached maximum replicas ({{ $value }})"
    
    - alert: HPAHighCPUUtilization
      expr: kube_horizontalpodautoscaler_status_current_metrics_average_utilization{metric_name="cpu"} > 90
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Very high CPU utilization despite HPA scaling"
        description: "CPU utilization is {{ $value }}% for HPA {{ $labels.horizontalpodautoscaler }}"
    
    - alert: HPAScalingTooFrequent
      expr: increase(kube_horizontalpodautoscaler_status_desired_replicas[10m]) > 5
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "HPA is scaling too frequently"
        description: "HPA {{ $labels.horizontalpodautoscaler }} has scaled {{ $value }} times in 10 minutes"
    
    - alert: HPAMetricsUnavailable
      expr: kube_horizontalpodautoscaler_status_condition{condition="ScalingActive", status="false"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "HPA metrics are unavailable"
        description: "HPA {{ $labels.horizontalpodautoscaler }} cannot get metrics for scaling decisions"
```

## 9. Testing and Validation {#testing}

### HPA Load Testing Script
```bash
#!/bin/bash
# hpa-load-test.sh

set -e

APP_NAME="my-app"
NAMESPACE="default"
HPA_NAME="${APP_NAME}-hpa"
SERVICE_URL="http://my-app-service.default.svc.cluster.local:8080"

echo "🚀 Starting HPA Load Test for $APP_NAME"

# Function to get current metrics
get_metrics() {
    echo "📊 Current HPA Status:"
    kubectl get hpa $HPA_NAME -n $NAMESPACE
    echo ""
    echo "📈 Current Pod Count:"
    kubectl get pods -l app=$APP_NAME -n $NAMESPACE --no-headers | wc -l
    echo ""
    echo "💻 Resource Utilization:"
    kubectl top pods -l app=$APP_NAME -n $NAMESPACE
    echo "----------------------------------------"
}

# Initial state
echo "📋 Initial State:"
get_metrics

# Phase 1: Light load
echo "🔥 Phase 1: Light Load (10 RPS for 2 minutes)"
kubectl run load-test-light --rm -i --restart=Never --image=busybox -- /bin/sh -c "
  for i in \$(seq 1 120); do
    for j in \$(seq 1 10); do
      wget -q -O- $SERVICE_URL/health &
    done
    sleep 1
  done
  wait
" &

LIGHT_PID=$!
sleep 60
get_metrics
wait $LIGHT_PID

# Phase 2: Medium load
echo "🔥 Phase 2: Medium Load (50 RPS for 3 minutes)"
kubectl run load-test-medium --rm -i --restart=Never --image=busybox -- /bin/sh -c "
  for i in \$(seq 1 180); do
    for j in \$(seq 1 50); do
      wget -q -O- $SERVICE_URL/api/data &
    done
    sleep 1
  done
  wait
" &

MEDIUM_PID=$!
sleep 90
get_metrics
sleep 90
get_metrics
wait $MEDIUM_PID

# Phase 3: Heavy load
echo "🔥 Phase 3: Heavy Load (200 RPS for 5 minutes)"
kubectl run load-test-heavy --rm -i --restart=Never --image=busybox -- /bin/sh -c "
  for i in \$(seq 1 300); do
    for j in \$(seq 1 200); do
      wget -q -O- $SERVICE_URL/api/compute &
    done
    sleep 1
  done
  wait
" &

HEAVY_PID=$!
for i in {1..5}; do
    sleep 60
    echo "Heavy load minute $i/5:"
    get_metrics
done
wait $HEAVY_PID

# Phase 4: Cool down
echo "❄️ Phase 4: Cool Down (5 minutes)"
for i in {1..5}; do
    sleep 60
    echo "Cool down minute $i/5:"
    get_metrics
done

echo "✅ HPA Load Test Completed!"
echo "📊 Final Metrics:"
get_metrics

# Generate test report
cat > hpa-test-report.md <<EOF
# HPA Load Test Report

## Test Summary
- **Application**: $APP_NAME
- **Namespace**: $NAMESPACE
- **Test Duration**: ~15 minutes
- **Load Phases**: Light (10 RPS) → Medium (50 RPS) → Heavy (200 RPS) → Cool Down

## Final Results
\`\`\`
$(kubectl get hpa $HPA_NAME -n $NAMESPACE)
\`\`\`

## Pod Scaling Timeline
\`\`\`
$(kubectl describe hpa $HPA_NAME -n $NAMESPACE | grep -A 20 "Events:")
\`\`\`

## Recommendations
- Monitor scaling behavior during peak hours
- Adjust thresholds if scaling is too aggressive/conservative
- Consider custom metrics for better scaling decisions
EOF

echo "📝 Test report generated: hpa-test-report.md"
```

### HPA Validation Checklist
```bash
#!/bin/bash
# hpa-validation.sh

APP_NAME="my-app"
NAMESPACE="default"
HPA_NAME="${APP_NAME}-hpa"

echo "✅ HPA Validation Checklist"
echo "=========================="

# Check 1: HPA exists and is active
echo "1. Checking HPA existence..."
if kubectl get hpa $HPA_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "   ✅ HPA exists"
else
    echo "   ❌ HPA not found"
    exit 1
fi

# Check 2: Metrics server is running
echo "2. Checking metrics server..."
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "   ✅ Metrics server is running"
else
    echo "   ❌ Metrics server not found"
fi

# Check 3: Resource requests are set
echo "3. Checking resource requests..."
CPU_REQUEST=$(kubectl get deployment $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
MEMORY_REQUEST=$(kubectl get deployment $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')

if [ -n "$CPU_REQUEST" ]; then
    echo "   ✅ CPU requests set: $CPU_REQUEST"
else
    echo "   ❌ CPU requests not set"
fi

if [ -n "$MEMORY_REQUEST" ]; then
    echo "   ✅ Memory requests set: $MEMORY_REQUEST"
else
    echo "   ❌ Memory requests not set"
fi

# Check 4: HPA can get metrics
echo "4. Checking HPA metrics..."
HPA_STATUS=$(kubectl get hpa $HPA_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}')
if [ "$HPA_STATUS" = "True" ]; then
    echo "   ✅ HPA can get metrics"
else
    echo "   ❌ HPA cannot get metrics"
    kubectl describe hpa $HPA_NAME -n $NAMESPACE | grep -A 5 "Conditions:"
fi

# Check 5: Pod Disruption Budget exists
echo "5. Checking Pod Disruption Budget..."
if kubectl get pdb ${APP_NAME}-pdb -n $NAMESPACE >/dev/null 2>&1; then
    echo "   ✅ PDB exists"
else
    echo "   ⚠️  PDB not found (recommended for zero-downtime)"
fi

# Check 6: Readiness probes are configured
echo "6. Checking readiness probes..."
READINESS_PROBE=$(kubectl get deployment $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}')
if [ -n "$READINESS_PROBE" ]; then
    echo "   ✅ Readiness probe configured"
else
    echo "   ❌ Readiness probe not configured"
fi

# Check 7: Current HPA status
echo "7. Current HPA status:"
kubectl get hpa $HPA_NAME -n $NAMESPACE
echo ""

# Check 8: Recent scaling events
echo "8. Recent scaling events:"
kubectl describe hpa $HPA_NAME -n $NAMESPACE | grep -A 10 "Events:" | tail -10

echo ""
echo "🎯 Validation complete!"
```

## 10. Troubleshooting {#troubleshooting}

### Common HPA Issues and Solutions

#### Issue 1: HPA Not Scaling
```bash
# Diagnostic script for HPA not scaling
#!/bin/bash
# diagnose-hpa-not-scaling.sh

APP_NAME="my-app"
NAMESPACE="default"
HPA_NAME="${APP_NAME}-hpa"

echo "🔍 Diagnosing HPA Scaling Issues"
echo "================================"

# Check HPA status
echo "1. HPA Status:"
kubectl describe hpa $HPA_NAME -n $NAMESPACE

# Check if metrics are available
echo -e "\n2. Metrics Availability:"
kubectl top pods -l app=$APP_NAME -n $NAMESPACE

# Check resource requests
echo -e "\n3. Resource Requests:"
kubectl get deployment $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .

# Check HPA conditions
echo -e "\n4. HPA Conditions:"
kubectl get hpa $HPA_NAME -n $NAMESPACE -o jsonpath='{.status.conditions}' | jq .

# Check metrics server
echo -e "\n5. Metrics Server Status:"
kubectl get pods -n kube-system -l k8s-app=metrics-server

# Common fixes
echo -e "\n🔧 Common Fixes:"
echo "- Ensure resource requests are set on containers"
echo "- Verify metrics-server is running and healthy"
echo "- Check if custom metrics API is available (for custom metrics)"
echo "- Verify RBAC permissions for HPA controller"
```

#### Issue 2: HPA Scaling Too Aggressively
```yaml
# conservative-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: conservative-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80  # Higher threshold
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 300  # Wait 5 minutes
      policies:
      - type: Percent
        value: 25    # Only 25% increase
        periodSeconds: 60
      - type: Pods
        value: 1     # Max 1 pod at a time
        periodSeconds: 60
      selectPolicy: Min
    scaleDown:
      stabilizationWindowSeconds: 900  # Wait 15 minutes
      policies:
      - type: Percent
        value: 5     # Only 5% decrease
        periodSeconds: 120
      selectPolicy: Min
```

#### Issue 3: Metrics Not Available
```bash
# fix-metrics-issues.sh
#!/bin/bash

echo "🔧 Fixing Metrics Issues"
echo "======================="

# Restart metrics server
echo "1. Restarting metrics server..."
kubectl rollout restart deployment/metrics-server -n kube-system
kubectl rollout status deployment/metrics-server -n kube-system

# Check metrics server logs
echo "2. Checking metrics server logs..."
kubectl logs -n kube-system -l k8s-app=metrics-server --tail=20

# Test metrics API
echo "3. Testing metrics API..."
kubectl top nodes
kubectl top pods --all-namespaces | head -10

# Verify API registration
echo "4. Checking API registration..."
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml

echo "✅ Metrics troubleshooting complete"
```

## 11. Best Practices {#best-practices}

### Production HPA Best Practices

#### 1. Resource Management
```yaml
# production-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: production-app
spec:
  replicas: 5  # Start with adequate baseline
  template:
    spec:
      containers:
      - name: app
        resources:
          requests:
            cpu: 200m      # Set based on actual usage
            memory: 256Mi  # Set based on actual usage
          limits:
            cpu: 1000m     # 5x requests for burst capacity
            memory: 1Gi    # 4x requests for memory spikes
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
```

#### 2. HPA Configuration Guidelines
```yaml
# production-hpa-guidelines.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: production-guidelines-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: production-app
  minReplicas: 5     # Never go below business requirements
  maxReplicas: 50    # Set reasonable upper limit
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60  # Conservative for production
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 120  # 2 minutes stabilization
      policies:
      - type: Percent
        value: 50    # Max 50% increase
        periodSeconds: 60
      - type: Pods
        value: 3     # Max 3 pods at once
        periodSeconds: 60
      selectPolicy: Min  # Conservative approach
    scaleDown:
      stabilizationWindowSeconds: 600  # 10 minutes stabilization
      policies:
      - type: Percent
        value: 10    # Max 10% decrease
        periodSeconds: 120
      - type: Pods
        value: 1     # Max 1 pod at a time
        periodSeconds: 120
      selectPolicy: Min  # Most conservative
```

#### 3. Monitoring and Alerting Strategy
```yaml
# hpa-monitoring-strategy.yaml
monitoring_strategy:
  metrics_to_track:
    - hpa_current_replicas
    - hpa_desired_replicas
    - hpa_scaling_events_rate
    - cpu_utilization_vs_target
    - memory_utilization_vs_target
    - scaling_decision_latency
  
  alerts_to_configure:
    - hpa_max_replicas_reached
    - hpa_scaling_disabled
    - hpa_metrics_unavailable
    - hpa_frequent_scaling
    - resource_utilization_high
  
  dashboards_to_create:
    - hpa_overview_dashboard
    - application_performance_dashboard
    - resource_utilization_dashboard
    - scaling_events_timeline
```

### Key Success Factors

1. **Proper Resource Requests**: Always set CPU/memory requests
2. **Health Checks**: Implement readiness and liveness probes
3. **Pod Disruption Budgets**: Ensure zero-downtime scaling
4. **Conservative Scaling**: Start conservative, tune based on behavior
5. **Monitoring**: Track HPA metrics and scaling events
6. **Testing**: Regularly test scaling behavior under load
7. **Documentation**: Document scaling decisions and thresholds

This comprehensive HPA guide provides everything needed to implement horizontal pod autoscaling in your GKE cluster with zero downtime, including production-ready configurations, monitoring, and troubleshooting procedures.
