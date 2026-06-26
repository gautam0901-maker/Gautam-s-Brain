// Glint AI proxy — Cloudflare Worker.
//
// Holds YOUR API keys server-side (as encrypted Worker Secrets) so every
// app user gets AI through your single key with zero setup. The key never
// ships in the app and can't be extracted from the APK.
//
// Failover chain: Gemini 2.0 Flash → Cerebras → Groq. If one is busy /
// out of quota / errors, the next answers. The app falls back to keyless
// Pollinations only if this whole worker is unreachable.
//
// Deploy:  wrangler deploy
// Secrets: wrangler secret put GEMINI_KEY   (then CEREBRAS_KEY, GROQ_KEY)

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: cors() });
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
