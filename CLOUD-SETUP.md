# Cloud Deployment Setup Guide

This guide walks you through setting up Google Cloud Run for the inference service and Vercel for the web API.

## Prerequisites

1. **Google Cloud Account**: Sign up at https://cloud.google.com/
2. **Vercel Account**: Sign up at https://vercel.com/
3. **GitHub Repository**: Your code should be in a GitHub repo

## Step 1: Google Cloud Setup

### Option A: Automated Setup (Recommended)

1. Make the setup script executable:
   ```bash
   chmod +x setup-cloud.sh
   ```

2. Run the setup script:
   ```bash
   ./setup-cloud.sh
   ```

   This will:
   - Enable required APIs
   - Create a service account
   - Generate a service account key
   - Display next steps

### Option B: Manual Setup

If you prefer manual setup, follow these commands:

```bash
# Set your project
export PROJECT_ID="your-project-id"
export REGION="us-central1"

gcloud config set project $PROJECT_ID
gcloud config set run/region $REGION

# Enable APIs
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com

# Create service account
gcloud iam service-accounts create github-actions-inference \
    --description="GitHub Actions CI/CD for inference service" \
    --display-name="GitHub Actions Inference"

# Grant permissions
SERVICE_ACCOUNT_EMAIL="github-actions-inference@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/run.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/artifactregistry.writer"

# Create key
gcloud iam service-accounts keys create github-key.json \
    --iam-account=$SERVICE_ACCOUNT_EMAIL
```

## Step 2: GitHub Secrets Configuration

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

### Google Cloud Secrets
- `GCP_PROJECT_ID`: Your Google Cloud project ID
- `GCP_SA_KEY`: Contents of the `github-key.json` file (paste the entire JSON)
- `GCP_REGION`: `us-central1` (or your chosen region)
- `INF_TOKEN`: A secure bearer token for API authentication (generate a random string)

### Vercel Secrets
- `VERCEL_TOKEN`: Your Vercel access token (from https://vercel.com/account/tokens)
- `VERCEL_ORG_ID`: Your Vercel organization ID
- `VERCEL_PROJECT_ID`: Your Vercel project ID

## Step 3: Environment Variables

### Cloud Run Environment Variables
Set these in your Cloud Run service (will be done automatically by CI/CD):
- `INF_TOKEN`: Same as the GitHub secret above

### Vercel Environment Variables
Set these in your Vercel project settings:
- `INF_BASE_URL`: Will be set after first deployment (Cloud Run service URL)
- `INF_TOKEN`: Same bearer token as above

## Step 4: Initial Deployment

1. **Commit and push** all changes to the `main` branch:
   ```bash
   git add .
   git commit -m "Add cloud deployment configuration"
   git push origin main
   ```

2. **Monitor deployments**:
   - Cloud Run deployment: Check GitHub Actions → "Deploy Inference Service"
   - Vercel deployment: Check GitHub Actions → "Deploy Web API"

3. **Get the Cloud Run URL** from the deployment logs and update Vercel:
   ```bash
   # The workflow will output the service URL
   # Copy it and set INF_BASE_URL in Vercel environment variables
   ```

## Step 5: Test the Deployment

Test the complete pipeline:

```bash
# Test tone analysis endpoint
curl -X POST https://your-vercel-app.vercel.app/api/v1/tone \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-inf-token" \
  -d '{"text": "Hello world", "context": "casual"}'
```

## Troubleshooting

### Common Issues

1. **API Enablement Delay**: If APIs aren't enabled immediately, wait 2-3 minutes and try again.

2. **Service Account Permissions**: Ensure the service account has all required roles.

3. **Vercel Deployment Fails**: Check that all required secrets are set correctly.

4. **Cloud Run Timeout**: The service has a 5-minute timeout. Long-running inferences may need adjustment.

### Monitoring

- **Cloud Run Logs**: `gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=unsaid-inference"`
- **Vercel Logs**: Check in Vercel dashboard
- **GitHub Actions**: Monitor workflow runs for deployment status

## Security Notes

- The service account key (`github-key.json`) should never be committed to git
- Use strong, unique bearer tokens for `INF_TOKEN`
- Regularly rotate service account keys
- Monitor Cloud Run costs and set budgets

## Cost Optimization

- Cloud Run charges only for actual usage
- Set appropriate memory/CPU limits
- Configure concurrency and max instances based on load
- Use Vercel's free tier for development