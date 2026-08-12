// The reqweaver API worker: goal encoding via Workers AI, plan storage
// in KV, and read-only sharing. Rust/WASM keeps billed CPU time minimal.
//
// Routes (all CORS-open; the app is a static page on another origin):
//   POST   /encode          {"text": ...} -> {"model", "vector"}
//   POST   /api/plans       body <= 64 KB -> {"planId", "writeToken"}
//   GET    /api/plans/:id   the stored payload (edge-cached briefly)
//   PUT    /api/plans/:id   Bearer writeToken -> {"ok": true}
//   DELETE /api/plans/:id   Bearer writeToken -> {"ok": true}
//
// planId is the read capability (the /s/<code> share code); writeToken
// is returned once at creation and stored only as a SHA-256 hash.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use worker::*;

const EMBED_MODEL: &str = "@cf/baai/bge-small-en-v1.5";
const MAX_TEXT: usize = 500;
const MAX_PLAN_BYTES: usize = 64 * 1024;
const SHARE_CACHE_TTL: u64 = 300; // seconds of edge caching for reads
const ENCODE_CACHE_TTL: u64 = 90 * 86_400; // encoded vectors live 90 days
const ENCODE_LIMIT_PER_MIN: u64 = 10; // model calls per IP per minute

fn cors(mut resp: Response) -> Result<Response> {
    let headers = resp.headers_mut();
    headers.set("Access-Control-Allow-Origin", "*")?;
    headers.set("Access-Control-Allow-Headers", "Content-Type, Authorization")?;
    headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")?;
    Ok(resp)
}

fn json_error(status: u16, message: &str) -> Result<Response> {
    cors(Response::from_json(&serde_json::json!({ "error": message }))?.with_status(status))
}

fn sha256_hex(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hex(&hasher.finalize())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn random_base58(bytes: usize) -> Result<String> {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).map_err(|e| Error::RustError(e.to_string()))?;
    Ok(bs58::encode(buf).into_string())
}

#[derive(Deserialize)]
struct EncodeRequest {
    text: String,
}

#[derive(Serialize, Deserialize)]
struct PlanRecord {
    v: u32,
    created_at: u64,
    updated_at: u64,
    write_token_hash: String,
    payload: serde_json::Value,
}

fn now_ms() -> u64 {
    Date::now().as_millis()
}

fn json_ok(body: String) -> Result<Response> {
    let mut resp = cors(Response::ok(body)?)?;
    resp.headers_mut()
        .set("Content-Type", "application/json; charset=utf-8")?;
    Ok(resp)
}

// Encoding is deterministic per (model, text), so the vector is cached
// in KV: repeated goals, including a naive flood, cost a KV read and
// never reach the metered model. Only a cache miss counts against the
// per-IP limit, so an attacker must invent unique strings from one
// address to spend model time, and the limiter caps that.
async fn handle_encode(mut req: Request, env: &Env) -> Result<Response> {
    let body: EncodeRequest = match req.json().await {
        Ok(b) => b,
        Err(_) => return json_error(400, "expected {\"text\": ...}"),
    };
    let text: String = body.text.chars().take(MAX_TEXT).collect::<String>().trim().to_string();
    let kv = env.kv("PLANS")?;
    let cache_key = format!("enc:{}", sha256_hex(&format!("{EMBED_MODEL}\n{text}")));
    if let Some(hit) = kv.get(&cache_key).cache_ttl(SHARE_CACHE_TTL).text().await? {
        return json_ok(hit);
    }
    let ip = req
        .headers()
        .get("CF-Connecting-IP")
        .ok()
        .flatten()
        .unwrap_or_else(|| "unknown".to_string());
    let rl_key = format!("rl:{ip}:{}", now_ms() / 60_000);
    let used: u64 = kv
        .get(&rl_key)
        .text()
        .await?
        .and_then(|t| t.parse().ok())
        .unwrap_or(0);
    if used >= ENCODE_LIMIT_PER_MIN {
        return json_error(429, "rate limited; try again in a minute");
    }
    kv.put(&rl_key, (used + 1).to_string())?
        .expiration_ttl(120)
        .execute()
        .await?;
    let ai = env.ai("AI")?;
    let output: serde_json::Value = ai
        .run(EMBED_MODEL, serde_json::json!({ "text": [text] }))
        .await?;
    let raw = output["data"][0]
        .as_array()
        .ok_or_else(|| Error::RustError("unexpected model output".into()))?;
    let mut vector: Vec<f64> = raw.iter().filter_map(|v| v.as_f64()).collect();
    let norm = vector.iter().map(|v| v * v).sum::<f64>().sqrt().max(1e-12);
    for v in vector.iter_mut() {
        *v = (*v / norm * 100000.0).round() / 100000.0;
    }
    let body_json = serde_json::json!({ "model": EMBED_MODEL, "vector": vector }).to_string();
    kv.put(&cache_key, body_json.clone())?
        .expiration_ttl(ENCODE_CACHE_TTL)
        .execute()
        .await?;
    json_ok(body_json)
}

