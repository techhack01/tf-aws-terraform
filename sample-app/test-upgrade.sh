#!/bin/bash

set -e

echo "🔄 EKS Blue-Green Upgrade Test"
echo "This script simulates a Blue-Green node group upgrade while monitoring application impact"

# Check if application is deployed
if ! kubectl get namespace sample-app >/dev/null 2>&1; then
    echo "❌ Sample application not found. Please deploy first:"
    echo "   ./deploy.sh"
    exit 1
fi

# Configuration
CLUSTER_NAME="my-eks-cluster"
NEW_AMI_TYPE="AL2023_x86_64_STANDARD"  # Upgrade from AL2 to AL2023
MONITORING_INTERVAL=10
UPGRADE_TIMEOUT=1800  # 30 minutes

echo "📋 Upgrade Configuration:"
echo "   • Cluster: $CLUSTER_NAME"
echo "   • Target AMI: $NEW_AMI_TYPE"
echo "   • Monitoring interval: ${MONITORING_INTERVAL}s"
echo ""

# Pre-upgrade validation
echo "🔍 Pre-upgrade validation..."

# Check current cluster status
echo "📊 Current cluster status:"
kubectl get nodes -o wide
echo ""

# Check application health
echo "🏥 Application health check:"
kubectl get pods -n sample-app
echo ""

# Check PDB status
echo "🛡️  Pod Disruption Budget status:"
kubectl get pdb -n sample-app
echo ""

# Get current node group info
echo "📋 Current node groups:"
aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-nodes" --query 'nodegroup.{AmiType:amiType,InstanceTypes:instanceTypes,ScalingConfig:scalingConfig,Status:status}' --output table 2>/dev/null || echo "Unable to get node group info"
echo ""

# Start continuous monitoring
echo "📊 Starting continuous monitoring during upgrade..."

# Create monitoring script
cat > /tmp/upgrade-monitor.sh << 'EOF'
#!/bin/bash

FRONTEND_URL="$1"
LOG_FILE="/tmp/upgrade-monitoring.log"

echo "$(date): Upgrade monitoring started" > $LOG_FILE

total_checks=0
failed_checks=0
consecutive_failures=0
max_consecutive_failures=0
downtime_start=""
total_downtime=0

while true; do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    total_checks=$((total_checks + 1))
    
    # Test all endpoints
    frontend_ok=true
    backend_ok=true
    db_ok=true
    
    # Frontend health
    if ! curl -s -f --max-time 5 "$FRONTEND_URL/health" >/dev/null 2>&1; then
        frontend_ok=false
    fi
    
    # Backend health
    if ! curl -s -f --max-time 5 "$FRONTEND_URL/api/health" >/dev/null 2>&1; then
        backend_ok=false
    fi
    
    # Database health
    if ! curl -s -f --max-time 5 "$FRONTEND_URL/api/db-health" >/dev/null 2>&1; then
        db_ok=false
    fi
    
    # Overall status
    if $frontend_ok && $backend_ok && $db_ok; then
        status="✅ HEALTHY"
        if [ -n "$downtime_start" ]; then
            # End of downtime
            downtime_end=$(date +%s)
            downtime_duration=$((downtime_end - downtime_start))
            total_downtime=$((total_downtime + downtime_duration))
            echo "$timestamp | RECOVERY: Downtime ended (${downtime_duration}s)" | tee -a $LOG_FILE
            downtime_start=""
        fi
        consecutive_failures=0
    else
        status="❌ UNHEALTHY"
        failed_checks=$((failed_checks + 1))
        consecutive_failures=$((consecutive_failures + 1))
        
        if [ -z "$downtime_start" ]; then
            # Start of downtime
            downtime_start=$(date +%s)
            echo "$timestamp | DOWNTIME: Started" | tee -a $LOG_FILE
        fi
        
        if [ $consecutive_failures -gt $max_consecutive_failures ]; then
            max_consecutive_failures=$consecutive_failures
        fi
    fi
    
    # Detailed status
    frontend_status="❌"
    backend_status="❌"
    db_status="❌"
    
    $frontend_ok && frontend_status="✅"
    $backend_ok && backend_status="✅"
    $db_ok && db_status="✅"
    
    # Calculate success rate
    success_rate=100
    if [ $total_checks -gt 0 ]; then
        success_rate=$(( (total_checks - failed_checks) * 100 / total_checks ))
    fi
    
    # Log and display
    log_line="$timestamp | $status | Frontend: $frontend_status | Backend: $backend_status | DB: $db_status | Success: ${success_rate}% | Failures: $consecutive_failures"
    echo "$log_line" | tee -a $LOG_FILE
    
    # Summary every 30 checks (5 minutes at 10s intervals)
    if [ $((total_checks % 30)) -eq 0 ]; then
        echo "=== UPGRADE MONITORING SUMMARY ===" | tee -a $LOG_FILE
        echo "Total checks: $total_checks" | tee -a $LOG_FILE
        echo "Failed checks: $failed_checks" | tee -a $LOG_FILE
        echo "Success rate: ${success_rate}%" | tee -a $LOG_FILE
        echo "Max consecutive failures: $max_consecutive_failures" | tee -a $LOG_FILE
        echo "Total downtime: ${total_downtime}s" | tee -a $LOG_FILE
        echo "=================================" | tee -a $LOG_FILE
    fi
    
    sleep 10
done
EOF

chmod +x /tmp/upgrade-monitor.sh

