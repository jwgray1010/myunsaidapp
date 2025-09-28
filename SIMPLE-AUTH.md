# Simple API Authentication

## Setup

1. **Set Environment Variable** (Vercel Project → Settings → Environment Variables):
   ```
   API_BEARER_TOKEN=URhIBZpw1lgmZX9WNC7u6mbysTHIAzh1X3TBjdobcmM
   ```

2. **Client Usage** (iOS/Swift):
   ```swift
   req.addValue("Bearer URhIBZpw1lgmZX9WNC7u6mbysTHIAzh1X3TBjdobcmM", forHTTPHeaderField: "Authorization")
   ```

3. **Client Usage** (Web/JavaScript):
   ```javascript
   fetch('/api/v1/tone', {
     method: 'POST',
     headers: {
       'Content-Type': 'application/json',
       'Authorization': 'Bearer URhIBZpw1lgmZX9WNC7u6mbysTHIAzh1X3TBjdobcmM'
     },
     body: JSON.stringify({ text: 'Hello' })
   })
   ```

4. **Test with cURL**:
   ```bash
   curl -X POST https://your-app.vercel.app/api/v1/tone \
     -H "Authorization: Bearer URhIBZpw1lgmZX9WNC7u6mbysTHIAzh1X3TBjdobcmM" \
     -H "Content-Type: application/json" \
     -d '{"text":"Hello"}'
   ```

## Security Notes

- ✅ Token is only stored in environment variables
- ✅ No logging of Authorization headers
- ✅ No token echoing in responses
- ✅ No persistence beyond environment
- ✅ CORS already configured for Authorization header

## Generate New Token

If you need a new token:
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
```