# EKS Patching Methodology

## Overview

This document explains the exact methodology used for EKS node patching, comparing different approaches and detailing the recommended Blue-Green strategy.

## Patching Approaches Comparison

### 1. Traditional One-by-One Patching (NOT RECOMMENDED)
```
Initial State: [Node1] [Node2] [Node3] [Node4]
Step 1:        [Node1*] [Node2] [Node3] [Node4]  # Patch Node1, drain workloads
Step 2:        [Node1] [Node2*] [Node3] [Node4]  # Patch Node2, drain workloads
Step 3:        [Node1] [Node2] [Node3*] [Node4]  # Patch Node3, drain workloads
Step 4:        [Node1] [Node2] [Node3] [Node4*]  # Patch Node4, drain workloads

Issues:
- Long upgrade window (hours)
- Multiple disruptions to workloads
- Risk of capacity issues during each drain
- Complex rollback scenarios
```

### 2. Rolling Node Group Updates (AWS DEFAULT)
```
Initial State: NodeGroup1 [Node1] [Node2] [Node3]
Step 1:        NodeGroup1 [Node1] [Node2] [Node3] + [NewNode1]  # Add new node
Step 2:        NodeGroup1 [Node2] [Node3] + [NewNode1]          # Remove Node1
Step 3:        NodeGroup1 [Node2] [Node3] + [NewNode1] + [NewNode2]  # Add new node
Step 4:        NodeGroup1 [Node3] + [NewNode1] + [NewNode2]     # Remove Node2
...continue until all nodes replaced

Issues:
- Still causes multiple workload disruptions
- Gradual capacity changes
- Extended upgrade window
- Complex state management
```

### 3. Blue-Green Node Group Strategy (RECOMMENDED)
```
Initial State: 
  Blue NodeGroup:  [Node1] [Node2] [Node3] [Node4]  # Current production
  Green NodeGroup: []                               # Empty

Step 1 - Create Green:
  Blue NodeGroup:  [Node1] [Node2] [Node3] [Node4]  # Still serving traffic
  Green NodeGroup: [NewNode1] [NewNode2] [NewNode3] [NewNode4]  # New patched nodes

Step 2 - Migrate Workloads:
  Blue NodeGroup:  [Node1] [Node2] [Node3] [Node4]  # Gradually drained
  Green NodeGroup: [NewNode1] [NewNode2] [NewNode3] [NewNode4]  # Receiving workloads

Step 3 - Complete Migration:
  Blue NodeGroup:  []                               # Removed
  Green NodeGroup: [NewNode1] [NewNode2] [NewNode3] [NewNode4]  # Full production

Benefits:
- Single migration event
- Full capacity maintained throughout
- Fast rollback capability
- Minimal workload disruption
```

## Detailed Blue-Green Implementation

### Phase 1: Green Node Group Creation
```bash
# Create new node group with updated AMI
resource "aws_eks_node_group" "green_nodes" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.cluster_name}-nodes-green"
  
  # Updated AMI with latest patches
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = var.target_ami_version
  
  # Same capacity as blue group
  scaling_config {
    desired_size = var.blue_desired_capacity
    max_size     = var.blue_max_capacity
    min_size     = var.blue_min_capacity
  }
  
  # Faster replacement during migration
  update_config {
    max_unavailable_percentage = 0  # No disruption during creation
  }
}

# Timeline: 5-10 minutes for node group creation
```

