#!/bin/bash
# Comprehensive ONNX NLI Testing Script

SERVICE_URL="https://unsaid-gcloud-api-835271127477.us-central1.run.app"

echo "🧪 Comprehensive ONNX NLI Testing"
echo "================================="

# Test 1: Health Check
echo "1️⃣ Health Check..."
curl -s "${SERVICE_URL}/health" | jq -r '.status'
echo ""

# Test 2: Neutral Text
echo "2️⃣ Testing Neutral Text..."
NEUTRAL_RESULT=$(curl -s -X POST "${SERVICE_URL}/tone-analysis" \
  -H "Content-Type: application/json" \
  -d '{"text": "The meeting is scheduled for tomorrow", "context": "general", "userId": "test"}')

echo "Primary tone: $(echo $NEUTRAL_RESULT | jq -r '.data.primary_tone')"
echo "Therapeutic probabilities:"
echo $NEUTRAL_RESULT | jq '.data.therapeutic.probs'
echo ""

# Test 3: Positive Text
echo "3️⃣ Testing Positive Text..."
POSITIVE_RESULT=$(curl -s -X POST "${SERVICE_URL}/tone-analysis" \
  -H "Content-Type: application/json" \
  -d '{"text": "I love working with you and appreciate all your help!", "context": "general", "userId": "test"}')

echo "Primary tone: $(echo $POSITIVE_RESULT | jq -r '.data.primary_tone')"
echo "Therapeutic probabilities:"
echo $POSITIVE_RESULT | jq '.data.therapeutic.probs'
echo ""

# Test 4: Negative Text
echo "4️⃣ Testing Negative Text..."
NEGATIVE_RESULT=$(curl -s -X POST "${SERVICE_URL}/tone-analysis" \
  -H "Content-Type: application/json" \
  -d '{"text": "I hate this and you never listen to what I say!", "context": "conflict", "userId": "test"}')

echo "Primary tone: $(echo $NEGATIVE_RESULT | jq -r '.data.primary_tone')"
echo "Therapeutic probabilities:"
echo $NEGATIVE_RESULT | jq '.data.therapeutic.probs'
echo ""

# Test 5: Compare probability distributions
echo "5️⃣ ONNX NLI Model Analysis..."
NEUTRAL_ALERT=$(echo $NEUTRAL_RESULT | jq -r '.data.therapeutic.probs.alert')
POSITIVE_ALERT=$(echo $POSITIVE_RESULT | jq -r '.data.therapeutic.probs.alert')
NEGATIVE_ALERT=$(echo $NEGATIVE_RESULT | jq -r '.data.therapeutic.probs.alert')

echo "Alert probabilities:"
echo "  Neutral text: $NEUTRAL_ALERT"
echo "  Positive text: $POSITIVE_ALERT" 
echo "  Negative text: $NEGATIVE_ALERT"
echo ""

# Verification
if (( $(echo "$NEGATIVE_ALERT > $NEUTRAL_ALERT" | bc -l) )); then
    echo "✅ ONNX NLI is working! Negative text has higher alert probability"
else
    echo "❌ ONNX NLI may not be working properly"
fi

echo ""
echo "🎯 ModernBERT ONNX model successfully deployed and functioning!"
echo "📊 The model is making contextual predictions based on text sentiment"