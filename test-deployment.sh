#!/bin/bash
# Test script for deployed cloud services

set -e

echo "🧪 Testing Unsaid Cloud Deployment"
echo "==================================="

# Check if required environment variables are set
if [ -z "$VERCEL_URL" ]; then
    echo "❌ VERCEL_URL not set. Please set it to your Vercel app URL."
    echo "   Example: export VERCEL_URL=https://unsaid-app.vercel.app"
    exit 1
fi

if [ -z "$INF_TOKEN" ]; then
    echo "❌ INF_TOKEN not set. Please set it to your bearer token."
    echo "   Example: export INF_TOKEN=your-secret-token"
    exit 1
fi

BASE_URL="$VERCEL_URL"
TOKEN="$INF_TOKEN"

echo "📍 Testing against: $BASE_URL"
echo "🔑 Using token: ${TOKEN:0:10}..."

# Test 1: Health check (if available)
echo ""
echo "1️⃣ Testing health endpoint..."
if curl -s -f "$BASE_URL/api/health" > /dev/null 2>&1; then
    echo "✅ Health check passed"
else
    echo "⚠️  Health check not available (expected for minimal Vercel setup)"
fi

# Test 2: Tone analysis
echo ""
echo "2️⃣ Testing tone analysis..."
TONE_RESPONSE=$(curl -s -X POST "$BASE_URL/api/v1/tone" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"text": "I really appreciate your help with this", "context": "professional"}')

if [ $? -eq 0 ] && echo "$TONE_RESPONSE" | grep -q "ui_tone"; then
    echo "✅ Tone analysis working"
    echo "   Response preview: $(echo "$TONE_RESPONSE" | head -c 100)..."
else
    echo "❌ Tone analysis failed"
    echo "   Response: $TONE_RESPONSE"
    exit 1
fi

# Test 3: Suggestions endpoint
echo ""
echo "3️⃣ Testing suggestions..."
SUGGESTIONS_RESPONSE=$(curl -s -X POST "$BASE_URL/api/v1/suggestions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"text": "You never listen to me", "context": "relationship"}')

if [ $? -eq 0 ] && echo "$SUGGESTIONS_RESPONSE" | grep -q "suggestions"; then
    echo "✅ Suggestions working"
    echo "   Response preview: $(echo "$SUGGESTIONS_RESPONSE" | head -c 100)..."
else
    echo "❌ Suggestions failed"
    echo "   Response: $SUGGESTIONS_RESPONSE"
    exit 1
fi

# Test 4: Communicator endpoint
echo ""
echo "4️⃣ Testing communicator..."
COMMUNICATOR_RESPONSE=$(curl -s -X POST "$BASE_URL/api/v1/communicator" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"text": "I feel unheard in our conversations", "userId": "test-user"}')

if [ $? -eq 0 ] && echo "$COMMUNICATOR_RESPONSE" | grep -q "insights"; then
    echo "✅ Communicator working"
    echo "   Response preview: $(echo "$COMMUNICATOR_RESPONSE" | head -c 100)..."
else
    echo "❌ Communicator failed"
    echo "   Response: $COMMUNICATOR_RESPONSE"
    exit 1
fi

echo ""
echo "🎉 All tests passed! Cloud deployment is working correctly."
echo ""
echo "📊 Next steps:"
echo "   - Monitor Cloud Run costs and performance"
echo "   - Set up proper monitoring and alerting"
echo "   - Consider implementing real ML inference"
echo "   - Test with the iOS keyboard extension"