# Glint AI Worker

A tiny Cloudflare Worker that holds your AI keys server-side so every app
user gets AI with **zero setup**. Keys never ship inside the app.

Failover chain: **Gemini 2.0 Flash → Cerebras → Groq**.

---

## One-time setup

### 1. Make a free Cloudflare account
https://dash.cloudflare.com/sign-up — no credit card.

### 2. Install the deploy tool (needs Node.js installed)
```bash
npm install -g wrangler
```

### 3. Log in (opens your browser once)
```bash
wrangler login
```

### 4. Paste your API keys as SECRETS
Run each command, and when it asks **"Enter a secret value:"**, paste the
key and press Enter. **This is where your keys go — never in any file.**

```bash
cd cloudflare-worker

wrangler secret put GEMINI_KEY      # paste your AIza... key
wrangler secret put CEREBRAS_KEY    # paste your csk-... key   (optional)
wrangler secret put GROQ_KEY        # paste your gsk_... key   (optional)
wrangler secret put APP_TOKEN       # type any random password (optional, anti-abuse)
```

You only NEED Gemini. Cerebras + Groq are extra fallbacks. Add them later
anytime by re-running the command.

### 5. Deploy
```bash
wrangler deploy
```

It prints your worker URL, e.g.:
```
https://glint-ai.YOURNAME.workers.dev
```

### 6. Give me that URL
Tell Claude the URL (and the APP_TOKEN if you set one). I'll paste it into
the app's `lib/services/ai_service.dart` so the app calls your worker.

---

## Testing it works
Open the worker URL in a browser — you should see `{"ok":true,...}`.

To change a key later, just re-run `wrangler secret put <NAME>` and it
overwrites. No redeploy needed for secret changes.

## Where keys live
- **Production keys** → Cloudflare Secrets (encrypted, set via `wrangler secret put`)
- **Local testing** (optional) → a `.dev.vars` file (git-ignored), format:
  ```
  GEMINI_KEY=AIza...
  GROQ_KEY=gsk_...
  ```
  then run `wrangler dev`.
