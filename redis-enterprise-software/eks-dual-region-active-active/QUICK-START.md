# Quick Start Guide

**Deploy dual-region Redis Enterprise in 3 steps**

---

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- kubectl installed

---

## 🚀 Step-by-Step Deployment

### **Step 1: Configure Terraform**

```bash
cd redis-enterprise-software/eks-dual-region-active-active

# Copy the example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit the configuration
vim terraform.tfvars
```

**Minimum required changes:**
```hcl
project_prefix = "acme"        # Your company/project name
owner          = "your_name"   # Your name
aws_profile    = "your_profile" # Your AWS CLI profile
```

---

### **Step 2: Deploy Infrastructure to REC Ready**

```bash
# Deploy infrastructure to the point where both RECs are running
terraform init
terraform plan
terraform apply

# Validate the generated configuration
./validate-config.sh

# Verify both Redis Enterprise clusters are running, then upload the
# license manually in each admin UI before continuing.
aws eks update-kubeconfig --region us-east-1 --name <region1-cluster> --alias region1
aws eks update-kubeconfig --region us-east-2 --name <region2-cluster> --alias region2
kubectl get rec -n redis-enterprise --context region1
kubectl get rec -n redis-enterprise --context region2
```

### **Step 3: Post-License Deployment**

```bash
cd post-deployment
source config.env
./deploy-all.sh
```

---

## ✨ What Happens Automatically

When you run `terraform apply`:

1. ✅ **Creates AWS infrastructure** (VPCs, EKS clusters, ingress, peering, RERC prerequisites)
2. ✅ **Deploys both Redis Enterprise clusters (REC)**
3. ✅ **Auto-generates `post-deployment/config.env`** with the values used by post-deployment scripts
4. ✅ **Outputs the manual license checkpoint and next steps**

`terraform apply` intentionally stops before REAADB creation.

---

## 📋 What Gets Created

### **Infrastructure (Terraform)**
- ✅ 2 VPCs (one per region)
- ✅ 2 EKS clusters with node groups
- ✅ VPC peering between regions
- ✅ Route53 private hosted zone
- ✅ IAM roles and security groups
- ✅ Redis Enterprise clusters and remote-cluster prerequisites
- ✅ **Auto-generated `config.env`**

### **Post-License Application**
- ✅ Active-Active Database (CRDB / REAADB)
- ✅ Monitoring and backups

---

## 🔍 Verification

After deployment, verify everything is working:

```bash
# Check EKS clusters
aws eks list-clusters --region us-east-1
aws eks list-clusters --region us-east-2

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name <cluster-name> --alias region1
aws eks update-kubeconfig --region us-east-2 --name <cluster-name> --alias region2

# Check Redis Enterprise
kubectl get rec -n redis-enterprise --context region1
kubectl get rec -n redis-enterprise --context region2

# After licensing and post-deployment, check the Active-Active database
kubectl get reaadb -n redis-enterprise --context region1
```

---

## 🎯 Key Files

| File | Purpose |
|------|---------|
| `terraform.tfvars` | **You edit this** - Infrastructure configuration |
| `post-deployment/config.env` | **Auto-generated** - Application configuration |
| `validate-config.sh` | Validates both configs are in sync |

---

## 💡 Tips

- **First time?** Start with the example values and customize gradually
- **Multiple environments?** Use different `project_prefix` values
- **Need help?** See `CONFIGURATION-GUIDE.md` for detailed explanations

---

## 🆘 Troubleshooting

**Problem:** `config.env` not generated  
**Solution:** Run `terraform apply` - it creates the file automatically

**Problem:** Validation fails  
**Solution:** Check that `project_prefix` in `terraform.tfvars` matches

**Problem:** CRDB deployment is blocked  
**Solution:** Confirm both RECs are running, licensed in the admin UI, and reachable through the configured API FQDNs

---

## 📚 Next Steps

- Read `CONFIGURATION-GUIDE.md` to understand the two-layer architecture
- See `REFACTORING-GUIDE.md` for details on the generic codebase
- Check `GENERIC-CODEBASE-SUMMARY.md` for a complete overview

---

**Ready to deploy? Let's go!** 🚀
