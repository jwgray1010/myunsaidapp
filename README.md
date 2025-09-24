# Unsaid - AI Communication Assistant

A monorepo containing a Flutter mobile app, Next.js web API, and Cloud Run inference service for AI-powered communication insights.

## Architecture

```
repo-root/
├── apps/
│   └── web/                    # Next.js API on Vercel
│       ├── api/v1/tone.ts      # Bridge endpoints (no ML models)
│       ├── vercel.json         # Vercel config
│       └── .vercelignore       # Exclude model files
├── services/
│   └── inference/              # Cloud Run service (Node/TS + ONNX)
│       ├── src/server.ts       # Fastify server with ONNX runtime
│       ├── models/             # MiniLM.onnx, tokenizer files
│       └── Dockerfile          # Container build
└── .github/workflows/          # CI/CD pipelines
    ├── deploy-cloud-run.yml    # Auto-deploy inference service
    └── deploy-vercel.yml       # Auto-deploy web API
```

## Quick Start

### 1. Google Cloud Setup
```bash
# Initialize project
gcloud init
gcloud config set project YOUR_PROJECT_ID
gcloud config set run/region us-central1

# Enable APIs
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com

# Create service account for CI/CD
gcloud iam service-accounts create github-actions \
  --description="GitHub Actions CI/CD" \
  --display-name="GitHub Actions"

# Grant permissions
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Create and download JSON key
gcloud iam service-accounts keys create github-key.json \
  --iam-account=github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

### 2. GitHub Secrets
Add these secrets to your GitHub repository:

**For Cloud Run:**
- `GCP_PROJECT_ID`: Your Google Cloud project ID
- `GCP_SA_KEY`: Contents of the `github-key.json` file
- `GCP_REGION`: `us-central1` (or your preferred region)
- `SERVICE_NAME`: `unsaid-inference` (optional)

**For Vercel:**
- `VERCEL_TOKEN`: Your Vercel API token
- `VERCEL_ORG_ID`: Your Vercel organization ID
- `VERCEL_PROJECT_ID`: Your Vercel project ID

### 3. Environment Variables

**Vercel (apps/web):**
```
INF_BASE_URL=https://unsaid-inference-XXXX-uc.a.run.app
INF_TOKEN=your-super-secret-token
```

**Cloud Run (services/inference):**
```
INF_TOKEN=your-super-secret-token
```

### 4. Deploy

**Inference Service (Cloud Run):**
```bash
cd services/inference
npm install
npm run build
gcloud run deploy unsaid-inference \
  --source . \
  --region us-central1 \
  --platform managed \
  --allow-unauthenticated=false \
  --port 8080 \
  --memory 512Mi \
  --cpu 1
```

**Web API (Vercel):**
```bash
cd apps/web
npm install
npx vercel --prod
```

## Development

### Local Development

**Inference Service:**
```bash
cd services/inference
npm install
npm run dev  # Uses tsx for hot reload
```

**Web API:**
```bash
cd apps/web
npm install
npx vercel dev
```

### Testing

**Test inference service:**
```bash
curl -X POST "http://localhost:8080/tone" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-token" \
  -d '{"text":"Hello world"}'
```

**Test web API bridge:**
```bash
curl -X POST "http://localhost:3000/api/v1/tone" \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello world"}'
```

## Deployment Flow

1. **Push to `main`** → GitHub Actions triggers
2. **Inference changes** → Cloud Run redeploys automatically
3. **Web API changes** → Vercel redeploys automatically
4. **Model updates** → Push new ONNX files to `services/inference/models/`

## Data Deployment

**Configuration Data:**
- `services/inference/data/` → All 22 data files deployed to Cloud Run with the ML service
- `apps/web/` → No data files (thin bridge layer only)

**ML Models:**
- `services/inference/models/` → MiniLM ONNX model and tokenizer (Cloud Run only)

**Architecture Benefits:**
- Smaller Vercel bundles (faster deployments, lower costs)
- All heavy data processing in Cloud Run
- Clean separation: Vercel = routing, Cloud Run = computation

## Performance

- **Cold starts**: Cloud Run scales to zero, ~3-5s cold start time
- **Inference**: MiniLM model processes ~100 tokens in ~50-100ms
- **Scaling**: Auto-scales to 50 instances max, 20 concurrent requests each
- **Cost**: ~$0.10/hour for typical usage (512Mi RAM, 1 vCPU)
