#!/bin/bash
# Google Cloud Setup Script for Unsaid Inference Service
# Run this script to set up Cloud Run infrastructure

set -e

echo "🚀 Setting up Google Cloud for Unsaid Inference Service"
echo "======================================================"

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo "❌ gcloud CLI not found. Please install it first:"
    echo "   https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Get project ID
read -p "Enter your Google Cloud Project ID: " PROJECT_ID
if [ -z "$PROJECT_ID" ]; then
    echo "❌ Project ID is required"
    exit 1
fi

echo "📍 Using project: $PROJECT_ID"

# Set project
gcloud config set project $PROJECT_ID

# Get region
read -p "Enter region (default: us-central1): " REGION
REGION=${REGION:-us-central1}
gcloud config set run/region $REGION

echo "📍 Using region: $REGION"

# Enable required APIs
echo "🔧 Enabling required APIs..."
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com
gcloud services enable containerregistry.googleapis.com

# Verify APIs are enabled
echo "✅ Verifying API enablement..."
gcloud services list --enabled | grep -E "(run|artifactregistry|containerregistry)" || {
    echo "❌ Some APIs may not be enabled yet. Please wait a few minutes and try again."
    exit 1
}

# Create service account
SERVICE_ACCOUNT_NAME="github-actions-inference"
SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"

echo "👤 Creating service account: $SERVICE_ACCOUNT_EMAIL"
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --description="GitHub Actions CI/CD for inference service" \
    --display-name="GitHub Actions Inference"

# Grant permissions
echo "🔑 Granting permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/run.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/iam.serviceAccountUser"

# Create and download key
KEY_FILE="github-key.json"
echo "🔐 Creating service account key..."
gcloud iam service-accounts keys create $KEY_FILE \
    --iam-account=$SERVICE_ACCOUNT_EMAIL

echo "✅ Setup complete!"
echo ""
echo "📋 Next steps:"
echo "1. Add these secrets to your GitHub repository:"
echo "   - GCP_PROJECT_ID: $PROJECT_ID"
echo "   - GCP_SA_KEY: (contents of $KEY_FILE)"
echo "   - GCP_REGION: $REGION"
echo "   - SERVICE_NAME: unsaid-inference"
echo ""
echo "2. Set environment variables in Cloud Run:"
echo "   - INF_TOKEN: your-secret-bearer-token"
echo ""
echo "3. Set environment variables in Vercel:"
echo "   - INF_BASE_URL: https://unsaid-inference-XXXX-uc.a.run.app"
echo "   - INF_TOKEN: your-secret-bearer-token"
echo ""
echo "4. Push to main branch to trigger deployment"
echo ""
echo "🔒 IMPORTANT: Keep $KEY_FILE secure and don't commit it to git!"