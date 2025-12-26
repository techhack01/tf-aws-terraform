# EKS Rollback Strategy

## Overview

This document outlines comprehensive rollback strategies for EKS cluster upgrades, including automated rollback triggers, manual procedures, and disaster recovery scenarios.

## Rollback Scenarios

### 1. Control Plane Rollback Limitations
**Important**: AWS EKS does not support rolling back the control plane to a previous Kubernetes version. Once upgraded, the control plane cannot be downgraded.

**Mitigation Strategies**:
- Thorough testing in staging environments
- Gradual rollout across environments
- Application-level compatibility testing
- Blue-green cluster strategy for critical workloads

### 2. Node Group Rollback
Node groups can be rolled back by:
- Creating new node groups with previous AMI versions
- Migrating workloads back to previous node configuration
- Removing upgraded node groups

### 3. Application Rollback
Applications can be rolled back independently:
- Container image rollback
- Helm chart version rollback
- Configuration rollback
- Database schema rollback (if applicable)

## Automated Rollback Triggers

### 1. Health Check Failures
```yaml
# Rollback trigger configuration
rollback_triggers:
  health_checks:
    - name: "api_server_availability"
      threshold: 95%
      duration: 5m
      action: "rollback_node_group"
    
    - name: "application_error_rate"
      threshold: 5%
      duration: 10m
      action: "rollback_applications"
    
    - name: "node_ready_percentage"
      threshold: 80%
      duration: 15m
      action: "rollback_node_group"
```

### 2. Performance Degradation
```bash
#!/bin/bash
# performance-monitor.sh

check_response_time() {
    local endpoint="$1"
    local threshold="$2"
    
    local response_time=$(curl -w "%{time_total}" -s -o /dev/null "$endpoint")
    local threshold_seconds=$(echo "$threshold / 1000" | bc -l)
    
    if (( $(echo "$response_time > $threshold_seconds" | bc -l) )); then
        echo "Response time exceeded threshold: ${response_time}s > ${threshold_seconds}s"
        return 1
    fi
    
    return 0
}

check_error_rate() {
    local service="$1"
    local threshold="$2"
    
    # Query Prometheus for error rate
    local error_rate=$(curl -s "http://prometheus:9090/api/v1/query" \
        --data-urlencode "query=rate(http_requests_total{job=\"$service\",status=~\"5..\"}[5m])" | \
        jq -r '.data.result[0].value[1]')
    
    if (( $(echo "$error_rate > $threshold" | bc -l) )); then
        echo "Error rate exceeded threshold: $error_rate > $threshold"
        return 1
    fi
    
    return 0
}

main() {
    local services=("frontend" "backend" "api")
    
    for service in "${services[@]}"; do
        if ! check_response_time "http://$service/health" 2000; then
            echo "ALERT: Performance degradation detected for $service"
            ./trigger-rollback.sh "$service"
        fi
        
        if ! check_error_rate "$service" 0.05; then
            echo "ALERT: High error rate detected for $service"
            ./trigger-rollback.sh "$service"
        fi
    done
}

main "$@"
```

## Manual Rollback Procedures

### 1. Node Group Rollback

#### Step 1: Assess Current State
```bash
# Check current node groups
aws eks describe-nodegroup --cluster-name my-eks-cluster --nodegroup-name my-eks-cluster-nodes

# Check node versions
kubectl get nodes -o wide

# Check workload distribution
kubectl get pods -o wide --all-namespaces
```

#### Step 2: Create Rollback Node Group
```hcl
# Terraform configuration for rollback node group
resource "aws_eks_node_group" "rollback_nodes" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-nodes-rollback"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  # Use previous AMI version (AL2023)
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = var.previous_ami_version  # e.g., "1.31.2-20241211"
  
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  scaling_config {
    desired_size = var.desired_capacity
    max_size     = var.max_capacity
    min_size     = var.min_capacity
  }

  update_config {
    max_unavailable_percentage = 25
  }

  tags = {
    Name = "${var.cluster_name}-nodes-rollback"
    Purpose = "rollback"
  }
}
```

