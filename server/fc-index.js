/**
 * PointWord — Aliyun Function Compute (FC) "Web 函数" HTTP server, Node.js 18.
 *
 * Proxies word-lookup requests to DashScope (Tongyi Qianwen) so the API key
 * never ships inside the iOS app. The app talks only to this server; the key
 * lives in the function's environment variable (DASHSCOPE_API_KEY).
 *
 * Deployed on Aliyun (same cloud as DashScope) so it's reliably reachable from
 * mainland China — unlike Cloudflare's *.workers.dev subdomain.
 *
 * This is a Web-function build: FC runs `npm run start` and forwards HTTP
 * requests to a real server listening on $FC_SERVER_PORT (default 9000).
 * Zero dependencies — only Node's built-in modules, so no npm install needed.
 *
 * Hardening: model and token ceiling are fixed here, so even if someone finds
 * the URL they can only run small word lookups, not a free expensive LLM.
 *
 * Streaming (SSE) from DashScope is written straight through, so the app's
 * typewriter effect keeps working unchanged.
 */

const http = require("http");
const https = require("https");

const PORT = process.env.FC_SERVER_PORT || 9000;

const DASHSCOPE_HOST = "dashscope.aliyuncs.com";
const DASHSCOPE_PATH = "/compatible-mode/v1/chat/completions";

// Locked server-side — the client cannot change these.
const MODEL = "qwen-turbo";
const MAX_TOKENS = 260;
const MAX_MESSAGE_CHARS = 4000;

const server = http.createServer((req, res) => {
  const setCors = () => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, x-app-key");
  };

  const fail = (code, message) => {
    setCors();
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: message }));
  };

  // Simple health check so you can open the URL in a browser.
  if (req.method === "GET") {
    setCors();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, service: "pointword-api" }));
    return;
  }

  if (req.method === "OPTIONS") {
    setCors();
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method !== "POST") {
    return fail(405, "method not allowed");
  }

  const apiKey = process.env.DASHSCOPE_API_KEY;
  if (!apiKey) {
    return fail(500, "server misconfigured: missing key");
  }

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let payload;
    try {
      payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return fail(400, "invalid json");
    }

    // Optional shared-secret gate — enable by setting APP_SHARED_SECRET env var.
    const secret = process.env.APP_SHARED_SECRET;
    if (secret && req.headers["x-app-key"] !== secret) {
      return fail(401, "unauthorized");
    }

    const messages = payload && payload.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return fail(400, "messages required");
    }
    const totalChars = messages.reduce(
      (n, m) => n + (typeof m.content === "string" ? m.content.length : 0),
      0
    );
    if (totalChars > MAX_MESSAGE_CHARS) {
      return fail(413, "prompt too large");
    }

    // Build the upstream request — model / stream / max_tokens fixed here.
    const upstreamBody = JSON.stringify({
      model: MODEL,
      stream: true,
      max_tokens: MAX_TOKENS,
      messages,
    });

    const upstreamReq = https.request(
      {
        host: DASHSCOPE_HOST,
        path: DASHSCOPE_PATH,
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(upstreamBody),
        },
      },
      (upstreamRes) => {
        setCors();
        res.writeHead(upstreamRes.statusCode || 502, {
          "Content-Type":
            upstreamRes.headers["content-type"] || "text/event-stream",
          "Cache-Control": "no-cache",
        });
        // Pass the SSE stream straight through, chunk by chunk.
        upstreamRes.pipe(res);
      }
    );

    upstreamReq.on("error", () => fail(502, "upstream unreachable"));
    upstreamReq.write(upstreamBody);
    upstreamReq.end();
  });
});

server.listen(PORT, () => {
  console.log(`pointword-api listening on ${PORT}`);
});