async fn create_plan(mut req: Request, env: &Env) -> Result<Response> {
    let payload: serde_json::Value = match req.json().await {
        Ok(p) => p,
        Err(_) => return json_error(400, "expected a JSON plan payload"),
    };
    if serde_json::to_vec(&payload).map(|v| v.len()).unwrap_or(usize::MAX) > MAX_PLAN_BYTES {
        return json_error(413, "plan payload exceeds 64 KB");
    }
    let plan_id = random_base58(16)?;
    let write_token = random_base58(16)?;
    let record = PlanRecord {
        v: 1,
        created_at: now_ms(),
        updated_at: now_ms(),
        write_token_hash: sha256_hex(&write_token),
        payload,
    };
    env.kv("PLANS")?
        .put(&plan_key(&plan_id), serde_json::to_string(&record)?)?
        .execute()
        .await?;
    cors(Response::from_json(&serde_json::json!({
        "planId": plan_id,
        "writeToken": write_token,
    }))?)
}

fn plan_key(id: &str) -> String {
    format!("plan:{id}")
}

async fn load_plan(env: &Env, id: &str) -> Result<Option<PlanRecord>> {
    let text = env
        .kv("PLANS")?
        .get(&plan_key(id))
        .cache_ttl(SHARE_CACHE_TTL)
        .text()
        .await?;
    Ok(match text {
        Some(t) => serde_json::from_str(&t).ok(),
        None => None,
    })
}

fn bearer_token(req: &Request) -> Option<String> {
    req.headers()
        .get("Authorization")
        .ok()
        .flatten()
        .and_then(|h| h.strip_prefix("Bearer ").map(str::to_owned))
}

async fn read_plan(env: &Env, id: &str) -> Result<Response> {
    match load_plan(env, id).await? {
        Some(record) => {
            let mut resp = cors(Response::from_json(&serde_json::json!({
                "createdAt": record.created_at,
                "updatedAt": record.updated_at,
                "payload": record.payload,
            }))?)?;
            resp.headers_mut()
                .set("Cache-Control", &format!("public, max-age={SHARE_CACHE_TTL}"))?;
            Ok(resp)
        }
        None => json_error(404, "no such plan"),
    }
}

async fn update_plan(mut req: Request, env: &Env, id: &str) -> Result<Response> {
    let Some(token) = bearer_token(&req) else {
        return json_error(401, "missing write token");
    };
    let Some(mut record) = load_plan(env, id).await? else {
        return json_error(404, "no such plan");
    };
    if sha256_hex(&token) != record.write_token_hash {
        return json_error(403, "wrong write token");
    }
    let payload: serde_json::Value = match req.json().await {
        Ok(p) => p,
        Err(_) => return json_error(400, "expected a JSON plan payload"),
    };
    if serde_json::to_vec(&payload).map(|v| v.len()).unwrap_or(usize::MAX) > MAX_PLAN_BYTES {
        return json_error(413, "plan payload exceeds 64 KB");
    }
    record.payload = payload;
    record.updated_at = now_ms();
    env.kv("PLANS")?
        .put(&plan_key(id), serde_json::to_string(&record)?)?
        .execute()
        .await?;
    cors(Response::from_json(&serde_json::json!({ "ok": true }))?)
}

async fn delete_plan(req: Request, env: &Env, id: &str) -> Result<Response> {
    let Some(token) = bearer_token(&req) else {
        return json_error(401, "missing write token");
    };
    let Some(record) = load_plan(env, id).await? else {
        return json_error(404, "no such plan");
    };
    if sha256_hex(&token) != record.write_token_hash {
        return json_error(403, "wrong write token");
    }
    env.kv("PLANS")?.delete(&plan_key(id)).await?;
    cors(Response::from_json(&serde_json::json!({ "ok": true }))?)
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    if req.method() == Method::Options {
        return cors(Response::empty()?.with_status(204));
    }
    let url = req.url()?;
    let path = url.path().to_string();
    let segments: Vec<&str> = path.trim_matches('/').split('/').collect();
    match (req.method(), segments.as_slice()) {
        (Method::Post, ["encode"]) => handle_encode(req, &env).await,
        (Method::Post, ["api", "plans"]) => create_plan(req, &env).await,
        (Method::Get, ["api", "plans", id]) => read_plan(&env, id).await,
        (Method::Put, ["api", "plans", id]) => update_plan(req, &env, id).await,
        (Method::Delete, ["api", "plans", id]) => delete_plan(req, &env, id).await,
        _ => json_error(404, "no such route"),
    }
}
