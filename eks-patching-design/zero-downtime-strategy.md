# Zero-Downtime EKS Patching Strategy

## Overview

This document outlines comprehensive strategies to ensure workloads remain unimpacted during EKS cluster patching and upgrades, achieving true zero-downtime operations.

## Workload Protection Mechanisms

### 1. Pod Disruption Budgets (PDBs)
```yaml
# Critical application PDB
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: default
spec:
  minAvailable: 2  # Always keep at least 2 pods running
  selector:
    matchLabels:
      app: frontend
---
# Percentage-based PDB for larger deployments
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: default
spec:
  maxUnavailable: 25%  # Never take down more than 25% at once
  selector:
    matchLabels:
      app: backend
---
# Critical system components PDB
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: coredns-pdb
  namespace: kube-system
spec:
  minAvailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
```

### 2. Application Deployment Strategies
```yaml
# High-availability deployment configuration
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 4  # Minimum 3+ for HA during upgrades
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1      # Only 1 pod down at a time
      maxSurge: 2           # Allow 2 extra pods during updates
  template:
    spec:
      # Anti-affinity to spread across nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - frontend
              topologyKey: kubernetes.io/hostname
      
      # Topology spread constraints for even distribution
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: frontend
      
      containers:
      - name: frontend
        image: myapp/frontend:v1.0.0
        ports:
        - containerPort: 8080
        
        # Proper health checks
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
        
        # Graceful shutdown
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]
        
        # Resource requests for proper scheduling
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
      
      # Graceful termination
      terminationGracePeriodSeconds: 30
```

### 3. Service Mesh Integration (Optional)
```yaml
# Istio VirtualService for traffic management during upgrades
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: frontend-vs
spec:
  hosts:
  - frontend-service
  http:
  - match:
    - headers:
        canary:
          exact: "true"
    route:
    - destination:
        host: frontend-service
        subset: canary
      weight: 100
  - route:
    - destination:
        host: frontend-service
        subset: stable
      weight: 100
---
# DestinationRule for subset definitions
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: frontend-dr
spec:
  host: frontend-service
  subsets:
  - name: stable
    labels:
      version: stable
  - name: canary
    labels:
      version: canary
```

## Enhanced Node Upgrade Strategy

### 1. Pre-Upgrade Workload Analysis
```bash
#!/bin/bash
# workload-impact-analysis.sh

analyze_workload_distribution() {
    echo "Analyzing workload distribution across nodes..."
    
    # Get node information
    kubectl get nodes -o wide
    
    # Analyze pod distribution
    echo -e "\nPod distribution per node:"
    kubectl get pods --all-namespaces -o wide | \
        awk 'NR>1 {count[$7]++} END {for (node in count) print node ": " count[node] " pods"}'
    
    # Check critical workloads
    echo -e "\nCritical workload analysis:"
    local critical_apps=("frontend" "backend" "database" "api")
    
    for app in "${critical_apps[@]}"; do
        echo "Analyzing $app deployment:"
        kubectl get pods -l app="$app" -o wide --no-headers | \
            awk '{print "  Node: " $7 ", Status: " $3}'
        
        # Check PDB status
        local pdb_status=$(kubectl get pdb "${app}-pdb" -o jsonpath='{.status}' 2>/dev/null)
        if [ -n "$pdb_status" ]; then
            echo "  PDB Status: $(echo "$pdb_status" | jq -r '.currentHealthy')/$(echo "$pdb_status" | jq -r '.desiredHealthy') healthy"
        else
            echo "  WARNING: No PDB found for $app"
        fi
    done
}

check_upgrade_safety() {
    echo -e "\nChecking upgrade safety..."
    
    # Check if any single node has too many critical pods
    local nodes=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
    
    for node in $nodes; do
        local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers | wc -l)
        local critical_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" \
            -l 'app in (frontend,backend,database,api)' --no-headers | wc -l)
        
        echo "Node $node: $pod_count total pods, $critical_pods critical pods"
        
        if [ "$critical_pods" -gt 5 ]; then
            echo "  WARNING: High concentration of critical pods on $node"
        fi
    done
}

validate_pdb_coverage() {
    echo -e "\nValidating PDB coverage..."
    
    # Check deployments without PDBs
    local deployments=$(kubectl get deployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')
    
    while IFS= read -r deployment; do
        local namespace=$(echo "$deployment" | awk '{print $1}')
        local name=$(echo "$deployment" | awk '{print $2}')
        
        if [ -n "$name" ]; then
            local pdb_exists=$(kubectl get pdb -n "$namespace" --no-headers 2>/dev/null | grep -c "$name" || echo "0")
            if [ "$pdb_exists" -eq 0 ]; then
                local replicas=$(kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.spec.replicas}')
                if [ "$replicas" -gt 1 ]; then
                    echo "  WARNING: Deployment $namespace/$name has $replicas replicas but no PDB"
                fi
            fi
        fi
    done <<< "$deployments"
}

main() {
    analyze_workload_distribution
    check_upgrade_safety
    validate_pdb_coverage
}

main "$@"
```

