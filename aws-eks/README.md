# EKS Cluster Terraform Configuration

This Terraform configuration creates a complete Amazon EKS cluster in the us-east-1 region with the following components:

## Resources Created

- **VPC**: Custom VPC with public and private subnets across 2 availability zones
- **EKS Cluster**: Managed Kubernetes cluster with logging enabled (version 1.31)
- **Node Group**: Managed worker nodes using Amazon Linux 2 (AL2) AMI in private subnets
- **IAM Roles**: Proper roles and policies for cluster and nodes
- **Security Groups**: Network security for cluster access
- **NAT Gateways**: For private subnet internet access
- **Add-ons**: VPC CNI, CoreDNS, and kube-proxy

## Default Configuration

- **Kubernetes Version**: 1.31
- **AMI Type**: AL2_x86_64 (Amazon Linux 2)
- **Instance Type**: t3.medium
- **Node Capacity**: 2 desired, 1-4 range
- **Region**: us-east-1

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
kubernetes_version = "1.31"
ami_type = "AL2_x86_64"          # Amazon Linux 2
# ami_type = "AL2023_x86_64_STANDARD"  # Amazon Linux 2023 (alternative)
instance_types = ["t3.large"]
desired_capacity = 3
max_capacity = 6
min_capacity = 2
```

### Available AMI Types:
- `AL2_x86_64` - Amazon Linux 2 (default)
- `AL2_x86_64_GPU` - Amazon Linux 2 with GPU support
- `AL2_ARM_64` - Amazon Linux 2 for ARM-based instances
- `AL2023_x86_64_STANDARD` - Amazon Linux 2023
- `AL2023_ARM_64_STANDARD` - Amazon Linux 2023 for ARM-based instances

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
