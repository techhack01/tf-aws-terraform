# EKS Patching Automation Design

## Architecture Overview

This document describes the automation architecture for EKS cluster patching, including tools, workflows, and integration points.

## Automation Stack

### 1. Infrastructure as Code
- **Terraform**: Cluster and node group management
- **Terraform Cloud**: Centralized state management and execution
- **Git Workflows**: Version control and change tracking
- **Policy as Code**: Sentinel policies for governance

### 2. CI/CD Pipeline
- **GitHub Actions / GitLab CI**: Orchestration platform
- **AWS CodePipeline**: Native AWS integration option
- **Approval Gates**: Manual validation points for production
- **Automated Testing**: Validation and rollback triggers

### 3. Monitoring and Observability
- **CloudWatch**: AWS native monitoring and logging
- **Prometheus/Grafana**: Kubernetes-native monitoring
- **AWS X-Ray**: Distributed tracing during upgrades
- **Custom Dashboards**: Real-time upgrade status

## Automation Components

### 1. Upgrade Orchestrator
```yaml
# Example GitHub Actions Workflow
name: EKS Cluster Upgrade
on:
  schedule:
    - cron: '0 2 * * 1'  # Weekly on Monday 2 AM
  workflow_dispatch:
    inputs:
      target_version:
        description: 'Target Kubernetes version'
        required: true
      environment:
        description: 'Environment to upgrade'
        required: true
        type: choice
        options: ['dev', 'staging', 'prod']

jobs:
  pre-upgrade-checks:
    runs-on: ubuntu-latest
    steps:
      - name: Validate cluster health
      - name: Check breaking changes
      - name: Backup critical data
      
  upgrade-control-plane:
    needs: pre-upgrade-checks
    steps:
      - name: Update Terraform configuration
      - name: Apply control plane upgrade
      - name: Validate API server
      
  upgrade-node-groups:
    needs: upgrade-control-plane
    strategy:
      matrix:
        node_group: [system, application, spot]
    steps:
      - name: Create new node group
      - name: Drain old nodes
      - name: Validate workloads
      - name: Remove old node group
```

### 2. Health Check Framework
```bash
#!/bin/bash
# cluster-health-check.sh

check_api_server() {
    kubectl cluster-info --request-timeout=30s
    return $?
}

check_node_status() {
    local ready_nodes=$(kubectl get nodes --no-headers | grep Ready | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [ "$ready_nodes" -eq "$total_nodes" ]; then
        echo "All nodes are ready ($ready_nodes/$total_nodes)"
        return 0
    else
        echo "Some nodes are not ready ($ready_nodes/$total_nodes)"
        return 1
    fi
}

check_critical_pods() {
    local namespaces=("kube-system" "aws-load-balancer-controller")
    
    for ns in "${namespaces[@]}"; do
        local failed_pods=$(kubectl get pods -n "$ns" --field-selector=status.phase!=Running --no-headers | wc -l)
        if [ "$failed_pods" -gt 0 ]; then
            echo "Failed pods in namespace $ns: $failed_pods"
            return 1
        fi
    done
    
    return 0
}

main() {
    echo "Starting cluster health check..."
    
    check_api_server && \
    check_node_status && \
    check_critical_pods
    
    if [ $? -eq 0 ]; then
        echo "Cluster health check passed"
        exit 0
    else
        echo "Cluster health check failed"
        exit 1
    fi
}

main "$@"
```

### 3. Terraform Automation Module
```hcl
# modules/eks-upgrade/main.tf
resource "aws_eks_cluster" "cluster" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Upgrade configuration
  upgrade_policy {
    support_type = "STANDARD"
  }

  lifecycle {
    ignore_changes = [
      # Prevent accidental downgrades
      version
    ]
  }
}

# Blue-green node group strategy
resource "aws_eks_node_group" "new_nodes" {
  count = var.upgrade_in_progress ? 1 : 0
  
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "${var.cluster_name}-nodes-new"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"  # AL2023 AMI type
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

  # Ensure new AMI version for AL2023
  release_version = data.aws_eks_addon_version.latest.version

  lifecycle {
    create_before_destroy = true
  }
}

# Gradual migration using taints and tolerations
resource "kubernetes_manifest" "migration_taint" {
  count = var.upgrade_in_progress ? 1 : 0
  
  manifest = {
    apiVersion = "v1"
    kind       = "Node"
    metadata = {
      name = each.value
    }
    spec = {
      taints = [
        {
          key    = "node.kubernetes.io/upgrade"
          value  = "true"
          effect = "NoSchedule"
        }
      ]
    }
  }
  
  for_each = var.old_node_names
}
```

