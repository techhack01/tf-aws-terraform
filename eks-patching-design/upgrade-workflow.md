# EKS Upgrade Workflow

## Workflow Overview

This document provides detailed step-by-step procedures for upgrading EKS clusters, including pre-upgrade preparation, execution, and post-upgrade validation.

## Pre-Upgrade Checklist

### 1. Planning Phase (T-7 days)
- [ ] **Review Kubernetes Release Notes**: Check for breaking changes and deprecated APIs
- [ ] **Assess Application Compatibility**: Validate workload compatibility with target version
- [ ] **Schedule Maintenance Window**: Coordinate with stakeholders for downtime
- [ ] **Prepare Communication Plan**: Notify users and dependent teams
- [ ] **Update Documentation**: Ensure runbooks and procedures are current

### 2. Environment Preparation (T-3 days)
- [ ] **Backup Critical Data**: 
  - etcd snapshots (managed by AWS)
  - Persistent volume snapshots
  - Application configuration backups
- [ ] **Update Management Tools**:
  - kubectl client version
  - Helm version compatibility
  - Terraform provider versions
- [ ] **Validate Staging Environment**: Ensure staging mirrors production

### 3. Pre-Upgrade Validation (T-1 day)
- [ ] **Cluster Health Check**:
  ```bash
  # Check cluster status
  kubectl cluster-info
  kubectl get nodes
  kubectl get pods --all-namespaces | grep -v Running
  
  # Check resource usage
  kubectl top nodes
  kubectl top pods --all-namespaces
  ```
- [ ] **Application Health Verification**:
  ```bash
  # Check critical applications
  kubectl get deployments --all-namespaces
  kubectl get services --all-namespaces
  kubectl get ingress --all-namespaces
  ```
- [ ] **Network Connectivity Tests**:
  ```bash
  # Test DNS resolution
  kubectl run test-pod --image=busybox --rm -it -- nslookup kubernetes.default
  
  # Test external connectivity
  kubectl run test-pod --image=busybox --rm -it -- wget -qO- http://example.com
  ```

## Upgrade Execution Workflow

### Phase 1: Control Plane Upgrade

#### Step 1: Update Terraform Configuration
```hcl
# Update variables.tf or terraform.tfvars
variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.32"  # Updated from 1.31
}
```

#### Step 2: Plan and Apply Control Plane Upgrade
```bash
# In Terraform Cloud or CLI
terraform plan -var="kubernetes_version=1.32"
terraform apply -var="kubernetes_version=1.32"
```

#### Step 3: Validate Control Plane
```bash
# Wait for upgrade completion (typically 10-15 minutes)
aws eks describe-cluster --name my-eks-cluster --query 'cluster.status'

# Verify API server functionality
kubectl version --short
kubectl get componentstatuses
```

### Phase 2: Add-on Updates

#### Step 1: Update Core Add-ons
```bash
# Update VPC CNI
aws eks describe-addon --cluster-name my-eks-cluster --addon-name vpc-cni
aws eks update-addon --cluster-name my-eks-cluster --addon-name vpc-cni

# Update CoreDNS
aws eks update-addon --cluster-name my-eks-cluster --addon-name coredns

# Update kube-proxy
aws eks update-addon --cluster-name my-eks-cluster --addon-name kube-proxy
```

#### Step 2: Validate Add-on Health
```bash
# Check add-on status
aws eks describe-addon --cluster-name my-eks-cluster --addon-name vpc-cni
kubectl get pods -n kube-system -l k8s-app=aws-node
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

### Phase 3: Node Group Upgrade

#### Step 1: Create New Node Group (Blue-Green Strategy)
```hcl
# Add to Terraform configuration
resource "aws_eks_node_group" "eks_nodes_new" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-nodes-new"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  # Updated AMI for new Kubernetes version (AL2023)
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = data.aws_eks_addon_version.latest.version
  
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  scaling_config {
    desired_size = var.desired_capacity
    max_size     = var.max_capacity
    min_size     = var.min_capacity
  }

  # Faster replacement during upgrades
  update_config {
    max_unavailable_percentage = 50
  }

  tags = {
    Name = "${var.cluster_name}-nodes-new"
    UpgradeGroup = "blue-green"
  }
}
```

#### Step 2: Validate New Nodes
```bash
# Wait for new nodes to be ready
kubectl get nodes -l eks.amazonaws.com/nodegroup=my-eks-cluster-nodes-new

# Check node version
kubectl get nodes -o wide

# Verify node labels and taints
kubectl describe nodes -l eks.amazonaws.com/nodegroup=my-eks-cluster-nodes-new
```

#### Step 3: Migrate Workloads
```bash
# Cordon old nodes (prevent new pods)
kubectl get nodes -l eks.amazonaws.com/nodegroup=my-eks-cluster-nodes -o name | \
  xargs -I {} kubectl cordon {}