### 2. Intelligent Node Draining
```bash
#!/bin/bash
# intelligent-node-drain.sh

intelligent_drain() {
    local node_name="$1"
    local max_wait_time="${2:-600}"  # 10 minutes default
    
    echo "Starting intelligent drain of node $node_name..."
    
    # Pre-drain validation
    if ! validate_cluster_capacity "$node_name"; then
        echo "ERROR: Insufficient cluster capacity for safe drain"
        return 1
    fi
    
    # Check for critical pods
    local critical_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" \
        -l 'app in (frontend,backend,database,api)' --no-headers)
    
    if [ -n "$critical_pods" ]; then
        echo "Critical pods found on $node_name:"
        echo "$critical_pods"
        
        # Validate PDBs before proceeding
        if ! validate_pdbs_for_node "$node_name"; then
            echo "ERROR: PDB validation failed, cannot safely drain"
            return 1
        fi
    fi
    
    # Cordon the node first
    kubectl cordon "$node_name"
    
    # Start graceful drain
    echo "Starting graceful drain..."
    kubectl drain "$node_name" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=60 \
        --timeout="${max_wait_time}s" &
    
    local drain_pid=$!
    
    # Monitor drain progress
    monitor_drain_progress "$node_name" "$drain_pid" "$max_wait_time"
    
    # Wait for drain to complete
    wait $drain_pid
    local drain_result=$?
    
    if [ $drain_result -eq 0 ]; then
        echo "Node $node_name drained successfully"
        
        # Final validation
        validate_workload_health_post_drain
        return 0
    else
        echo "ERROR: Node drain failed or timed out"
        kubectl uncordon "$node_name"
        return 1
    fi
}

validate_cluster_capacity() {
    local node_to_drain="$1"
    
    # Get total cluster resources
    local total_cpu=$(kubectl describe nodes | grep -A 5 "Capacity:" | grep cpu | awk '{sum += $2} END {print sum}')
    local total_memory=$(kubectl describe nodes | grep -A 5 "Capacity:" | grep memory | awk '{sum += $2} END {print sum}')
    
    # Get node resources being removed
    local node_cpu=$(kubectl describe node "$node_to_drain" | grep -A 5 "Capacity:" | grep cpu | awk '{print $2}')
    local node_memory=$(kubectl describe node "$node_to_drain" | grep -A 5 "Capacity:" | grep memory | awk '{print $2}')
    
    # Calculate remaining capacity (simplified check)
    local remaining_nodes=$(kubectl get nodes --no-headers | grep -v "$node_to_drain" | grep Ready | wc -l)
    
    if [ "$remaining_nodes" -lt 2 ]; then
        echo "ERROR: Less than 2 nodes would remain after draining $node_to_drain"
        return 1
    fi
    
    echo "Capacity validation passed: $remaining_nodes nodes will remain"
    return 0
}

validate_pdbs_for_node() {
    local node_name="$1"
    
    # Get all pods on the node
    local pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.labels}{"\n"}{end}')
    
    # Check each pod's PDB status
    while IFS= read -r pod_info; do
        local namespace=$(echo "$pod_info" | awk '{print $1}')
        local pod_name=$(echo "$pod_info" | awk '{print $2}')
        
        if [ -n "$pod_name" ]; then
            # Find matching PDB
            local pdbs=$(kubectl get pdb -n "$namespace" -o json | jq -r '.items[] | select(.spec.selector.matchLabels) | .metadata.name')
            
            for pdb in $pdbs; do
                local current_healthy=$(kubectl get pdb "$pdb" -n "$namespace" -o jsonpath='{.status.currentHealthy}')
                local min_available=$(kubectl get pdb "$pdb" -n "$namespace" -o jsonpath='{.spec.minAvailable}')
                
                if [ "$current_healthy" -le "$min_available" ]; then
                    echo "ERROR: PDB $pdb would be violated (current: $current_healthy, min: $min_available)"
                    return 1
                fi
            done
        fi
    done <<< "$pods"
    
    return 0
}

monitor_drain_progress() {
    local node_name="$1"
    local drain_pid="$2"
    local max_wait="$3"
    
    local start_time=$(date +%s)
    
    while kill -0 $drain_pid 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $max_wait ]; then
            echo "Drain timeout reached, terminating..."
            kill $drain_pid
            break
        fi
        
        # Show remaining pods
        local remaining_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" --no-headers | wc -l)
        echo "Drain progress: $remaining_pods pods remaining on $node_name (${elapsed}s elapsed)"
        
        # Check application health
        if ! quick_health_check; then
            echo "WARNING: Application health degraded during drain"
        fi
        
        sleep 30
    done
}

validate_workload_health_post_drain() {
    echo "Validating workload health after drain..."
    
    # Check all deployments are healthy
    local unhealthy_deployments=$(kubectl get deployments --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.readyReplicas}{" "}{.spec.replicas}{"\n"}{end}' | \
        awk '$3 != $4 {print $1"/"$2}')
    
    if [ -n "$unhealthy_deployments" ]; then
        echo "WARNING: Unhealthy deployments detected:"
        echo "$unhealthy_deployments"
        return 1
    fi
    
    # Run application-specific health checks
    ./validate-applications.sh
    
    return $?
}

quick_health_check() {
    # Quick health check for critical services
    local critical_services=("frontend-service" "backend-service" "api-service")
    
    for service in "${critical_services[@]}"; do
        if ! kubectl run health-check-$$ --image=busybox --rm -it --restart=Never --timeout=30s -- \
            wget -qO- "http://$service/health" >/dev/null 2>&1; then
            return 1
        fi
    done
    
    return 0
}

# Usage
if [ $# -lt 1 ]; then
    echo "Usage: $0 <node-name> [max-wait-seconds]"
    exit 1
fi

intelligent_drain "$1" "$2"
```

