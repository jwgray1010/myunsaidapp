# Unsaid Vercel API

This folder contains **ONLY** the lightweight proxy endpoints that are deployed to Vercel. These endpoints proxy heavy ML processing requests to the Google Cloud backend.

## What's Here

```
api/
├── v1/
│   ├── health.ts        # Health check (Vercel + Google Cloud status)
│   ├── tone.ts         # Tone analysis (proxies to Google Cloud)
│   └── suggestions.ts  # Suggestion generation (proxies to Google Cloud)
├── _lib/               # Copied utilities from main API
│   ├── services/
│   │   └── gcloudClient.ts  # Google Cloud API client
│   ├── wrappers.ts     # CORS, validation, error handling
│   ├── cors.ts         # CORS middleware
│   ├── http.ts         # HTTP utilities
│   ├── logger.ts       # Logging utilities
│   └── ...            # Other utility files
└── README.md          # This file
```

## Dependencies & Configuration

- **package.json**: Uses root `/package.json` (no duplicate needed)
- **tsconfig.json**: Uses root `/tsconfig.json` (already includes vercel-api/**)
- **vercel.json**: Root configuration updated to deploy this folder

## Architecture

- **This folder (Vercel)**: Lightweight proxy, CORS, input validation
- **Google Cloud (/gcloud-api/)**: Heavy ML processing, ONNX models, data processing  
- **Client (iOS/Flutter)**: Local profile storage, UI, keyboard integration

## Deployment

The main project's `vercel.json` is configured to deploy this folder:
- Routes `/api/v1/*` requests to `/vercel-api/v1/*`
- Uses `@vercel/node` runtime for TypeScript serverless functions
- Uses existing root `package.json` dependencies (no duplication)

## Key Points

- All heavy computation happens in Google Cloud
- Vercel just routes requests, handles CORS, and provides error handling
- No local ML processing or data storage
- Communicator endpoint was removed (client-side storage now)
- Uses existing `gcloudClient` from copied `_lib/services/` folder
- **No duplicate configuration files** - reuses root package.json and tsconfig.json