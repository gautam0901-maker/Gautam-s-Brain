// Glint AI proxy — Cloudflare Worker.
//
// Holds YOUR API keys server-side (as encrypted Worker Secrets) so every
// app user gets AI through your single key with zero setup. The key never
// ships in the app and can't be extracted from the APK.
//
// TTS Failover chain (natural voices):
//   1) Groq PlayAI (paid, premium quality)
//   2) Google Cloud TTS (free tier: 1M/month, natural)
//   3) Azure Speech (free tier: 5M/month, natural)
//   4) Device flutter_tts (fallback, robotic)
//
// Deploy:  wrangler deploy
// Secrets: wrangler secret put GROQ_KEY GOOGLE_CLOUD_KEY AZURE_SPEECH_KEY
// AI Secrets: wrangler secret put GEMINI_KEY CEREBRAS_KEY

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: cors() });
    }
    const url = new URL(request.url);
    // 🔊 Text-to-speech route — Groq PlayAI TTS → audio bytes.
    if (url.pathname === '/tts') {
      return handleTts(request, env);
    }
    // Health check — open the worker URL in a browser to see "ok".
    if (request.method === 'GET') {
      return json({ ok: true, service: 'glint-ai' });
    }
    if (request.method !== 'POST') {
      return json({ error: 'POST only' }, 405);
    }

    // Optional light abuse protection. If you set an APP_TOKEN secret, the
    // app must send the same value in the x-glint-token header. Not
    // bulletproof (the token also lives in the app) but stops casual spam.
    if (env.APP_TOKEN) {
      if (request.headers.get('x-glint-token') !== env.APP_TOKEN) {
        return json({ error: 'unauthorized' }, 401);
      }
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'bad json' }, 400);
    }
    const messages = body.messages || [];
    const maxTokens = body.maxTokens || 900;
    if (!Array.isArray(messages) || messages.length === 0) {
      return json({ error: 'no messages' }, 400);
    }

    // 1) Gemini 2.0 Flash
    if (env.GEMINI_KEY) {
      const r = await callGemini(env.GEMINI_KEY, messages, maxTokens);
      if (r) return json({ text: r, provider: 'Gemini' });
    }
    // 2) Cerebras
    if (env.CEREBRAS_KEY) {
      const r = await callOpenAi(
        'https://api.cerebras.ai/v1/chat/completions',
        env.CEREBRAS_KEY, 'llama-3.3-70b', messages, maxTokens);
      if (r) return json({ text: r, provider: 'Cerebras' });
    }
    // 3) Groq
    if (env.GROQ_KEY) {
      const r = await callOpenAi(
        'https://api.groq.com/openai/v1/chat/completions',
        env.GROQ_KEY, 'llama-3.1-8b-instant', messages, maxTokens);
      if (r) return json({ text: r, provider: 'Groq' });
    }

    return json({ error: 'all providers failed' }, 502);
  },
};

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, x-glint-token',
  };
}

// ── 🔊 Text-to-speech: Multi-provider TTS with fallover ──────────────────
// POST /tts  { text, voice, ttsProvider, azureRegion }  → audio/wav or mp3
// Provider order: groq → google → azure → error
// The app falls back to device voice when this returns non-audio.
async function handleTts(request, env) {
  if (request.method !== 'POST') return json({ error: 'POST only' }, 405);
  if (env.APP_TOKEN && request.headers.get('x-glint-token') !== env.APP_TOKEN) {
    return json({ error: 'unauthorized' }, 401);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'bad json' }, 400);
  }
  const text = (body.text || '').toString().slice(0, 9000);
  const voice = (body.voice || 'Celeste-PlayAI').toString();
  const ttsProvider = (body.ttsProvider || 'auto').toString().toLowerCase();
  const azureRegion = env.AZURE_SPEECH_REGION || body.azureRegion || 'eastus';
  
  if (!text.trim()) return json({ error: 'no text' }, 400);

  // Define the chain of TTS providers to try. Azure first — it has real
  // broadcast "newscast" neural voices (the news-anchor sound Glint wants).
  const providerChain = [
    {
      name: 'azure',
      enabled: env.AZURE_SPEECH_KEY,
      handler: () => azureTts(env.AZURE_SPEECH_KEY, azureRegion, text, voice),
      contentType: 'audio/mpeg',
    },
    {
      name: 'google',
      enabled: env.GOOGLE_CLOUD_KEY,
      handler: () => googleCloudTts(env.GOOGLE_CLOUD_KEY, text, voice),
      contentType: 'audio/mpeg',
    },
    {
      name: 'groq',
      enabled: env.GROQ_KEY,
      handler: () => groqTts(env.GROQ_KEY, text, voice),
      contentType: 'audio/wav',
    },
  ];

  for (const provider of providerChain) {
    if (provider.enabled && (ttsProvider === 'auto' || ttsProvider === provider.name)) {
      const audio = await provider.handler();
      if (audio) {
        return new Response(audio, { headers: { 'Content-Type': provider.contentType, 'X-TTS-Provider': provider.name, ...cors() } });
      }
    }
  }

  return json({ error: 'all tts providers failed' }, 502);
}

async function groqTts(key, text, voice) {
  try {
    const resp = await fetch('https://api.groq.com/openai/v1/audio/speech', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'playai-tts',
        input: text,
        voice,
        response_format: 'wav',
      }),
      signal: AbortSignal.timeout(25000),
    });
    if (!resp.ok) return null;
    const buf = await resp.arrayBuffer();
    return buf && buf.byteLength > 1000 ? buf : null;
  } catch {
    return null;
  }
}

