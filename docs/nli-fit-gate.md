# NLI Fit Gate Documentation

## Overview

The NLI (Natural Language Inference) Fit Gate prevents semantic mismatches between user messages and therapy advice by checking entailment relationships. This system ensures advice is contextually appropriate without external API dependencies.

## Architecture

### Components

- **`api/_lib/services/nliLocal.ts`**: ONNX-based NLI verifier
- **`api/_lib/services/suggestions.ts`**: Centralized gate integration
- **`api/v1/health.ts`**: Health monitoring (includes NLI status)
- **`data/evaluation_tones.json`**: Context-specific thresholds

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DISABLE_NLI` | `0` | Set to `1` to disable NLI checking |
| `NLI_ONNX_PATH` | `/var/task/models/mnli-mini.onnx` | Path to ONNX model file |
| `NODE_ENV` | `development` | Controls NLI trace visibility |

## Configuration

### NLI Thresholds

Configured in `data/evaluation_tones.json`:

```json
{
  "nli_thresholds": {
    "default": { "entail_min": 0.55, "contra_max": 0.20 },
    "conflict": { "entail_min": 0.60, "contra_max": 0.18 },
    "repair": { "entail_min": 0.57, "contra_max": 0.19 }
  }
}
```

- **`entail_min`**: Minimum entailment score required (0-1)
- **`contra_max`**: Maximum contradiction score allowed (0-1)

### Hypothesis Generation

The system generates contextual hypotheses for therapy advice:

- **TA035 "listen or help solve"** → "The person is unclear about what type of support they need"
- **Boundary advice** → "The person needs to set or discuss boundaries"
- **Apology advice** → "The person should offer an apology or repair"

## Pipeline Integration

The NLI gate runs after contraindications but before advanced guardrails:

1. **Retrieval**: BM25 + embedding search
2. **Contraindications**: Remove harmful patterns
3. **🔥 NLI Fit Gate**: Check message-advice entailment
4. **Guardrails**: Profanity, context, safety checks
5. **Ranking**: Score and prioritize suggestions

## Fallback Behavior

- **Model unavailable**: Gate passes all advice (rules-only mode)
- **Import failure**: Gracefully degrades to existing guardrails
- **Runtime error**: Fails open, logs warning, continues pipeline

## Monitoring

### Health Endpoint

**GET** `/api/v1/health?check=status`

NLI status is included in the comprehensive health response under the `nli` check:

```json
{
  "success": true,
  "data": {
    "ok": true,
    "checks": [
      {
        "name": "nli",
        "ok": true,
        "data": {
          "ready": true,
          "disabled": false,
          "modelPath": "/var/task/models/mnli-mini.onnx",
          "environment": "production"
        }
      }
    ]
  }
}
```

### Logs

Gate decisions are logged with full context:

```json
{
  "message": "NLI gate rejected advice",
  "id": "TA035",
  "entail": 0.32,
  "contra": 0.45,
  "reason": "nli_fail",
  "ctx": "general"
}
```

### Dev Traces

In non-production environments, NLI scores are included in suggestion responses:

```json
{
  "id": "TA035",
  "text": "Ask: 'Do you want me to listen or help solve?'",
  "nli": {
    "ok": false,
    "entail": 0.32,
    "contra": 0.45,
    "reason": "nli_fail"
  }
}
```

## Performance

- **Cold start**: ~500ms (includes model loading)
- **Inference**: ~50ms per suggestion
- **Memory**: 256MB baseline + model size
- **Bundle**: Model included via `includeFiles` in `vercel.json`

## Example Scenarios

### ✅ Good Entailment

**Message**: "I'm confused about what she meant"
**Advice**: "Ask for clarification about their message"  
**Result**: `entail=0.78, contra=0.12` → **PASS**

### ❌ Poor Entailment

**Message**: "Sure, I can do that"
**Advice**: "Ask: 'Do you want me to listen or help solve?'"  
**Result**: `entail=0.23, contra=0.67` → **REJECT**

## Troubleshooting

### Common Issues

1. **NLI always disabled**
   - Check `DISABLE_NLI` environment variable
   - Verify `onnxruntime-node` package installation
   - Check model file path and permissions

2. **Model loading fails**
   - Verify `NLI_ONNX_PATH` points to valid ONNX file
   - Check Vercel `includeFiles` configuration
   - Ensure sufficient memory allocation (1024MB+)

3. **No advice suggestions**
   - Check if thresholds are too strict
   - Review hypothesis generation logic
   - Monitor entailment/contradiction scores in logs

### Debug Commands

```bash
# Check health endpoint (includes NLI status)
curl https://your-app.vercel.app/api/v1/health?check=status

# Test with NLI disabled
DISABLE_NLI=1 npm run dev

# Monitor logs for NLI decisions
grep "NLI gate" logs/suggestions.log
```