# EKS Blue-Green Upgrade Testing Guide

## Overview

This comprehensive sample application is designed to test zero-downtime EKS upgrades using the Blue-Green node group strategy. The application includes multiple tiers, monitoring, and load testing capabilities.

## Application Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Frontend      │    │   Backend API   │    │   PostgreSQL    │
│   (nginx)       │───▶│   (Node.js)     │───▶│   Database      │
│   4 replicas    │    │   3 replicas    │    │   1 replica     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │   Monitoring    │
                    │   (busybox)     │
                    │   1 replica     │
                    └─────────────────┘
```

## Features for Upgrade Testing

### 1. **High Availability Configuration**
- **Pod Disruption Budgets**: Ensures minimum pods remain during upgrades
- **Anti-affinity rules**: Spreads pods across nodes
- **Multiple replicas**: Frontend (4), Backend (3), Database (1)
- **Health checks**: Liveness and readiness probes

### 2. **Real-time Monitoring**
- **Continuous health monitoring**: Every 5 seconds
- **Response time tracking**: Measures API performance
- **Success rate calculation**: Tracks availability percentage
- **Downtime detection**: Identifies and measures outages

### 3. **Load Testing**
- **Concurrent requests**: Simulates real user traffic
- **Multiple endpoints**: Tests all application tiers
- **Stress testing**: High-concurrency scenarios
- **Performance metrics**: Response times and error rates

### 4. **Upgrade Simulation**
- **Node cordoning**: Simulates node replacement
- **Pod migration**: Forces workload rescheduling
- **Impact measurement**: Tracks application behavior
- **Recovery validation**: Ensures full restoration

## Quick Start

### 1. Deploy the Application
```bash
# Configure kubectl for your EKS cluster
aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster

# Deploy the sample application
cd sample-app
bash deploy.sh
```

### 2. Start Load Testing
```bash
# Start continuous load testing
bash start-load-test.sh
```

### 3. Test Blue-Green Upgrade
```bash
# Simulate Blue-Green upgrade while monitoring impact
bash test-upgrade.sh
```

### 4. Clean Up
```bash
# Remove all resources
bash cleanup.sh
```

## Detailed Testing Procedure

### Phase 1: Pre-Upgrade Validation
1. **Deploy Application**: Ensure all components are healthy
2. **Verify PDBs**: Confirm Pod Disruption Budgets are active
3. **Check Distribution**: Validate pods are spread across nodes
4. **Baseline Performance**: Establish normal response times

### Phase 2: Load Testing
1. **Start Monitoring**: Begin continuous health checks
2. **Generate Traffic**: Create realistic load patterns
3. **Measure Baseline**: Record normal performance metrics
4. **Validate Stability**: Ensure consistent behavior

### Phase 3: Upgrade Simulation
1. **Begin Monitoring**: Start detailed upgrade tracking
2. **Simulate Node Replacement**: Cordon and drain nodes
3. **Monitor Impact**: Track downtime and performance
4. **Validate Recovery**: Ensure full service restoration

### Phase 4: Results Analysis
1. **Review Logs**: Analyze monitoring output
2. **Calculate Downtime**: Measure any service interruptions
3. **Performance Impact**: Compare before/after metrics
4. **PDB Effectiveness**: Verify disruption budget compliance

## Expected Results

### ✅ **Successful Zero-Downtime Upgrade**
- **No service interruptions**: 100% availability maintained
- **Minimal performance impact**: <10% response time increase
- **PDB compliance**: Minimum pods always available
- **Quick recovery**: <30 seconds for full stabilization

### ⚠️ **Potential Issues to Watch**
- **Brief response spikes**: During pod migration
- **Temporary capacity reduction**: While nodes are cordoned
- **Database connection blips**: During backend pod restarts
- **Load balancer updates**: DNS propagation delays

## Monitoring Metrics

### 1. **Availability Metrics**
- **Success Rate**: Percentage of successful requests
- **Consecutive Failures**: Maximum failure streak
- **Total Downtime**: Cumulative unavailable seconds
- **Recovery Time**: Time to restore full service

### 2. **Performance Metrics**
- **Response Time**: Average API response latency
- **Throughput**: Requests per second handled
- **Error Rate**: Percentage of failed requests
- **Resource Usage**: CPU and memory consumption

### 3. **Infrastructure Metrics**
- **Pod Distribution**: Workload spread across nodes
- **Node Status**: Available vs cordoned nodes
- **PDB Status**: Current vs desired healthy pods
- **Storage**: Persistent volume availability

## Troubleshooting

### Common Issues

#### 1. **LoadBalancer Not Ready**
```bash
# Check service status
kubectl get service frontend-service -n sample-app