#### Step 3: Execute Rollback Migration
```bash
#!/bin/bash
# rollback-node-migration.sh

CLUSTER_NAME="my-eks-cluster"
OLD_NODE_GROUP="my-eks-cluster-nodes-new"
ROLLBACK_NODE_GROUP="my-eks-cluster-nodes-rollback"

# Wait for rollback nodes to be ready
echo "Waiting for rollback nodes to be ready..."
kubectl wait --for=condition=Ready nodes -l eks.amazonaws.com/nodegroup=$ROLLBACK_NODE_GROUP --timeout=600s

# Cordon upgraded nodes
echo "Cordoning upgraded nodes..."
kubectl get nodes -l eks.amazonaws.com/nodegroup=$OLD_NODE_GROUP -o name | \
  xargs -I {} kubectl cordon {}

# Drain upgraded nodes with careful monitoring
echo "Starting rollback migration..."
OLD_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=$OLD_NODE_GROUP -o name)

for node in $OLD_NODES; do
    echo "Processing $node..."
    
    # Check cluster capacity before draining
    AVAILABLE_NODES=$(kubectl get nodes --no-headers | grep -c Ready)
    if [ "$AVAILABLE_NODES" -lt 2 ]; then
        echo "ERROR: Insufficient capacity for safe rollback"
        exit 1
    fi
    
    # Drain node
    kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
    
    # Validate applications after each node
    if ! ./validate-applications.sh; then
        echo "ERROR: Application validation failed during rollback"
        # Attempt to uncordon the node
        kubectl uncordon $node
        exit 1
    fi
    
    echo "Successfully migrated workloads from $node"
    sleep 30  # Brief pause between nodes
done

echo "Rollback migration completed successfully"
```

### 2. Application Rollback

#### Helm-based Application Rollback
```bash
#!/bin/bash
# helm-rollback.sh

rollback_helm_release() {
    local release="$1"
    local namespace="$2"
    local revision="$3"
    
    echo "Rolling back $release to revision $revision..."
    
    # Get current revision for reference
    local current_revision=$(helm list -n "$namespace" -o json | jq -r ".[] | select(.name==\"$release\") | .revision")
    echo "Current revision: $current_revision"
    
    # Perform rollback
    helm rollback "$release" "$revision" -n "$namespace"
    
    # Wait for rollback to complete
    kubectl rollout status deployment/"$release" -n "$namespace" --timeout=300s
    
    # Validate rollback
    if validate_application "$release" "$namespace"; then
        echo "Rollback successful for $release"
        return 0
    else
        echo "Rollback validation failed for $release"
        return 1
    fi
}

validate_application() {
    local app="$1"
    local namespace="$2"
    
    # Check deployment status
    local ready_replicas=$(kubectl get deployment "$app" -n "$namespace" -o jsonpath='{.status.readyReplicas}')
    local desired_replicas=$(kubectl get deployment "$app" -n "$namespace" -o jsonpath='{.spec.replicas}')
    
    if [ "$ready_replicas" != "$desired_replicas" ]; then
        echo "Deployment not ready: $ready_replicas/$desired_replicas"
        return 1
    fi
    
    # Health check
    local service_name="${app}-service"
    kubectl run health-check-$$ --image=busybox --rm -it --restart=Never -n "$namespace" -- \
        wget -qO- "http://$service_name/health" || return 1
    
    return 0
}

# Rollback critical applications
rollback_helm_release "frontend" "default" "previous"
rollback_helm_release "backend" "default" "previous"
rollback_helm_release "database" "default" "previous"
```

#### Container Image Rollback
```bash
#!/bin/bash
# image-rollback.sh

rollback_deployment_image() {
    local deployment="$1"
    local namespace="$2"
    local previous_image="$3"
    
    echo "Rolling back $deployment to image $previous_image..."
    
    # Update deployment image
    kubectl set image deployment/"$deployment" \
        "$deployment"="$previous_image" \
        -n "$namespace"
    
    # Wait for rollout
    kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout=300s
    
    # Validate rollback
    local current_image=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    
    if [ "$current_image" = "$previous_image" ]; then
        echo "Image rollback successful: $current_image"
        return 0
    else
        echo "Image rollback failed: expected $previous_image, got $current_image"
        return 1
    fi
}

# Example rollbacks
rollback_deployment_image "frontend" "default" "myapp/frontend:v1.2.3"
rollback_deployment_image "backend" "default" "myapp/backend:v1.2.3"
```

## Disaster Recovery Scenarios

### 1. Complete Cluster Failure

#### Blue-Green Cluster Strategy
```hcl
# disaster-recovery-cluster.tf
resource "aws_eks_cluster" "dr_cluster" {
  name     = "${var.cluster_name}-dr"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.stable_kubernetes_version  # Known stable version

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Ensure DR cluster is always ready
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.cluster_name}-dr"
    Purpose     = "disaster-recovery"
    Environment = var.environment
  }
}

# Pre-deployed node group for DR
resource "aws_eks_node_group" "dr_nodes" {
  cluster_name    = aws_eks_cluster.dr_cluster.name
  node_group_name = "${var.cluster_name}-dr-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  # Minimal capacity for cost optimization
  scaling_config {
    desired_size = 1
    max_size     = var.max_capacity
    min_size     = 1
  }

  tags = {
    Name = "${var.cluster_name}-dr-nodes"
  }
}
```