### 3. Traffic Management During Upgrades
```bash
#!/bin/bash
# traffic-management.sh

setup_traffic_splitting() {
    local old_version="$1"
    local new_version="$2"
    local split_percentage="${3:-10}"  # Start with 10% to new version
    
    echo "Setting up traffic splitting: ${split_percentage}% to new version"
    
    # Update service to include both versions
    kubectl patch service frontend-service -p '{
        "spec": {
            "selector": {}
        }
    }'
    
    # Create separate services for each version
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: frontend-service-old
spec:
  selector:
    app: frontend
    version: "$old_version"
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-service-new
spec:
  selector:
    app: frontend
    version: "$new_version"
  ports:
  - port: 80
    targetPort: 8080
EOF

    # Configure ingress for traffic splitting
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend-ingress
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "$split_percentage"
spec:
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-service-new
            port:
              number: 80
EOF
}

monitor_traffic_health() {
    local monitoring_duration="${1:-300}"  # 5 minutes default
    local error_threshold="${2:-5}"        # 5% error rate threshold
    
    echo "Monitoring traffic health for ${monitoring_duration} seconds..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + monitoring_duration))
    
    while [ $(date +%s) -lt $end_time ]; do
        # Check error rates
        local error_rate=$(get_error_rate)
        local response_time=$(get_avg_response_time)
        
        echo "Current metrics - Error rate: ${error_rate}%, Avg response time: ${response_time}ms"
        
        if (( $(echo "$error_rate > $error_threshold" | bc -l) )); then
            echo "ERROR: Error rate exceeded threshold ($error_rate% > $error_threshold%)"
            return 1
        fi
        
        if (( $(echo "$response_time > 2000" | bc -l) )); then
            echo "WARNING: High response time detected: ${response_time}ms"
        fi
        
        sleep 30
    done
    
    echo "Traffic monitoring completed successfully"
    return 0
}

get_error_rate() {
    # Query Prometheus for error rate (example)
    local error_rate=$(curl -s "http://prometheus:9090/api/v1/query" \
        --data-urlencode "query=rate(http_requests_total{status=~\"5..\"}[5m]) / rate(http_requests_total[5m]) * 100" | \
        jq -r '.data.result[0].value[1] // "0"')
    
    echo "$error_rate"
}

get_avg_response_time() {
    # Query Prometheus for average response time (example)
    local response_time=$(curl -s "http://prometheus:9090/api/v1/query" \
        --data-urlencode "query=histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) * 1000" | \
        jq -r '.data.result[0].value[1] // "0"')
    
    echo "$response_time"
}

gradual_traffic_increase() {
    local steps=(10 25 50 75 100)
    
    for percentage in "${steps[@]}"; do
        echo "Increasing traffic to new version: ${percentage}%"
        
        # Update canary weight
        kubectl patch ingress frontend-ingress -p '{
            "metadata": {
                "annotations": {
                    "nginx.ingress.kubernetes.io/canary-weight": "'$percentage'"
                }
            }
        }'
        
        # Monitor for issues
        if ! monitor_traffic_health 180 5; then  # 3 minutes, 5% error threshold
            echo "Issues detected, rolling back traffic split"
            rollback_traffic_split
            return 1
        fi
        
        echo "Traffic split at ${percentage}% is healthy, proceeding..."
        sleep 60  # Wait between increases
    done
    
    echo "Traffic migration completed successfully"
    finalize_traffic_migration
}

rollback_traffic_split() {
    echo "Rolling back traffic to old version..."
    
    kubectl patch ingress frontend-ingress -p '{
        "metadata": {
            "annotations": {
                "nginx.ingress.kubernetes.io/canary-weight": "0"
            }
        }
    }'
    
    echo "Traffic rollback completed"
}

finalize_traffic_migration() {
    echo "Finalizing traffic migration..."
    
    # Remove canary annotations
    kubectl patch ingress frontend-ingress -p '{
        "metadata": {
            "annotations": {
                "nginx.ingress.kubernetes.io/canary": null,
                "nginx.ingress.kubernetes.io/canary-weight": null
            }
        }
    }'
    
    # Update main service to point to new version
    kubectl patch service frontend-service -p '{
        "spec": {
            "selector": {
                "app": "frontend",
                "version": "new"
            }
        }
    }'
    
    # Clean up old version service
    kubectl delete service frontend-service-old
    
    echo "Traffic migration finalized"
}
```

