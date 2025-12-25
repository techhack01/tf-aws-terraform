# EKS Cluster Terraform Configurations.

This Terraform configuration creates a complete Amazon EKS cluster in the us-east-1 region with the following components:

## Resources Created

- **VPC**: Custom VPC with public and private subnets across 2 availability zones
- **EKS Cluster**: Managed Kubernetes cluster with logging enabled
- **Node Group**: Managed worker nodes in private subnets
- **IAM Roles**: Proper roles and policies for cluster and nodes
- **Security Groups**: Network security for cluster access
- **NAT Gateways**: For private subnet internet access
- **Add-ons**: VPC CNI, CoreDNS, and kube-proxy

## Usage

1. **Initialize Terraform**:
   ```bash
   terraform init
   ```

2. **Plan the deployment**:
   ```bash
   terraform plan
   ```

3. **Apply the configuration**:
   ```bash
   terraform apply
   ```

4. **Configure kubectl**:
   ```bash
   aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster
   ```

## Customization

You can customize the deployment by modifying variables in `variables.tf` or by creating a `terraform.tfvars` file:

```hcl
cluster_name = "production-eks"
kubernetes_version = "1.28"
instance_types = ["t3.large"]
desired_capacity = 3
max_capacity = 6
min_capacity = 2
```

## Security Considerations

- The cluster endpoint is accessible from the internet by default (0.0.0.0/0)
- Consider restricting `workstation_cidr` to your specific IP range
- Worker nodes are deployed in private subnets for security
- All cluster logging is enabled for audit purposes

## Cleanup

To destroy the resources:
```bash
terraform destroy
```

## Requirements

- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- kubectl (for cluster management)