#### DR Activation Script
```bash
#!/bin/bash
# activate-disaster-recovery.sh

DR_CLUSTER_NAME="my-eks-cluster-dr"
PRODUCTION_CLUSTER_NAME="my-eks-cluster"

activate_dr_cluster() {
    echo "Activating disaster recovery cluster..."
    
    # Scale up DR cluster
    aws eks update-nodegroup-config \
        --cluster-name "$DR_CLUSTER_NAME" \
        --nodegroup-name "${DR_CLUSTER_NAME}-nodes" \
        --scaling-config desiredSize=3
    
    # Wait for nodes to be ready
    kubectl --context="$DR_CLUSTER_NAME" wait --for=condition=Ready nodes --all --timeout=600s
    
    # Deploy applications to DR cluster
    deploy_applications_to_dr
    
    # Update DNS/Load balancer to point to DR cluster
    update_traffic_routing
    
    echo "Disaster recovery activation completed"
}

deploy_applications_to_dr() {
    echo "Deploying applications to DR cluster..."
    
    # Switch kubectl context
    kubectl config use-context "$DR_CLUSTER_NAME"
    
    # Deploy from backup configurations
    helm install frontend ./charts/frontend --values ./values/production.yaml
    helm install backend ./charts/backend --values ./values/production.yaml
    
    # Restore data from backups
    restore_database_from_backup
    
    # Validate deployment
    ./validate-applications.sh
}

restore_database_from_backup() {
    echo "Restoring database from latest backup..."
    
    # Get latest backup
    local latest_backup=$(aws rds describe-db-snapshots \
        --db-instance-identifier myapp-db \
        --query 'DBSnapshots | sort_by(@, &SnapshotCreateTime) | [-1].DBSnapshotIdentifier' \
        --output text)
    
    # Restore database
    aws rds restore-db-instance-from-db-snapshot \
        --db-instance-identifier myapp-db-dr \
        --db-snapshot-identifier "$latest_backup"
    
    # Wait for database to be available
    aws rds wait db-instance-available --db-instance-identifier myapp-db-dr
}

update_traffic_routing() {
    echo "Updating traffic routing to DR cluster..."
    
    # Update Route 53 records or load balancer target groups
    # This depends on your specific setup
    
    # Example: Update ALB target group
    local dr_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
    
    for node_ip in $dr_nodes; do
        aws elbv2 register-targets \
            --target-group-arn "$TARGET_GROUP_ARN" \
            --targets Id="$node_ip"
    done
}

# Execute DR activation
if [ "$1" = "activate" ]; then
    activate_dr_cluster
else
    echo "Usage: $0 activate"
    exit 1
fi
```

### 2. Data Recovery Procedures

#### Persistent Volume Recovery
```bash
#!/bin/bash
# pv-recovery.sh

recover_persistent_volumes() {
    echo "Starting persistent volume recovery..."
    
    # List available EBS snapshots
    local snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:kubernetes.io/cluster/my-eks-cluster,Values=owned" \
        --query 'Snapshots | sort_by(@, &StartTime) | [-5:] | [].SnapshotId' \
        --output text)
    
    echo "Available snapshots: $snapshots"
    
    # Create volumes from snapshots
    for snapshot in $snapshots; do
        local volume_id=$(aws ec2 create-volume \
            --snapshot-id "$snapshot" \
            --availability-zone us-east-1a \
            --query 'VolumeId' \
            --output text)
        
        echo "Created volume $volume_id from snapshot $snapshot"
        
        # Create PV and PVC for recovered volume
        create_pv_from_volume "$volume_id" "$snapshot"
    done
}

create_pv_from_volume() {
    local volume_id="$1"
    local snapshot_id="$2"
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: recovered-pv-${snapshot_id##*-}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: ebs.csi.aws.com
    volumeHandle: $volume_id
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: recovered-pvc-${snapshot_id##*-}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  volumeName: recovered-pv-${snapshot_id##*-}
EOF
}

recover_persistent_volumes
```

## Rollback Validation