### Phase 2: Workload Migration Strategy
```bash
#!/bin/bash
# blue-green-migration.sh

migrate_workloads_blue_to_green() {
    echo "Starting Blue-Green workload migration..."
    
    # Get all blue nodes
    local blue_nodes=$(kubectl get nodes -l eks.amazonaws.com/nodegroup="${CLUSTER_NAME}-nodes-blue" -o name)
    local total_blue_nodes=$(echo "$blue_nodes" | wc -l)
    local current_node=1
    
    echo "Found $total_blue_nodes blue nodes to migrate"
    
    # Migration approaches - choose one:
    
    # APPROACH 1: Parallel Migration (Fastest - 10-15 minutes)
    parallel_migration "$blue_nodes"
    
    # APPROACH 2: Sequential Migration (Safest - 20-30 minutes)
    # sequential_migration "$blue_nodes"
    
    # APPROACH 3: Batch Migration (Balanced - 15-20 minutes)
    # batch_migration "$blue_nodes" 2  # Migrate 2 nodes at a time
}

parallel_migration() {
    local blue_nodes="$1"
    
    echo "Using parallel migration strategy..."
    
    # Cordon all blue nodes simultaneously
    echo "Cordoning all blue nodes..."
    for node in $blue_nodes; do
        kubectl cordon ${node#node/} &
    done
    wait
    
    # Start draining all nodes in parallel with careful monitoring
    echo "Starting parallel drain of all blue nodes..."
    local drain_pids=()
    
    for node in $blue_nodes; do
        local node_name=${node#node/}
        echo "Starting drain of $node_name..."
        
        # Drain with longer grace period for parallel operation
        kubectl drain "$node_name" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --force \
            --grace-period=120 \
            --timeout=1800s &  # 30 minute timeout
        
        drain_pids+=($!)
        
        # Brief stagger to avoid overwhelming the API server
        sleep 10
    done
    
    # Monitor all drain operations
    monitor_parallel_drains "${drain_pids[@]}"
    
    # Wait for all drains to complete
    local failed_drains=0
    for pid in "${drain_pids[@]}"; do
        if ! wait $pid; then
            ((failed_drains++))
        fi
    done
    
    if [ $failed_drains -gt 0 ]; then
        echo "ERROR: $failed_drains drain operations failed"
        return 1
    fi
    
    echo "Parallel migration completed successfully"
}

sequential_migration() {
    local blue_nodes="$1"
    
    echo "Using sequential migration strategy..."
    
    for node in $blue_nodes; do
        local node_name=${node#node/}
        echo "Migrating node $current_node/$total_blue_nodes: $node_name"
        
        # Use intelligent drain for each node
        if ! ./intelligent-node-drain.sh "$node_name" 600; then
            echo "Failed to migrate $node_name"
            return 1
        fi
        
        # Validate cluster health after each node
        if ! quick_health_check; then
            echo "Health check failed after migrating $node_name"
            return 1
        fi
        
        echo "Successfully migrated $node_name"
        ((current_node++))
        
        # Brief pause between nodes
        sleep 30
    done
    
    echo "Sequential migration completed successfully"
}

batch_migration() {
    local blue_nodes="$1"
    local batch_size="$2"
    
    echo "Using batch migration strategy (batch size: $batch_size)..."
    
    # Convert to array
    local nodes_array=($blue_nodes)
    local total_nodes=${#nodes_array[@]}
    
    # Process in batches
    for ((i=0; i<total_nodes; i+=batch_size)); do
        local batch_end=$((i + batch_size - 1))
        if [ $batch_end -ge $total_nodes ]; then
            batch_end=$((total_nodes - 1))
        fi
        
        echo "Processing batch: nodes $((i+1)) to $((batch_end+1))"
        
        # Drain batch in parallel
        local batch_pids=()
        for ((j=i; j<=batch_end; j++)); do
            local node_name=${nodes_array[j]#node/}
            echo "Starting drain of $node_name (batch)"
            
            kubectl drain "$node_name" \
                --ignore-daemonsets \
                --delete-emptydir-data \
                --force \
                --grace-period=90 \
                --timeout=900s &
            
            batch_pids+=($!)
            sleep 5  # Brief stagger
        done
        
        # Wait for batch to complete
        local batch_failures=0
        for pid in "${batch_pids[@]}"; do
            if ! wait $pid; then
                ((batch_failures++))
            fi
        done
        
        if [ $batch_failures -gt 0 ]; then
            echo "ERROR: $batch_failures nodes failed in batch"
            return 1
        fi
        
        # Validate health after each batch
        if ! comprehensive_health_check; then
            echo "Health check failed after batch"
            return 1
        fi
        
        echo "Batch completed successfully"
        sleep 60  # Pause between batches
    done
    
    echo "Batch migration completed successfully"
}

monitor_parallel_drains() {
    local pids=("$@")
    local total_pids=${#pids[@]}
    
    echo "Monitoring $total_pids parallel drain operations..."
    
    while true; do
        local active_drains=0
        local completed_drains=0
        
        # Check status of all drain operations
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active_drains++))
            else
                ((completed_drains++))
            fi
        done
        
        echo "Drain status: $completed_drains completed, $active_drains active"
        
        # Check cluster health during parallel operations
        if ! quick_health_check; then
            echo "WARNING: Health check failed during parallel drain"
        fi
        
        # Show remaining pods on blue nodes
        local remaining_pods=$(kubectl get pods --all-namespaces \
            --field-selector spec.nodeName!="" \
            -o wide | grep -E "nodes-blue" | wc -l)
        echo "Remaining pods on blue nodes: $remaining_pods"
        
        if [ $active_drains -eq 0 ]; then
            echo "All drain operations completed"
            break
        fi
        
        sleep 30
    done
}

quick_health_check() {
    # Fast health check during migration
    local unhealthy_deployments=$(kubectl get deployments --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.readyReplicas}{" "}{.spec.replicas}{"\n"}{end}' | \
        awk '$3 != $4 && $4 > 0 {count++} END {print count+0}')
    
    if [ "$unhealthy_deployments" -gt 0 ]; then
        echo "WARNING: $unhealthy_deployments unhealthy deployments detected"
        return 1
    fi
    
    return 0
}

comprehensive_health_check() {
    # More thorough health check between batches
    ./cluster-health-check.sh && ./validate-applications.sh
}
```

### Phase 3: Blue Node Group Cleanup
```bash
cleanup_blue_nodes() {
    echo "Cleaning up blue node group..."
    
    # Final validation before cleanup
    if ! ./validate-applications.sh; then
        echo "ERROR: Applications not healthy, keeping blue nodes for rollback"
        return 1
    fi
    
    # Remove blue node group
    terraform destroy -target=aws_eks_node_group.blue_nodes -auto-approve
    
    # Rename green to blue for next upgrade cycle
    terraform apply -var="rename_green_to_blue=true" -auto-approve
    
    echo "Blue node group cleanup completed"
}
```

