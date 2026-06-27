# 🎯 DEPLOY BOTH GOOGLE & AZURE TTS - FINAL GUIDE

## 📊 Your TTS Failover Chain (NOW LIVE)

```
User plays TTS
    ↓
1. Try Groq PlayAI (if key exists) → PREMIUM
    ↓ fails or no key
2. Try Google Cloud → FREE (1M/month)
    ↓ fails or no key  
3. Try Azure Speech → FREE (5M/month) ← BACKUP
    ↓ fails or no key
4. Device flutter_tts → ROBOTIC BUT ALWAYS WORKS
```

**Voice Consistency**: Same voice personality across providers
- Celeste = warm female (Google Neural2-C → Azure AmberNeural)
- Arista = bright female (Google Neural2-A → Azure JennyNeural)
- Quinn = calm neutral (Google Neural2-E → Azure ElizaNeural)
- Fritz = clear male (Google Neural2-B → Azure GuyNeural)
- Atlas = deep male (Google Neural2-D → Azure EricNeural)
- Indigo = soft neutral (Google Neural2-F → Azure CoraNeural)

---

## 🚀 STEP 1: Get Google Cloud API Key (5 min)

```bash
# 1. Go to https://console.cloud.google.com
# 2. Create new project (name: "Glint")
# 3. Search for "Cloud Text-to-Speech API"
# 4. Click "Enable"
# 5. Go to "Credentials" → "Create Credentials" → "API Key"
# 6. Copy the key (looks like: AIzaSyD...)
```

---

## 🚀 STEP 2: Get Azure Speech Service Key (5 min)

```bash
# 1. Go to https://portal.azure.com
# 2. Click "Create a resource"
# 3. Search: "Speech Services" → Click "Create"
# 4. Set:
#    - Name: glint-speech
#    - Location: East US (eastus) or your closest region
#    - Pricing: Free F0 tier
#    - Resource group: Create new "glint"
# 5. Click "Create"
# 6. After deployment, go to "Keys and Endpoint"
# 7. Copy "Key 1" (looks like: 1a2b3c4d...)
```

---

## 🚀 STEP 3: Deploy to Cloudflare Worker

```bash
# Navigate to your worker directory
cd cloudflare-worker

# Add Google Cloud key
wrangler secret put GOOGLE_CLOUD_KEY
# Paste: AIzaSyD... (your Google API key)
# Press Enter

# Add Azure Speech key
wrangler secret put AZURE_SPEECH_KEY
# Paste: 1a2b3c4d... (your Azure key)
# Press Enter

# Deploy to production
wrangler deploy
```

**You should see**: ✅ `Deployment ID: ...`

---

## 🚀 STEP 4: Verify Deployment

```bash
# Test the worker health
curl https://glint-ai.glintai.workers.dev

# Should return: {"ok":true,"service":"glint-ai"}
```

---

## 🚀 STEP 5: Test in Your App

1. Restart Glint completely (force close + reopen)
2. Ask a question in chat
3. Click play button on response
4. Listen to TTS 👂

**Expected**: Natural voice (NOT robotic)

---

## 🔧 Troubleshooting

### "Still sounds robotic"
✅ Verify your keys were deployed:
```bash
wrangler secret list
# Should show:
# - GOOGLE_CLOUD_KEY
# - AZURE_SPEECH_KEY
```

✅ Redeploy if needed:
```bash
wrangler deploy
```

✅ Force restart app (kill + reopen)

### "Network error" / "TTS failed"
✅ Test worker health:
```bash
curl https://glint-ai.glintai.workers.dev
```

✅ If error, check Google/Azure quotas:
- Google: https://console.cloud.google.com → Quotas
- Azure: https://portal.azure.com → Your resource → Monitor

### "One provider not working"
That's OKAY! Auto-failover handles it:
- If Google hits quota → automatically tries Azure
- If Azure fails → automatically tries device TTS
- Users won't notice the switch

### "How do I know which provider is running?"
Check network logs or logs from the endpoint with:
```bash
# View last 100 deployments
wrangler tail
```

You'll see `X-TTS-Provider: google` or `X-TTS-Provider: azure` in response headers.

---

## 📊 Free Tier Limits (You'll Never Hit These)

| Provider | Free Tier | Equals |
|----------|-----------|--------|
| Google Cloud | 1,000,000/month | 90 hours of audio |
| Azure Speech | 5,000,000/month | 450 hours of audio |
| **Combined** | 6,000,000/month | **540 hours/month** |

**Example daily usage**:
- Read 20 articles/day = 20-60 requests
- 10 chat responses/day = 10-20 requests
- **Total = ~100 requests/day = 3,000/month**

✅ You'll use ~0.5% of your free limit

---

## 🎤 Optional: Customize Azure Region

If you want Azure in a specific region:

```bash
# Update in Flutter app settings (optional)
# Default: eastus
# Other options: westeurope, eastasia, southcentralus, etc.

# Or change when deploying (ask if you need this)
```

---

## ✅ You're Done!

Your app now has:
- ✅ Natural TTS (Google Cloud)
- ✅ Automatic failover to Azure
- ✅ Same voice personality across all providers
- ✅ Completely FREE (both providers on free tier)
- ✅ Server-side secrets (never exposed in app)

Next time Google Cloud hits quota (unlikely), Azure automatically kicks in without user noticing.

**Try it now**: Open app → ask question → hit play button → enjoy natural voice! 🎉
