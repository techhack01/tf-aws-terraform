#!/bin/bash

set -e

echo "🚀 Starting Load Test for EKS Blue-Green Upgrade Testing"

# Check if application is deployed
if ! kubectl get namespace sample-app >/dev/null 2>&1; then
    echo "❌ Sample application not found. Please deploy first:"
    echo "   ./deploy.sh"
    exit 1
fi

# Check if pods are ready
echo "📋 Checking application status..."
kubectl get pods -n sample-app

# Get LoadBalancer URL
FRONTEND_URL=$(kubectl get service frontend-service -n sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -z "$FRONTEND_URL" ]; then
    echo "⚠️  LoadBalancer not ready yet. Using port-forward instead..."
    echo "🔗 Starting port-forward to frontend service..."
    kubectl port-forward service/frontend-service 8080:80 -n sample-app &
    PORT_FORWARD_PID=$!
    sleep 5
    FRONTEND_URL="localhost:8080"
    
    # Cleanup function
    cleanup() {
        echo "🧹 Cleaning up port-forward..."
        kill $PORT_FORWARD_PID 2>/dev/null || true
    }
    trap cleanup EXIT
fi

echo "🎯 Target URL: http://$FRONTEND_URL"

# Test basic connectivity
echo "🔍 Testing basic connectivity..."
if curl -s -f --max-time 10 "http://$FRONTEND_URL/health" >/dev/null; then
    echo "✅ Frontend is accessible"
else
    echo "❌ Frontend is not accessible"
    exit 1
fi

# Start monitoring in background
echo "📊 Starting continuous monitoring..."
kubectl exec -it deployment/monitoring -n sample-app -- /scripts/monitor.sh &
MONITOR_PID=$!

# Function to stop monitoring
stop_monitoring() {
    echo "🛑 Stopping monitoring..."
    kubectl exec deployment/monitoring -n sample-app -- pkill -f monitor.sh 2>/dev/null || true
}

# Cleanup function
cleanup_all() {
    stop_monitoring
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi
}
trap cleanup_all EXIT

echo ""
echo "🔥 Starting Load Test..."
echo "   Duration: 5 minutes"
echo "   Concurrent users: 10"
echo "   Check interval: 1 second"
echo ""
echo "📊 Monitoring will show:"
echo "   • Response times"
echo "   • Success rates"
echo "   • Error counts"
echo "   • Node information"
echo ""
echo "Press Ctrl+C to stop the load test"
echo ""

# Load test parameters
DURATION=300  # 5 minutes
CONCURRENT=10
INTERVAL=1

start_time=$(date +%s)
end_time=$((start_time + DURATION))

total_requests=0
failed_requests=0
response_times=()

echo "$(date): Load test started"

while [ $(date +%s) -lt $end_time ]; do
    batch_start=$(date +%s)
    batch_requests=0
    batch_failures=0
    batch_times=()
    
    # Start concurrent requests
    pids=()
    
    for i in $(seq 1 $CONCURRENT); do
        (
            # Test different endpoints
            endpoints=(
                "http://$FRONTEND_URL/health"
                "http://$FRONTEND_URL/api/health"
                "http://$FRONTEND_URL/api/db-health"
                "http://$FRONTEND_URL/api/node-info"
                "http://$FRONTEND_URL/api/metrics"
            )
            
            endpoint=${endpoints[$((RANDOM % ${#endpoints[@]}))]}
            request_start=$(date +%s%3N)  # milliseconds
            
            if curl -s -f --max-time 5 "$endpoint" >/dev/null 2>&1; then
                request_end=$(date +%s%3N)
                response_time=$((request_end - request_start))
                echo "SUCCESS:$response_time"
            else
                echo "FAILURE:0"
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all requests and collect results
    for pid in "${pids[@]}"; do
        if result=$(wait $pid 2>/dev/null && echo "$(jobs -p | grep $pid)" | head -1); then
            result_line=$(echo "$result" | tail -1)
            if [[ $result_line == SUCCESS:* ]]; then
                response_time=${result_line#SUCCESS:}
                batch_times+=($response_time)
            else
                batch_failures=$((batch_failures + 1))
            fi
        else
            batch_failures=$((batch_failures + 1))
        fi
        batch_requests=$((batch_requests + 1))
    done
    
    # Update totals
    total_requests=$((total_requests + batch_requests))
    failed_requests=$((failed_requests + batch_failures))
    response_times+=("${batch_times[@]}")
    
    # Calculate statistics
    elapsed=$(($(date +%s) - start_time))
    remaining=$((DURATION - elapsed))
    success_rate=100
    if [ $total_requests -gt 0 ]; then
        success_rate=$(( (total_requests - failed_requests) * 100 / total_requests ))
    fi
    
    # Calculate average response time for this batch
    avg_response_time=0
    if [ ${#batch_times[@]} -gt 0 ]; then
        sum=0
        for time in "${batch_times[@]}"; do
            sum=$((sum + time))
        done
        avg_response_time=$((sum / ${#batch_times[@]}))
    fi
    
    # Progress report
    printf "\r⏱️  %02d:%02d | Requests: %d | Failures: %d | Success: %d%% | Avg Response: %dms" \
        $((elapsed / 60)) $((elapsed % 60)) \
        $total_requests $failed_requests $success_rate $avg_response_time
    
    # Sleep for the remainder of the interval
    batch_duration=$(($(date +%s) - batch_start))
    sleep_time=$((INTERVAL - batch_duration))
    if [ $sleep_time -gt 0 ]; then
        sleep $sleep_time
    fi
done

echo ""
echo ""
echo "🎉 Load test completed!"
echo ""
echo "📊 Final Results:"
echo "   • Total requests: $total_requests"
echo "   • Failed requests: $failed_requests"
echo "   • Success rate: $(( (total_requests - failed_requests) * 100 / total_requests ))%"
echo "   • Duration: $DURATION seconds"

# Calculate overall average response time
if [ ${#response_times[@]} -gt 0 ]; then
    sum=0
    for time in "${response_times[@]}"; do
        sum=$((sum + time))
    done
    avg_response_time=$((sum / ${#response_times[@]}))
    echo "   • Average response time: ${avg_response_time}ms"
fi

echo ""
echo "📋 Current application status:"
kubectl get pods -n sample-app -o wide

echo ""
echo "🔍 To view detailed monitoring logs:"
echo "   kubectl logs deployment/monitoring -n sample-app"

echo ""
echo "🧪 Ready for upgrade testing! Run:"
echo "   ./test-upgrade.sh"