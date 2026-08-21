/**
 * PointWord — Cloudflare Worker
 *
 * Proxies word-lookup requests to Aliyun DashScope (Tongyi Qianwen) so the API
 * key never ships inside the iOS app. The app talks only to this Worker; the
 * key lives in a Worker secret (DASHSCOPE_API_KEY) and is injected here.
 *
 * Hardening: the model and token ceiling are fixed server-side, so even if
 * someone finds the Worker URL they can only run small word lookups — they
 * can't turn it into a free, expensive LLM endpoint.
 *
 * Streaming (SSE) is passed straight through, so the app's typewriter effect
 * keeps working unchanged.
 */

const DASHSCOPE_URL =
  "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";

// Locked server-side — the client cannot change these.
const MODEL = "qwen-turbo";
const MAX_TOKENS = 260; // small ceiling → cheap; a word lookup never needs more
const MAX_MESSAGE_CHARS = 4000; // reject oversized prompts (abuse guard)

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    // Optional shared-secret gate. Set APP_SHARED_SECRET as a Worker secret and
    // send the same value in the "x-app-key" header from the app to enable it.
    if (env.APP_SHARED_SECRET) {
      if (request.headers.get("x-app-key") !== env.APP_SHARED_SECRET) {
        return json({ error: "unauthorized" }, 401);
      }
    }

    if (!env.DASHSCOPE_API_KEY) {
      return json({ error: "server misconfigured: missing key" }, 500);
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return json({ error: "invalid json" }, 400);
    }

    const messages = payload && payload.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return json({ error: "messages required" }, 400);
    }

    const totalChars = messages.reduce(
      (n, m) => n + (typeof m.content === "string" ? m.content.length : 0),
      0
    );
    if (totalChars > MAX_MESSAGE_CHARS) {
      return json({ error: "prompt too large" }, 413);
    }

    // Build the upstream request — model / stream / max_tokens are fixed here,
    // not taken from the client.
    const upstreamBody = JSON.stringify({
      model: MODEL,
      stream: true,
      max_tokens: MAX_TOKENS,
      messages,
    });

    let upstream;
    try {
      upstream = await fetch(DASHSCOPE_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.DASHSCOPE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: upstreamBody,
      });
    } catch (e) {
      return json({ error: "upstream unreachable" }, 502);
    }

    // Pass the SSE stream straight through, preserving status and content-type.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type":
          upstream.headers.get("Content-Type") || "text/event-stream",
        "Cache-Control": "no-cache",
        ...corsHeaders(),
      },
    });
  },
};

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, x-app-key",
  };
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}