# Get LoadBalancer URL or setup port-forward
FRONTEND_URL=$(kubectl get service frontend-service -n sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -z "$FRONTEND_URL" ]; then
    echo "🔗 Setting up port-forward for monitoring..."
    kubectl port-forward service/frontend-service 8080:80 -n sample-app >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 3
    FRONTEND_URL="localhost:8080"
    
    cleanup() {
        echo "🧹 Cleaning up..."
        kill $PORT_FORWARD_PID 2>/dev/null || true
        pkill -f upgrade-monitor.sh 2>/dev/null || true
    }
    trap cleanup EXIT
fi

# Start monitoring in background
echo "📊 Starting upgrade monitoring at: http://$FRONTEND_URL"
/tmp/upgrade-monitor.sh "http://$FRONTEND_URL" &
MONITOR_PID=$!

# Wait a moment for monitoring to start
sleep 5

echo ""
echo "🚀 SIMULATING BLUE-GREEN UPGRADE"
echo ""
echo "In a real scenario, you would now:"
echo "1. Create a new node group with updated AMI"
echo "2. Wait for new nodes to be ready"
echo "3. Gradually drain old nodes"
echo "4. Remove old node group"
echo ""
echo "For this simulation, we'll:"
echo "1. Simulate node pressure by cordoning nodes"
echo "2. Force pod rescheduling"
echo "3. Monitor application behavior"
echo ""

read -p "Press Enter to start the upgrade simulation..."

# Get current nodes
CURRENT_NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
NODE_COUNT=$(echo "$CURRENT_NODES" | wc -l)

echo "📋 Found $NODE_COUNT nodes to simulate upgrade on:"
echo "$CURRENT_NODES"
echo ""

# Simulate upgrade by cordoning and draining nodes one by one
node_num=1
for node in $CURRENT_NODES; do
    echo "🔄 Simulating upgrade of node $node_num/$NODE_COUNT: $node"
    
    # Cordon the node
    echo "   📝 Cordoning node $node..."
    kubectl cordon "$node"
    
    # Wait a moment
    sleep 5
    
    # Check pod distribution
    echo "   📊 Current pod distribution:"
    kubectl get pods -n sample-app -o wide | grep -E "(NAME|sample-app)"
    
    # Simulate partial drain (evict some pods)
    echo "   🔄 Simulating workload migration from $node..."
    
    # Get pods on this node
    PODS_ON_NODE=$(kubectl get pods -n sample-app --field-selector spec.nodeName="$node" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")
    
    if [ -n "$PODS_ON_NODE" ]; then
        for pod in $PODS_ON_NODE; do
            echo "      🔄 Migrating pod: $pod"
            kubectl delete pod "$pod" -n sample-app --grace-period=30 &
            sleep 2  # Stagger deletions
        done
        
        # Wait for pods to be rescheduled
        echo "   ⏳ Waiting for pods to be rescheduled..."
        sleep 30
        
        # Check if pods are back up
        kubectl wait --for=condition=ready pod -l app=frontend -n sample-app --timeout=120s || echo "   ⚠️ Some frontend pods may still be starting"
        kubectl wait --for=condition=ready pod -l app=backend -n sample-app --timeout=120s || echo "   ⚠️ Some backend pods may still be starting"
    else
        echo "      ℹ️ No application pods found on this node"
    fi
    
    # Uncordon the node (simulate new node ready)
    echo "   ✅ Uncordoning node $node (simulating new node ready)..."
    kubectl uncordon "$node"
    
    # Show current status
    echo "   📊 Application status after node $node_num upgrade:"
    kubectl get pods -n sample-app -o wide
    echo ""
    
    node_num=$((node_num + 1))
    
    # Pause between nodes
    if [ $node_num -le $NODE_COUNT ]; then
        echo "⏸️  Pausing 30 seconds before next node..."
        sleep 30
    fi
done

echo ""
echo "🎉 Upgrade simulation completed!"
echo ""

# Wait a bit more for final stabilization
echo "⏳ Waiting for final stabilization..."
sleep 60

# Stop monitoring
echo "🛑 Stopping monitoring..."
kill $MONITOR_PID 2>/dev/null || true

# Final status check
echo ""
echo "📊 Final Application Status:"
kubectl get pods -n sample-app -o wide
echo ""

echo "🏥 Final Health Check:"
kubectl get deployments -n sample-app
echo ""

echo "📋 Node Status:"
kubectl get nodes
echo ""

# Show monitoring results
if [ -f /tmp/upgrade-monitoring.log ]; then
    echo "📈 Upgrade Monitoring Summary:"
    echo "================================"
    tail -20 /tmp/upgrade-monitoring.log
    echo "================================"
    echo ""
    echo "📄 Full monitoring log available at: /tmp/upgrade-monitoring.log"
fi

echo ""
echo "✅ Blue-Green Upgrade Test Completed!"
echo ""
echo "🔍 Key Observations:"
echo "   • Check the monitoring log for any downtime periods"
echo "   • Verify all pods are running on available nodes"
echo "   • Confirm application remained accessible during simulation"
echo ""
echo "📊 To analyze results:"
echo "   • Review monitoring log: cat /tmp/upgrade-monitoring.log"
echo "   • Check pod events: kubectl get events -n sample-app"
echo "   • Verify PDB effectiveness: kubectl describe pdb -n sample-app"
echo ""
echo "🧹 To clean up:"
echo "   ./cleanup.sh"