### 4. Rollback Automation
```python
#!/usr/bin/env python3
# rollback-manager.py

import boto3
import subprocess
import json
import sys
from datetime import datetime

class EKSRollbackManager:
    def __init__(self, cluster_name, region):
        self.cluster_name = cluster_name
        self.region = region
        self.eks_client = boto3.client('eks', region_name=region)
        
    def get_cluster_info(self):
        """Get current cluster information"""
        response = self.eks_client.describe_cluster(name=self.cluster_name)
        return response['cluster']
    
    def check_upgrade_status(self):
        """Check if upgrade is in progress or failed"""
        cluster = self.get_cluster_info()
        return cluster['status'], cluster.get('version')
    
    def initiate_rollback(self):
        """Initiate rollback procedure"""
        print(f"Starting rollback for cluster {self.cluster_name}")
        
        # 1. Scale up old node group
        self.scale_node_group(f"{self.cluster_name}-nodes-old", desired=2)
        
        # 2. Drain new node group
        self.drain_node_group(f"{self.cluster_name}-nodes-new")
        
        # 3. Update Terraform state
        self.revert_terraform_state()
        
        # 4. Validate rollback
        if self.validate_rollback():
            print("Rollback completed successfully")
            return True
        else:
            print("Rollback validation failed")
            return False
    
    def scale_node_group(self, node_group_name, desired):
        """Scale node group to desired capacity"""
        try:
            self.eks_client.update_nodegroup_config(
                clusterName=self.cluster_name,
                nodegroupName=node_group_name,
                scalingConfig={'desiredSize': desired}
            )
            print(f"Scaled {node_group_name} to {desired} nodes")
        except Exception as e:
            print(f"Failed to scale node group: {e}")
            
    def drain_node_group(self, node_group_name):
        """Drain nodes in the specified node group"""
        # Get nodes in the node group
        cmd = f"kubectl get nodes -l eks.amazonaws.com/nodegroup={node_group_name} -o name"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            nodes = result.stdout.strip().split('\n')
            for node in nodes:
                if node:
                    drain_cmd = f"kubectl drain {node.split('/')[-1]} --ignore-daemonsets --delete-emptydir-data --force"
                    subprocess.run(drain_cmd, shell=True)
                    print(f"Drained node: {node}")
    
    def revert_terraform_state(self):
        """Revert Terraform configuration to previous version"""
        # This would integrate with your Terraform Cloud API
        # or local Terraform state management
        pass
    
    def validate_rollback(self):
        """Validate that rollback was successful"""
        # Run health checks
        cmd = "./cluster-health-check.sh"
        result = subprocess.run(cmd, shell=True)
        return result.returncode == 0

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 rollback-manager.py <cluster_name> <region>")
        sys.exit(1)
    
    cluster_name = sys.argv[1]
    region = sys.argv[2]
    
    rollback_manager = EKSRollbackManager(cluster_name, region)
    
    status, version = rollback_manager.check_upgrade_status()
    print(f"Cluster status: {status}, Version: {version}")
    
    if status in ['FAILED', 'DEGRADED']:
        success = rollback_manager.initiate_rollback()
        sys.exit(0 if success else 1)
    else:
        print("No rollback needed - cluster is healthy")
        sys.exit(0)
```

## Integration Points

### 1. Terraform Cloud Integration
- **Workspace Variables**: Dynamic version management
- **Run Triggers**: Automated execution based on schedules
- **Policy Checks**: Governance and compliance validation
- **State Management**: Centralized infrastructure state

### 2. AWS Services Integration
- **EventBridge**: Trigger upgrades based on AWS events
- **Systems Manager**: Parameter store for configuration
- **CloudFormation**: Alternative IaC option
- **Lambda**: Serverless automation functions

### 3. Kubernetes Integration
- **Helm**: Application deployment and upgrades
- **Operators**: Custom resource management
- **Admission Controllers**: Policy enforcement
- **Custom Resources**: Upgrade coordination

## Security Considerations

### 1. Access Control
- **IAM Roles**: Least privilege for automation
- **RBAC**: Kubernetes role-based access
- **Service Accounts**: Workload identity management
- **Secrets Management**: Secure credential handling

### 2. Audit and Compliance
- **CloudTrail**: API call logging
- **Audit Logs**: Kubernetes audit trail
- **Change Tracking**: Git-based change history
- **Compliance Reports**: Automated compliance validation

## Monitoring and Alerting

### 1. Upgrade Metrics
- **Success Rate**: Track upgrade completion
- **Duration**: Monitor upgrade timing
- **Rollback Rate**: Track rollback frequency
- **Error Patterns**: Identify common issues

### 2. Alert Configuration
```yaml
# Example Prometheus alerting rules
groups:
- name: eks-upgrade-alerts
  rules:
  - alert: EKSUpgradeInProgress
    expr: eks_upgrade_status == 1
    for: 0m
    labels:
      severity: info
    annotations:
      summary: "EKS upgrade in progress for cluster {{ $labels.cluster_name }}"
      
  - alert: EKSUpgradeFailed
    expr: eks_upgrade_status == -1
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "EKS upgrade failed for cluster {{ $labels.cluster_name }}"
      description: "Upgrade has been failing for more than 5 minutes"
      
  - alert: EKSNodeGroupUnhealthy
    expr: eks_node_group_ready_nodes / eks_node_group_total_nodes < 0.8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "EKS node group has unhealthy nodes"
```

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)
- Set up Terraform modules
- Create basic health check scripts
- Implement CI/CD pipeline structure

### Phase 2: Automation (Weeks 3-4)
- Build upgrade orchestrator
- Implement rollback mechanisms
- Add monitoring and alerting

### Phase 3: Testing (Weeks 5-6)
- Test in development environment
- Validate rollback procedures
- Performance and reliability testing

### Phase 4: Production (Weeks 7-8)
- Deploy to staging environment
- Production rollout with monitoring
- Documentation and training