#!/bin/bash

set -e

echo "🚀 Deploying Sample Application for EKS Blue-Green Upgrade Testing"

# Check if kubectl is configured
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ kubectl is not configured or cluster is not accessible"
    echo "Please run: aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster"
    exit 1
fi

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2 2>/dev/null || echo "unknown")
echo "📋 Deploying to cluster: $CLUSTER_NAME"

# Create namespace
echo "📁 Creating namespace..."
kubectl apply -f namespace.yaml

# Wait for namespace to be ready
kubectl wait --for=condition=Active namespace/sample-app --timeout=30s

# Deploy database first (has dependencies)
echo "🗄️  Deploying PostgreSQL database..."
kubectl apply -f database/deployment.yaml

# Wait for database to be ready
echo "⏳ Waiting for database to be ready..."
kubectl wait --for=condition=available deployment/postgres -n sample-app --timeout=300s

# Deploy backend
echo "🔧 Deploying backend API..."
kubectl apply -f backend/configmap.yaml
kubectl apply -f backend/deployment.yaml

# Wait for backend to be ready
echo "⏳ Waiting for backend to be ready..."
kubectl wait --for=condition=available deployment/backend -n sample-app --timeout=300s

# Deploy frontend
echo "🌐 Deploying frontend..."
kubectl apply -f frontend/configmap.yaml
kubectl apply -f frontend/deployment.yaml

# Wait for frontend to be ready
echo "⏳ Waiting for frontend to be ready..."
kubectl wait --for=condition=available deployment/frontend -n sample-app --timeout=300s

# Deploy monitoring
echo "📊 Deploying monitoring..."
kubectl apply -f monitoring/deployment.yaml

# Wait for monitoring to be ready
echo "⏳ Waiting for monitoring to be ready..."
kubectl wait --for=condition=available deployment/monitoring -n sample-app --timeout=120s

# Get service information
echo ""
echo "✅ Deployment completed successfully!"
echo ""
echo "📋 Application Status:"
kubectl get pods -n sample-app -o wide

echo ""
echo "🌐 Services:"
kubectl get services -n sample-app

echo ""
echo "💾 Storage:"
kubectl get pvc -n sample-app

echo ""
echo "🛡️  Pod Disruption Budgets:"
kubectl get pdb -n sample-app

# Get LoadBalancer URL
echo ""
echo "🔗 Getting LoadBalancer URL..."
FRONTEND_URL=""
for i in {1..30}; do
    FRONTEND_URL=$(kubectl get service frontend-service -n sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$FRONTEND_URL" ]; then
        break
    fi
    echo "   Waiting for LoadBalancer... ($i/30)"
    sleep 10
done

if [ -n "$FRONTEND_URL" ]; then
    echo "🎉 Application is accessible at: http://$FRONTEND_URL"
    echo ""
    echo "📱 Available endpoints:"
    echo "   • Main App: http://$FRONTEND_URL"
    echo "   • Health Check: http://$FRONTEND_URL/health"
    echo "   • API Health: http://$FRONTEND_URL/api/health"
    echo "   • Node Info: http://$FRONTEND_URL/api/node-info"
    echo "   • Metrics: http://$FRONTEND_URL/api/metrics"
else
    echo "⚠️  LoadBalancer URL not available yet. Check with:"
    echo "   kubectl get service frontend-service -n sample-app"
fi

echo ""
echo "🔍 Monitoring logs:"
echo "   kubectl logs -f deployment/monitoring -n sample-app"

echo ""
echo "🧪 To test the application:"
echo "   ./start-load-test.sh"
echo "   ./test-upgrade.sh"

echo ""
echo "🗑️  To clean up:"
echo "   ./cleanup.sh"