// Google Cloud Text-to-Speech (free tier: 1M requests/month)
// Maps PlayAI voice names to Google Cloud voices with matching emotions
async function googleCloudTts(key, text, voice) {
  try {
    const googleVoiceMap = {
      'Celeste-PlayAI': { name: 'en-US-Neural2-C', gender: 'FEMALE' },   // warm female
      'Arista-PlayAI': { name: 'en-US-Neural2-A', gender: 'FEMALE' },    // bright female
      'Quinn-PlayAI': { name: 'en-US-Neural2-E', gender: 'FEMALE' },     // calm neutral
      'Fritz-PlayAI': { name: 'en-US-Neural2-B', gender: 'MALE' },       // clear male
      'Atlas-PlayAI': { name: 'en-US-Neural2-D', gender: 'MALE' },       // deep male
      'Indigo-PlayAI': { name: 'en-US-Neural2-F', gender: 'FEMALE' },    // soft neutral
    };
    
    const voiceConfig = googleVoiceMap[voice] || googleVoiceMap['Celeste-PlayAI'];
    
    const resp = await fetch(`https://texttospeech.googleapis.com/v1/text:synthesize?key=${key}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: { text },
        voice: {
          languageCode: 'en-US',
          name: voiceConfig.name,
          ssmlGender: voiceConfig.gender,
        },
        audioConfig: {
          audioEncoding: 'MP3',
          pitch: 0,
          speakingRate: 0.95, // slightly slower for readability
        },
      }),
      signal: AbortSignal.timeout(20000),
    });
    
    if (!resp.ok) return null;
    const data = await resp.json();
    if (data.audioContent) {
      const buf = Uint8Array.from(atob(data.audioContent), c => c.charCodeAt(0));
      return buf.buffer;
    }
    return null;
  } catch {
    return null;
  }
}

// Microsoft Azure Speech Services (free tier: 0.5M chars/month).
// Maps Glint's voice choices to Azure NEWSCAST-capable neural voices and
// wraps the text in an `mstts:express-as` newscast style → genuine TV news
// anchor delivery. Higher 24kHz/48kbps mp3 for crisp audio.
async function azureTts(key, region, text, voice) {
  try {
    // Only Aria / Jenny / Guy / Jane / Nancy support newscast styles, so we
    // map every choice onto one of those (with its best-supported style).
    const azureVoiceMap = {
      'Celeste-PlayAI': { name: 'en-US-AriaNeural', style: 'newscast-casual' },
      'Arista-PlayAI': { name: 'en-US-JennyNeural', style: 'newscast' },
      'Quinn-PlayAI': { name: 'en-US-AriaNeural', style: 'newscast-formal' },
      'Fritz-PlayAI': { name: 'en-US-GuyNeural', style: 'newscast' },
      'Atlas-PlayAI': { name: 'en-US-GuyNeural', style: 'newscast' },
      'Indigo-PlayAI': { name: 'en-US-JennyNeural', style: 'newscast' },
    };
    // Allow the app to pass a raw Azure voice name directly too.
    let voiceName, style;
    if (voice && voice.includes('Neural')) {
      voiceName = voice;
      style = 'newscast-casual';
    } else {
      const cfg = azureVoiceMap[voice] || azureVoiceMap['Celeste-PlayAI'];
      voiceName = cfg.name;
      style = cfg.style;
    }

    const ssml =
      `<speak version='1.0' xml:lang='en-US' ` +
      `xmlns='http://www.w3.org/2001/10/synthesis' ` +
      `xmlns:mstts='https://www.w3.org/2001/mstts'>` +
      `<voice name='${voiceName}'>` +
      `<mstts:express-as style='${style}'>` +
      `<prosody rate='-2%'>${escapeXml(text)}</prosody>` +
      `</mstts:express-as></voice></speak>`;

    const resp = await fetch(
      `https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`,
      {
        method: 'POST',
        headers: {
          'Ocp-Apim-Subscription-Key': key,
          'Content-Type': 'application/ssml+xml',
          'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
          'User-Agent': 'glint-news',
        },
        body: ssml,
        signal: AbortSignal.timeout(25000),
      }
    );

    if (!resp.ok) return null;
    const buf = await resp.arrayBuffer();
    return buf && buf.byteLength > 1000 ? buf : null;
  } catch {
    return null;
  }
}

function escapeXml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors() },
  });
}

// Cerebras + Groq share the OpenAI chat-completions shape.
async function callOpenAi(endpoint, key, model, messages, maxTokens) {
  try {
    const resp = await fetch(endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        messages,
        max_tokens: maxTokens,
        temperature: 0.7,
      }),
      signal: AbortSignal.timeout(12000),
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    const text = data?.choices?.[0]?.message?.content;
    return text ? text.trim() : null;
  } catch {
    return null;
  }
}

// Gemini uses its own request/response shape.
async function callGemini(key, messages, maxTokens) {
  try {
    const contents = [];
    let systemText = null;
    for (const m of messages) {
      const role = m.role || 'user';
      const text = m.content || '';
      if (!text) continue;
      if (role === 'system') {
        systemText = systemText ? systemText + '\n' + text : text;
        continue;
      }
      contents.push({
        role: role === 'assistant' ? 'model' : 'user',
        parts: [{ text }],
      });
    }
    const payload = {
      contents,
      generationConfig: { maxOutputTokens: maxTokens, temperature: 0.7 },
    };
    if (systemText) payload.systemInstruction = { parts: [{ text: systemText }] };

    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${key}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(12000),
      });
    if (!resp.ok) return null;
    const data = await resp.json();
    const parts = data?.candidates?.[0]?.content?.parts || [];
    const text = parts.map((p) => p.text || '').join('').trim();
    return text || null;
  } catch {
    return null;
  }
}
