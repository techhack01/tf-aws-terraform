#!/bin/bash

echo "🧹 Cleaning up Sample Application"

# Check if application exists
if ! kubectl get namespace sample-app >/dev/null 2>&1; then
    echo "ℹ️  Sample application not found, nothing to clean up"
    exit 0
fi

echo "📋 Current application status:"
kubectl get all -n sample-app

echo ""
read -p "Are you sure you want to delete the sample application? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Cleanup cancelled"
    exit 0
fi

echo "🗑️  Deleting sample application..."

# Delete deployments first to stop pods gracefully
echo "   Deleting deployments..."
kubectl delete deployment --all -n sample-app --timeout=60s

# Delete services
echo "   Deleting services..."
kubectl delete service --all -n sample-app

# Delete PVCs (this will also delete PVs)
echo "   Deleting persistent volume claims..."
kubectl delete pvc --all -n sample-app

# Delete secrets and configmaps
echo "   Deleting secrets and configmaps..."
kubectl delete secret --all -n sample-app
kubectl delete configmap --all -n sample-app

# Delete PDBs
echo "   Deleting pod disruption budgets..."
kubectl delete pdb --all -n sample-app

# Delete namespace (this will clean up any remaining resources)
echo "   Deleting namespace..."
kubectl delete namespace sample-app --timeout=120s

# Clean up local files
echo "   Cleaning up local monitoring files..."
rm -f /tmp/upgrade-monitor.sh
rm -f /tmp/upgrade-monitoring.log

# Kill any background processes
pkill -f "kubectl port-forward" 2>/dev/null || true
pkill -f "upgrade-monitor.sh" 2>/dev/null || true

echo ""
echo "✅ Cleanup completed successfully!"
echo ""
echo "📋 Verification:"
kubectl get namespace sample-app 2>/dev/null || echo "   ✅ Namespace deleted"
kubectl get pv | grep sample-app || echo "   ✅ No persistent volumes remaining"

echo ""
echo "🎉 Sample application has been completely removed from the cluster"