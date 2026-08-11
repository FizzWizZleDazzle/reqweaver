// Goal-encoding endpoint on Cloudflare Workers AI.
// POST /encode {"text": "..."} -> {"model": ..., "vector": [384 floats]}
// Same model as the compile-time course embeddings (tools/embed.py), so
// goal and course vectors share one space. Plain JS because Workers
// require an ES-module default export, which LiveScript does not emit.

const MODEL = '@cf/baai/bge-small-en-v1.5';
const MAX_TEXT = 500;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json',
};

function normalize(vector) {
  let norm = 0;
  for (const v of vector) norm += v * v;
  norm = Math.sqrt(norm) || 1;
  return vector.map((v) => v / norm);
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/encode') {
      return new Response('{"error": "POST /encode"}', { status: 404, headers: CORS });
    }
    let text;
    try {
      text = String((await request.json()).text).slice(0, MAX_TEXT);
    } catch {
      return new Response('{"error": "expected {\\"text\\": ...}"}', { status: 400, headers: CORS });
    }
    const result = await env.AI.run(MODEL, { text: [text] });
    const vector = normalize(result.data[0]).map((v) => Math.round(v * 100000) / 100000);
    return new Response(JSON.stringify({ model: MODEL, vector }), { headers: CORS });
  },
};
