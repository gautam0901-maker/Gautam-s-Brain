# Natural TTS Setup Guide

## 🎯 What Changed

Your app now supports **3 natural TTS providers** with automatic failover. No more robotic device voices!

| Provider | Cost | Quality | Monthly Limit | Setup Time |
|----------|------|---------|----------------|-----------|
| **Groq PlayAI** | ~$5-10/mo | ⭐⭐⭐⭐⭐ | Unlimited | Already configured |
| **Google Cloud** | Free! | ⭐⭐⭐⭐ | 1M requests | 5 min |
| **Azure Speech** | Free! | ⭐⭐⭐⭐ | 5M requests | 5 min |
| **Device flutter_tts** | Free | ⭐ | Unlimited | N/A (robotic) |

---

## 🚀 QUICK START: Use Free Google Cloud TTS

### Step 1: Create Google Cloud Account
```bash
# Go to: https://console.cloud.google.com
# Sign up with your Gmail account
```

### Step 2: Get Free API Key
1. Go to Google Cloud Console
2. Create new project (e.g., "Glint News")
3. Enable "Cloud Text-to-Speech API"
4. Create API key (Credentials → Create Credentials → API Key)
5. Copy the key

### Step 3: Deploy to Cloudflare Worker
```bash
cd cloudflare-worker

# Add your Google Cloud API key as a secret
wrangler secret put GOOGLE_CLOUD_KEY
# Paste your API key when prompted

# Deploy
wrangler deploy
```

### Step 4: Test It
- Open Glint app
- Ask a question in chat or read an article
- TTS should now sound natural!

---

## 🔧 Advanced: Multi-Provider Setup (Recommended)

Get **maximum availability** by setting up 2+ providers:

### Setup Google Cloud TTS
```bash
wrangler secret put GOOGLE_CLOUD_KEY
# Paste: AIzaSyD... (your key)
```

### Setup Azure Speech (Optional but RECOMMENDED)
```bash
# Get key from: https://portal.azure.com
# 1. Create "Speech Services" resource
# 2. Copy Key 1 from "Keys and Endpoint"

wrangler secret put AZURE_SPEECH_KEY
# Paste your key

wrangler secret put AZURE_SPEECH_REGION
# Paste your region (e.g., "eastus", "westeurope")
```

### Deploy
```bash
wrangler deploy
```

---

## 📊 How Failover Works

When user plays TTS, tries in order:
1. **Groq PlayAI** (if key set + quota available)
2. **Google Cloud** (if key set + quota available)
3. **Azure Speech** (if keys set + quota available)
4. **Device TTS** (fallback, robotic but always works)

If step 1 fails → instantly tries step 2, etc.

---

## 💰 Free Tier Limits

### Google Cloud Text-to-Speech
- **1,000,000 requests/month free**
- ~90 hours of audio playback
- Good for casual users

### Azure Speech Services
- **5,000,000 requests/month free**
- ~450 hours of audio playback
- Generous free tier

### Example Usage
- 1 article read aloud = ~1-3 requests (split into sentences)
- 1 chat response = ~1-2 requests
- **You'll never hit free limits** unless you're reading 1000+ articles/month

---

## 🎤 Voice Customization

Your app already supports these voices across all providers:
- **Celeste** (warm female) ← Default
- **Arista** (bright female)
- **Quinn** (calm neutral)
- **Fritz** (clear male)
- **Atlas** (deep male)
- **Indigo** (soft neutral)

Each provider maps these to their closest equivalent voice.

---

## 🔐 Security Notes

- ✅ API keys stored **server-side on Cloudflare Worker** (encrypted)
- ✅ Keys **never ship in the app**
- ✅ Keys **can't be extracted** from APK
- ✅ Each user shares your one key (free tier handles this)

---

## 🐛 Troubleshooting

### "TTS still sounds robotic"
- Check if Google Cloud/Azure keys are set
- Run: `wrangler secret list` to verify
- Redeploy: `wrangler deploy`
- Restart app completely

### "Network error when playing"
- Worker may be temporarily down
- Check: `curl https://glint-ai.glintai.workers.dev`
- Should return: `{"ok":true,"service":"glint-ai"}`

### "Runs out of free quota"
- Upgrade to paid plan in provider console
- Or switch to different provider
- Or keep device TTS as fallback

---

## 📝 In-App Settings (Future)

Users can switch providers in Settings:
```
Settings → Audio & Voice
├─ Voice: [Celeste ▼]
├─ TTS Provider: [Auto-failover ▼]
│   ├─ Auto-failover (recommended)
│   ├─ Groq PlayAI (if paid)
│   ├─ Google Cloud (free)
│   └─ Azure Speech (free)
└─ Cloud TTS: [ON/OFF]
```

---

## 🚀 Next Steps

1. ✅ Pick **Google Cloud** or **Azure** (or both)
2. ✅ Create free account + get API key
3. ✅ Run `wrangler secret put` to add key
4. ✅ Deploy: `wrangler deploy`
5. ✅ Restart your app
6. ✅ Test TTS — should sound natural now!

Questions? Check the [Google Cloud TTS docs](https://cloud.google.com/text-to-speech) or [Azure Speech docs](https://learn.microsoft.com/azure/ai-services/speech-service/)