# Drain old nodes gradually
OLD_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup=my-eks-cluster-nodes -o name)
for node in $OLD_NODES; do
  echo "Draining $node"
  kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
  
  # Wait and validate workload migration
  sleep 60
  kubectl get pods --all-namespaces --field-selector=spec.nodeName=${node#node/}
  
  # Check application health before proceeding
  ./validate-applications.sh
done
```

#### Step 4: Remove Old Node Group
```bash
# After successful migration, remove old node group
terraform apply -var="remove_old_node_group=true"
```

## Validation Scripts

### Application Health Validation
```bash
#!/bin/bash
# validate-applications.sh

validate_critical_apps() {
    local apps=("frontend" "backend" "database")
    
    for app in "${apps[@]}"; do
        echo "Validating $app..."
        
        # Check deployment status
        local ready_replicas=$(kubectl get deployment $app -o jsonpath='{.status.readyReplicas}')
        local desired_replicas=$(kubectl get deployment $app -o jsonpath='{.spec.replicas}')
        
        if [ "$ready_replicas" != "$desired_replicas" ]; then
            echo "ERROR: $app not fully ready ($ready_replicas/$desired_replicas)"
            return 1
        fi
        
        # Health check endpoint
        local service_ip=$(kubectl get service $app -o jsonpath='{.spec.clusterIP}')
        kubectl run health-check --image=busybox --rm -it --restart=Never -- \
          wget -qO- http://$service_ip/health || return 1
    done
    
    echo "All critical applications are healthy"
    return 0
}

validate_ingress_connectivity() {
    local ingresses=$(kubectl get ingress -o jsonpath='{.items[*].metadata.name}')
    
    for ingress in $ingresses; do
        local host=$(kubectl get ingress $ingress -o jsonpath='{.spec.rules[0].host}')
        echo "Testing ingress: $host"
        
        curl -f -s -o /dev/null "https://$host/health" || {
            echo "ERROR: Ingress $ingress not responding"
            return 1
        }
    done
    
    echo "All ingress endpoints are responding"
    return 0
}

main() {
    validate_critical_apps && validate_ingress_connectivity
}

main "$@"
```

### Performance Validation
```bash
#!/bin/bash
# performance-validation.sh

run_load_test() {
    echo "Running load test..."
    
    # Deploy load testing pod
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: load-test
spec:
  containers:
  - name: load-test
    image: busybox
    command: ['sh', '-c']
    args:
    - |
      for i in \$(seq 1 100); do
        wget -qO- http://frontend-service/api/health
        sleep 0.1
      done
  restartPolicy: Never
EOF

    # Wait for completion
    kubectl wait --for=condition=complete pod/load-test --timeout=300s
    
    # Check results
    kubectl logs load-test
    kubectl delete pod load-test
}

monitor_resource_usage() {
    echo "Monitoring resource usage..."
    
    # Check node resource usage
    kubectl top nodes
    
    # Check pod resource usage
    kubectl top pods --all-namespaces --sort-by=cpu
    
    # Check for resource pressure
    kubectl describe nodes | grep -A 5 "Conditions:"
}

main() {
    run_load_test
    monitor_resource_usage
}

main "$@"
```

## Post-Upgrade Tasks

### 1. Immediate Validation (T+0)
- [ ] **Cluster Status Verification**:
  ```bash
  kubectl cluster-info
  kubectl get nodes
  kubectl get pods --all-namespaces
  ```
- [ ] **Application Health Checks**:
  ```bash
  ./validate-applications.sh
  ./performance-validation.sh
  ```
- [ ] **Monitoring Dashboard Review**: Check metrics and alerts

### 2. Extended Monitoring (T+24h)
- [ ] **Performance Baseline**: Establish new performance metrics
- [ ] **Error Rate Analysis**: Monitor application error rates
- [ ] **Resource Utilization**: Track CPU, memory, and network usage
- [ ] **User Feedback**: Collect feedback from application users

### 3. Documentation and Cleanup (T+7d)
- [ ] **Update Documentation**: Record upgrade process and issues
- [ ] **Clean Up Resources**: Remove temporary resources and old backups
- [ ] **Lessons Learned**: Document improvements for next upgrade
- [ ] **Security Scan**: Run vulnerability scans on updated components

## Rollback Procedures

### Immediate Rollback (During Upgrade)
```bash
# If upgrade fails during node group migration
# 1. Stop draining old nodes
kubectl uncordon <old-node-name>

# 2. Scale up old node group
aws eks update-nodegroup-config \
  --cluster-name my-eks-cluster \
  --nodegroup-name my-eks-cluster-nodes \
  --scaling-config desiredSize=3

# 3. Remove new node group
terraform destroy -target=aws_eks_node_group.eks_nodes_new
```

### Post-Upgrade Rollback (If Issues Discovered)
```bash
# 1. Create rollback plan
terraform plan -var="kubernetes_version=1.31"

# 2. Execute rollback (Note: Control plane rollback not supported)
# Focus on node group rollback and application fixes

# 3. Validate rollback
./cluster-health-check.sh
./validate-applications.sh
```

## Emergency Procedures

### Critical Application Failure
1. **Immediate Response**:
   - Scale up old node group if available
   - Redirect traffic to backup systems
   - Activate incident response team

2. **Investigation**:
   - Collect logs and metrics
   - Identify root cause
   - Determine fix vs. rollback

3. **Resolution**:
   - Apply hotfix if possible
   - Execute rollback if necessary
   - Communicate status to stakeholders

### Cluster Unavailability
1. **Assessment**:
   - Check AWS service health
   - Verify network connectivity
   - Review recent changes

2. **Recovery**:
   - Contact AWS support if needed
   - Activate disaster recovery procedures
   - Restore from backups if necessary

## Success Criteria

### Technical Success
- [ ] All nodes running target Kubernetes version
- [ ] All add-ons updated and healthy
- [ ] All applications passing health checks
- [ ] No increase in error rates
- [ ] Performance within acceptable ranges

### Business Success
- [ ] Minimal or no user-facing downtime
- [ ] No data loss or corruption
- [ ] All SLA requirements met
- [ ] Stakeholder communication completed
- [ ] Documentation updated

## Continuous Improvement

### Metrics Collection
- Upgrade duration and success rate
- Application downtime measurements
- Resource utilization changes
- User satisfaction scores

### Process Refinement
- Regular review of upgrade procedures
- Automation enhancement opportunities
- Tool and script improvements
- Training and knowledge sharing