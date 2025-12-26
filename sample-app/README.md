# Sample Application for EKS Blue-Green Upgrade Testing

This directory contains a comprehensive sample application designed to test zero-downtime EKS upgrades using the Blue-Green strategy.

## Application Architecture

- **Frontend**: React-based web application
- **Backend API**: Node.js REST API
- **Database**: PostgreSQL with persistent storage
- **Load Generator**: Continuous traffic simulation
- **Monitoring**: Health checks and metrics collection

## Components

- `frontend/` - Frontend application manifests
- `backend/` - Backend API manifests  
- `database/` - PostgreSQL database manifests
- `monitoring/` - Monitoring and health check tools
- `load-generator/` - Traffic simulation tools
- `deploy.sh` - Deployment script
- `test-upgrade.sh` - Upgrade testing script

## Quick Deploy

```bash
# Configure kubectl for your cluster
aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster

# Deploy the sample application
./deploy.sh

# Start load testing
./start-load-test.sh

# Test Blue-Green upgrade
./test-upgrade.sh
```