# Use port-forward as fallback
kubectl port-forward service/frontend-service 8080:80 -n sample-app
```

#### 2. **Pods Not Starting**
```bash
# Check pod status
kubectl get pods -n sample-app -o wide

# View pod logs
kubectl logs deployment/frontend -n sample-app
kubectl logs deployment/backend -n sample-app
```

#### 3. **Database Connection Issues**
```bash
# Check database pod
kubectl get pods -l app=postgres -n sample-app

# Check database logs
kubectl logs deployment/postgres -n sample-app

# Verify secret
kubectl get secret postgres-secret -n sample-app -o yaml
```

#### 4. **PDB Violations**
```bash
# Check PDB status
kubectl get pdb -n sample-app

# Describe PDB for details
kubectl describe pdb frontend-pdb -n sample-app
```

## Advanced Testing Scenarios

### 1. **Stress Testing**
```bash
# High-concurrency load test
kubectl exec -it deployment/monitoring -n sample-app -- /scripts/load-test.sh
```

### 2. **Failure Injection**
```bash
# Test error handling
curl http://your-frontend-url/api/error
```

### 3. **Resource Pressure**
```bash
# Simulate resource constraints
kubectl exec -it deployment/backend -n sample-app -- /app/stress-test.sh
```

### 4. **Network Partitioning**
```bash
# Test network resilience
kubectl exec -it deployment/frontend -n sample-app -- iptables -A OUTPUT -d backend-service -j DROP
```

## Integration with Real Upgrades

This sample application can be used during actual EKS upgrades:

### 1. **Before Real Upgrade**
- Deploy the application
- Start monitoring
- Establish performance baseline

### 2. **During Real Upgrade**
- Keep monitoring running
- Execute actual Blue-Green node group upgrade
- Track real impact on application

### 3. **After Real Upgrade**
- Analyze monitoring results
- Compare with simulation results
- Document lessons learned

## Customization

### Modify Load Patterns
Edit `start-load-test.sh` to adjust:
- Request frequency
- Concurrent users
- Test duration
- Endpoint mix

### Adjust Application Configuration
Modify deployment files to change:
- Replica counts
- Resource requests/limits
- Health check parameters
- PDB settings

### Enhance Monitoring
Extend monitoring scripts to track:
- Custom metrics
- Business KPIs
- External dependencies
- User experience metrics

## Best Practices

### 1. **Pre-Upgrade**
- Always test in staging first
- Validate PDB configuration
- Ensure adequate cluster capacity
- Backup critical data

### 2. **During Upgrade**
- Monitor continuously
- Have rollback plan ready
- Communicate with stakeholders
- Document any issues

### 3. **Post-Upgrade**
- Validate full functionality
- Compare performance metrics
- Update documentation
- Plan next upgrade cycle

## Conclusion

This sample application provides a comprehensive testing framework for validating zero-downtime EKS upgrades. By simulating real-world conditions and measuring actual impact, you can confidently implement Blue-Green upgrade strategies in production environments.

The combination of proper application architecture, comprehensive monitoring, and realistic testing scenarios ensures that your EKS upgrades will maintain service availability and meet your SLA requirements.