### 1. Automated Validation Suite
```bash
#!/bin/bash
# rollback-validation.sh

validate_rollback_success() {
    local validation_results=()
    
    echo "Starting rollback validation..."
    
    # Test 1: Cluster health
    if validate_cluster_health; then
        validation_results+=("PASS: Cluster health")
    else
        validation_results+=("FAIL: Cluster health")
    fi
    
    # Test 2: Application functionality
    if validate_application_functionality; then
        validation_results+=("PASS: Application functionality")
    else
        validation_results+=("FAIL: Application functionality")
    fi
    
    # Test 3: Performance baseline
    if validate_performance_baseline; then
        validation_results+=("PASS: Performance baseline")
    else
        validation_results+=("FAIL: Performance baseline")
    fi
    
    # Test 4: Data integrity
    if validate_data_integrity; then
        validation_results+=("PASS: Data integrity")
    else
        validation_results+=("FAIL: Data integrity")
    fi
    
    # Report results
    echo "Rollback validation results:"
    printf '%s\n' "${validation_results[@]}"
    
    # Check for any failures
    if printf '%s\n' "${validation_results[@]}" | grep -q "FAIL"; then
        echo "Rollback validation failed!"
        return 1
    else
        echo "Rollback validation successful!"
        return 0
    fi
}

validate_cluster_health() {
    # Check node status
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c Ready)
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [ "$ready_nodes" -ne "$total_nodes" ]; then
        echo "Not all nodes are ready: $ready_nodes/$total_nodes"
        return 1
    fi
    
    # Check system pods
    local failed_pods=$(kubectl get pods -n kube-system --field-selector=status.phase!=Running --no-headers | wc -l)
    if [ "$failed_pods" -gt 0 ]; then
        echo "Failed system pods: $failed_pods"
        return 1
    fi
    
    return 0
}

validate_application_functionality() {
    local apps=("frontend" "backend" "database")
    
    for app in "${apps[@]}"; do
        # Check deployment status
        local ready_replicas=$(kubectl get deployment "$app" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(kubectl get deployment "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        if [ "$ready_replicas" != "$desired_replicas" ]; then
            echo "$app deployment not ready: $ready_replicas/$desired_replicas"
            return 1
        fi
        
        # Health check
        if ! kubectl run health-check-$$ --image=busybox --rm -it --restart=Never -- \
            wget -qO- "http://$app-service/health" 2>/dev/null; then
            echo "$app health check failed"
            return 1
        fi
    done
    
    return 0
}

validate_performance_baseline() {
    # Simple performance test
    local response_time=$(kubectl run perf-test-$$ --image=busybox --rm -it --restart=Never -- \
        sh -c 'time wget -qO- http://frontend-service/' 2>&1 | grep real | awk '{print $2}')
    
    # Extract seconds (assuming format like "0m2.345s")
    local seconds=$(echo "$response_time" | sed 's/.*m\([0-9.]*\)s/\1/')
    
    # Check if response time is acceptable (< 5 seconds)
    if (( $(echo "$seconds > 5" | bc -l) )); then
        echo "Performance degraded: ${seconds}s response time"
        return 1
    fi
    
    return 0
}

validate_data_integrity() {
    # Check database connectivity and basic query
    kubectl run db-test-$$ --image=postgres:13 --rm -it --restart=Never -- \
        psql -h database-service -U myuser -d mydb -c "SELECT COUNT(*) FROM users;" 2>/dev/null || return 1
    
    return 0
}

# Run validation
validate_rollback_success
```

## Communication and Documentation

### 1. Rollback Communication Template
```markdown
# Rollback Notification

**Subject**: EKS Cluster Rollback Completed - [Cluster Name]

**Summary**: 
Due to [issue description], we have successfully rolled back the EKS cluster upgrade.

**Timeline**:
- Issue detected: [timestamp]
- Rollback initiated: [timestamp]
- Rollback completed: [timestamp]
- Services restored: [timestamp]

**Impact**:
- Affected services: [list]
- Downtime duration: [duration]
- Users affected: [number/percentage]

**Current Status**:
- Cluster version: [version]
- All services: Operational
- Performance: Within normal parameters

**Next Steps**:
- Root cause analysis scheduled
- Upgrade retry planned for [date]
- Monitoring enhanced for [specific areas]

**Contact**: [team contact information]
```

### 2. Post-Rollback Review Process
```markdown
# Post-Rollback Review Checklist

## Immediate Actions (Within 2 hours)
- [ ] Confirm all services are operational
- [ ] Validate data integrity
- [ ] Update monitoring dashboards
- [ ] Notify stakeholders of resolution

## Short-term Actions (Within 24 hours)
- [ ] Document rollback procedure used
- [ ] Collect logs and metrics from failed upgrade
- [ ] Identify root cause of upgrade failure
- [ ] Update rollback procedures based on lessons learned

## Long-term Actions (Within 1 week)
- [ ] Conduct post-mortem meeting
- [ ] Update upgrade testing procedures
- [ ] Enhance monitoring and alerting
- [ ] Plan next upgrade attempt with improvements
```

## Continuous Improvement

### 1. Rollback Metrics
- **Mean Time to Detect (MTTD)**: Time to identify upgrade issues
- **Mean Time to Rollback (MTTR)**: Time to complete rollback procedure
- **Rollback Success Rate**: Percentage of successful rollbacks
- **Data Loss Incidents**: Number of rollbacks resulting in data loss

### 2. Process Enhancement
- Regular rollback procedure testing
- Automation improvement based on manual steps
- Training updates for operations team
- Documentation refinement based on real incidents