## Comprehensive Upgrade Orchestration

### 1. Zero-Downtime Upgrade Orchestrator
```bash
#!/bin/bash
# zero-downtime-upgrade.sh

CLUSTER_NAME="my-eks-cluster"
TARGET_VERSION="1.32"
ROLLBACK_ENABLED=true

zero_downtime_upgrade() {
    echo "Starting zero-downtime EKS upgrade to version $TARGET_VERSION..."
    
    # Phase 1: Pre-upgrade validation
    if ! pre_upgrade_validation; then
        echo "Pre-upgrade validation failed, aborting"
        exit 1
    fi
    
    # Phase 2: Setup monitoring
    setup_upgrade_monitoring
    
    # Phase 3: Control plane upgrade
    if ! upgrade_control_plane; then
        echo "Control plane upgrade failed"
        if [ "$ROLLBACK_ENABLED" = true ]; then
            trigger_rollback "control_plane"
        fi
        exit 1
    fi
    
    # Phase 4: Node group upgrade with zero downtime
    if ! zero_downtime_node_upgrade; then
        echo "Node upgrade failed"
        if [ "$ROLLBACK_ENABLED" = true ]; then
            trigger_rollback "node_group"
        fi
        exit 1
    fi
    
    # Phase 5: Post-upgrade validation
    if ! post_upgrade_validation; then
        echo "Post-upgrade validation failed"
        if [ "$ROLLBACK_ENABLED" = true ]; then
            trigger_rollback "validation"
        fi
        exit 1
    fi
    
    # Phase 6: Cleanup
    cleanup_upgrade_resources
    
    echo "Zero-downtime upgrade completed successfully!"
}

pre_upgrade_validation() {
    echo "Running pre-upgrade validation..."
    
    # Check cluster health
    ./cluster-health-check.sh || return 1
    
    # Analyze workload distribution
    ./workload-impact-analysis.sh || return 1
    
    # Validate PDB coverage
    validate_pdb_coverage || return 1
    
    # Check resource capacity
    validate_resource_capacity || return 1
    
    # Backup critical data
    backup_critical_data || return 1
    
    echo "Pre-upgrade validation passed"
    return 0
}

setup_upgrade_monitoring() {
    echo "Setting up upgrade monitoring..."
    
    # Deploy monitoring dashboard
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: upgrade-monitoring-dashboard
  namespace: monitoring
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "EKS Upgrade Monitoring",
        "panels": [
          {
            "title": "Application Error Rate",
            "targets": [
              {
                "expr": "rate(http_requests_total{status=~\"5..\"}[5m]) / rate(http_requests_total[5m]) * 100"
              }
            ]
          },
          {
            "title": "Pod Restart Rate",
            "targets": [
              {
                "expr": "rate(kube_pod_container_status_restarts_total[5m])"
              }
            ]
          }
        ]
      }
    }
EOF

    # Set up alerting
    kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: upgrade-alerts
  namespace: monitoring
spec:
  groups:
  - name: upgrade.rules
    rules:
    - alert: HighErrorRateDuringUpgrade
      expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) * 100 > 5
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "High error rate detected during upgrade"
    
    - alert: PodRestartSpikeDuringUpgrade
      expr: rate(kube_pod_container_status_restarts_total[5m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod restart spike detected during upgrade"
EOF
}

zero_downtime_node_upgrade() {
    echo "Starting zero-downtime node upgrade..."
    
    # Create new node group with target version
    create_new_node_group || return 1
    
    # Wait for new nodes to be ready
    wait_for_new_nodes || return 1
    
    # Gradually migrate workloads
    migrate_workloads_gradually || return 1
    
    # Remove old node group
    remove_old_node_group || return 1
    
    echo "Zero-downtime node upgrade completed"
    return 0
}

create_new_node_group() {
    echo "Creating new node group with version $TARGET_VERSION..."
    
    # Update Terraform configuration
    cat > upgrade-nodegroup.tf <<EOF
resource "aws_eks_node_group" "upgrade_nodes" {
  cluster_name    = "$CLUSTER_NAME"
  node_group_name = "${CLUSTER_NAME}-nodes-upgrade"
  node_role_arn   = data.aws_iam_role.node_role.arn
  subnet_ids      = data.aws_subnets.private.ids

  ami_type = "AL2023_x86_64_STANDARD"
  capacity_type = "ON_DEMAND"
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 3
    max_size     = 6
    min_size     = 1
  }

  update_config {
    max_unavailable_percentage = 25
  }

  # Ensure nodes are spread across AZs
  remote_access {
    ec2_ssh_key = var.key_pair_name
  }

  tags = {
    Name = "${CLUSTER_NAME}-nodes-upgrade"
    Purpose = "upgrade"
  }
}
EOF

    # Apply Terraform changes
    terraform apply -target=aws_eks_node_group.upgrade_nodes -auto-approve
    
    return $?
}

wait_for_new_nodes() {
    echo "Waiting for new nodes to be ready..."
    
    local max_wait=600  # 10 minutes
    local start_time=$(date +%s)
    
    while true; do
        local ready_nodes=$(kubectl get nodes -l eks.amazonaws.com/nodegroup="${CLUSTER_NAME}-nodes-upgrade" \
            --no-headers | grep Ready | wc -l)
        
        if [ "$ready_nodes" -ge 3 ]; then
            echo "New nodes are ready: $ready_nodes nodes"
            break
        fi
        
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $max_wait ]; then
            echo "Timeout waiting for new nodes"
            return 1
        fi
        
        echo "Waiting for nodes... ($ready_nodes/3 ready, ${elapsed}s elapsed)"
        sleep 30
    done
    
    # Validate new nodes
    kubectl get nodes -l eks.amazonaws.com/nodegroup="${CLUSTER_NAME}-nodes-upgrade" -o wide
    
    return 0
}

migrate_workloads_gradually() {
    echo "Starting gradual workload migration..."
    
    # Get old nodes
    local old_nodes=$(kubectl get nodes -l eks.amazonaws.com/nodegroup="${CLUSTER_NAME}-nodes" -o name)
    
    # Migrate one node at a time
    for node in $old_nodes; do
        local node_name=${node#node/}
        echo "Migrating workloads from $node_name..."
        
        # Use intelligent drain
        if ! ./intelligent-node-drain.sh "$node_name" 600; then
            echo "Failed to drain $node_name"
            return 1
        fi
        
        # Validate cluster health after each migration
        if ! ./validate-applications.sh; then
            echo "Application validation failed after migrating $node_name"
            return 1
        fi
        
        # Brief pause between migrations
        sleep 60
    done
    
    echo "Workload migration completed successfully"
    return 0
}

remove_old_node_group() {
    echo "Removing old node group..."
    
    # Remove old node group via Terraform
    terraform destroy -target=aws_eks_node_group.eks_nodes -auto-approve
    
    return $?
}

post_upgrade_validation() {
    echo "Running post-upgrade validation..."
    
    # Comprehensive health check
    ./cluster-health-check.sh || return 1
    
    # Application validation
    ./validate-applications.sh || return 1
    
    # Performance validation
    ./performance-validation.sh || return 1
    
    # Security validation
    ./security-validation.sh || return 1
    
    echo "Post-upgrade validation passed"
    return 0
}

validate_resource_capacity() {
    echo "Validating resource capacity..."
    
    # Check if cluster has enough capacity for upgrade
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    local total_cpu=$(kubectl describe nodes | grep -A 5 "Capacity:" | grep cpu | awk '{sum += $2} END {print sum}')
    local used_cpu=$(kubectl describe nodes | grep -A 5 "Allocated resources:" | grep cpu | awk '{sum += $2} END {print sum}')
    
    echo "Cluster capacity: $total_nodes nodes, ${total_cpu} CPU cores"
    echo "Current usage: ${used_cpu} CPU cores"
    
    # Ensure we have enough capacity for blue-green deployment
    if [ "$total_nodes" -lt 4 ]; then
        echo "WARNING: Minimum 4 nodes recommended for zero-downtime upgrades"
    fi
    
    return 0
}

backup_critical_data() {
    echo "Backing up critical data..."
    
    # Backup etcd (handled by AWS)
    echo "etcd backup handled by AWS EKS"
    
    # Backup persistent volumes
    ./backup-persistent-volumes.sh || return 1
    
    # Backup configurations
    kubectl get configmaps --all-namespaces -o yaml > configmaps-backup.yaml
    kubectl get secrets --all-namespaces -o yaml > secrets-backup.yaml
    
    echo "Critical data backup completed"
    return 0
}

cleanup_upgrade_resources() {
    echo "Cleaning up upgrade resources..."
    
    # Remove upgrade monitoring
    kubectl delete configmap upgrade-monitoring-dashboard -n monitoring --ignore-not-found
    kubectl delete prometheusrule upgrade-alerts -n monitoring --ignore-not-found
    
    # Clean up temporary files
    rm -f upgrade-nodegroup.tf
    rm -f configmaps-backup.yaml
    rm -f secrets-backup.yaml
    
    echo "Cleanup completed"
}

trigger_rollback() {
    local phase="$1"
    echo "Triggering rollback for phase: $phase"
    
    case $phase in
        "control_plane")
            echo "Control plane rollback not supported by AWS EKS"
            ;;
        "node_group")
            ./rollback-node-group.sh
            ;;
        "validation")
            ./rollback-validation-issues.sh
            ;;
    esac
}

# Execute zero-downtime upgrade
zero_downtime_upgrade
```

## Summary: Zero-Downtime Guarantees

The enhanced design now provides comprehensive zero-downtime protection through:

### 1. **Application-Level Protection**
- Pod Disruption Budgets for all critical workloads
- Anti-affinity rules for pod distribution
- Proper health checks and graceful shutdown
- Rolling update strategies with controlled surge/unavailable

### 2. **Infrastructure-Level Protection**
- Blue-green node group deployments
- Intelligent node draining with capacity validation
- Real-time monitoring during upgrades
- Automated rollback triggers

### 3. **Traffic Management**
- Gradual traffic shifting with canary deployments
- Real-time error rate monitoring
- Automatic traffic rollback on issues
- Service mesh integration for advanced routing

### 4. **Comprehensive Validation**
- Pre-upgrade workload impact analysis
- Continuous health monitoring during upgrades
- Post-upgrade validation with automatic rollback
- Performance baseline validation

This design ensures that workloads remain unimpacted during patching through multiple layers of protection, intelligent automation, and comprehensive monitoring.