## Migration Timeline Comparison

### Parallel Migration (Recommended for Production)
```
Time 0:    Create Green nodes (5-10 min)
Time 10:   Start parallel drain of all Blue nodes
Time 15:   Most workloads migrated to Green nodes
Time 20:   All Blue nodes drained
Time 25:   Validation and cleanup
Total:     25-30 minutes
```

### Sequential Migration (Safest for Critical Systems)
```
Time 0:    Create Green nodes (5-10 min)
Time 10:   Drain Blue Node 1 (5 min)
Time 15:   Drain Blue Node 2 (5 min)
Time 20:   Drain Blue Node 3 (5 min)
Time 25:   Drain Blue Node 4 (5 min)
Time 30:   Validation and cleanup
Total:     35-40 minutes
```

### Batch Migration (Balanced Approach)
```
Time 0:    Create Green nodes (5-10 min)
Time 10:   Drain Batch 1 (Nodes 1-2) (8 min)
Time 18:   Drain Batch 2 (Nodes 3-4) (8 min)
Time 26:   Validation and cleanup
Total:     30-35 minutes
```

## Workload Impact Analysis

### During Blue-Green Migration:
```
Workload Disruption Events:
- Pod evictions: 1 time per pod (during drain)
- Service interruption: 0 seconds (if PDBs configured correctly)
- DNS resolution: Unaffected
- Load balancer: Automatic target updates
- Persistent volumes: Seamless reattachment

Capacity During Migration:
- Initial: 100% (Blue nodes)
- Peak: 200% (Blue + Green nodes)
- Final: 100% (Green nodes)
```

### Resource Utilization Pattern:
```
CPU/Memory Usage:
Time 0-10:   Normal usage on Blue nodes
Time 10-15:  Spike as workloads migrate to Green
Time 15-20:  Stabilization on Green nodes
Time 20+:    Normal usage on Green nodes

Network Traffic:
- Pod-to-pod: Brief spike during migration
- External traffic: Unaffected
- Internal DNS: Temporary increase in queries
```

## Rollback Scenarios

### Fast Rollback (During Migration)
```bash
# If issues detected during migration
emergency_rollback() {
    echo "EMERGENCY: Rolling back Blue-Green migration"
    
    # Stop all drain operations
    pkill -f "kubectl drain"
    
    # Uncordon all blue nodes
    kubectl get nodes -l eks.amazonaws.com/nodegroup="${CLUSTER_NAME}-nodes-blue" -o name | \
        xargs -I {} kubectl uncordon {}
    
    # Scale up blue node group if needed
    aws eks update-nodegroup-config \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "${CLUSTER_NAME}-nodes-blue" \
        --scaling-config desiredSize=4
    
    # Remove green node group
    terraform destroy -target=aws_eks_node_group.green_nodes -auto-approve
    
    echo "Emergency rollback completed"
}
```

## Configuration Examples

### Terraform Configuration for Blue-Green
```hcl
# Blue node group (current production)
resource "aws_eks_node_group" "blue_nodes" {
  count = var.blue_green_migration ? 1 : 0
  
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "${var.cluster_name}-nodes-blue"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = var.private_subnet_ids

  ami_type = "AL2023_x86_64_STANDARD"
  release_version = var.current_ami_version
  
  scaling_config {
    desired_size = var.node_desired_capacity
    max_size     = var.node_max_capacity
    min_size     = var.node_min_capacity
  }

  tags = {
    Name = "${var.cluster_name}-nodes-blue"
    Environment = "production"
    MigrationPhase = "blue"
  }
}

# Green node group (new patched nodes)
resource "aws_eks_node_group" "green_nodes" {
  count = var.blue_green_migration ? 1 : 0
  
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "${var.cluster_name}-nodes-green"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = var.private_subnet_ids

  ami_type = "AL2023_x86_64_STANDARD"
  release_version = var.target_ami_version  # Updated AMI
  
  scaling_config {
    desired_size = var.node_desired_capacity
    max_size     = var.node_max_capacity
    min_size     = var.node_min_capacity
  }

  tags = {
    Name = "${var.cluster_name}-nodes-green"
    Environment = "production"
    MigrationPhase = "green"
  }
  
  # Ensure green nodes are created before blue nodes are drained
  lifecycle {
    create_before_destroy = true
  }
}
```

## Summary

**The design does NOT patch nodes one at a time.** Instead, it uses a **Blue-Green node group strategy** where:

1. **New patched nodes are created in parallel** (Green group)
2. **Workloads are migrated** using one of three strategies:
   - **Parallel**: All nodes drained simultaneously (fastest)
   - **Sequential**: One node at a time (safest)
   - **Batch**: Groups of nodes (balanced)
3. **Old nodes are removed** after successful migration

This approach provides:
- **Faster upgrades** (25-40 minutes vs hours)
- **Better capacity management** (200% capacity during migration)
- **Simpler rollback** (just switch back to blue)
- **Fewer workload disruptions** (single migration event)
- **Higher reliability** (full redundancy throughout)