// V-Taper "push" function: sends the notifications that are due.
// Paste this whole file into Supabase → Edge Functions → Deploy a new function → Via editor, name it "push".
// Needs secrets VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY and VAPID_SUBJECT (Edge Functions → Secrets).
// It only sends notifications that are already due, so it's safe to leave "Verify JWT" off.

const enc = new TextEncoder();
const b64u = {
  enc(buf: ArrayBuffer | Uint8Array): string {
    const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    let s = ""; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  dec(str: string): Uint8Array {
    const s = atob(str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4));
    const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out;
  },
};
const concat = (...parts: Uint8Array[]) => { const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0)); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

// VAPID (RFC 8292): a signed token that proves the message comes from this app.
export async function vapidAuth(endpoint: string, publicKey: string, privateKey: string, subject: string): Promise<string> {
  const pub = b64u.dec(publicKey);
  const jwk = { kty: "EC", crv: "P-256", x: b64u.enc(pub.slice(1, 33)), y: b64u.enc(pub.slice(33, 65)), d: privateKey, ext: true };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64u.enc(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u.enc(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(head + "." + body));
  return `vapid t=${head}.${body}.${b64u.enc(sig)}, k=${publicKey}`;
}

// Message encryption (RFC 8291, aes128gcm), so only the phone can read it.
export async function encryptPayload(p256dh: string, auth: string, payload: string): Promise<Uint8Array> {
  const uaPub = b64u.dec(p256dh), authSecret = b64u.dec(auth);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const prkKey = await hmac(authSecret, shared);
  const ikm = await hmac(prkKey, concat(enc.encode("WebPush: info\0"), uaPub, asPub, new Uint8Array([1])));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(enc.encode(payload), new Uint8Array([2]))));
  const head = new Uint8Array(21); head.set(salt, 0); new DataView(head.buffer).setUint32(16, 4096); head[20] = 65;
  return concat(head, asPub, cipher);
}

export async function sendPush(sub: { endpoint: string; p256dh: string; auth: string }, payload: string, vapid: { pub: string; priv: string; subject: string }, doFetch = fetch) {
  const body = await encryptPayload(sub.p256dh, sub.auth, payload);
  return doFetch(sub.endpoint, {
    method: "POST",
    headers: { TTL: "86400", Urgency: "high", "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
      Authorization: await vapidAuth(sub.endpoint, vapid.pub, vapid.priv, vapid.subject) },
    body,
  });
}

type Row = { id: number; kind: string; tag: string; title: string; body: string; url: string; subs: { endpoint: string; p256dh: string; auth: string }[] };

export async function run(env: (k: string) => string | undefined, doFetch = fetch) {
  const url = env("SUPABASE_URL"), key = env("SB_SECRET_KEY") || env("SUPABASE_SERVICE_ROLE_KEY");
  const vapid = { pub: env("VAPID_PUBLIC_KEY") || "", priv: env("VAPID_PRIVATE_KEY") || "", subject: env("VAPID_SUBJECT") || "mailto:hello@example.com" };
  if (!url || !key) return { error: "Missing SUPABASE_URL or a service key" };
  if (!vapid.pub || !vapid.priv) return { error: "Missing VAPID_PUBLIC_KEY or VAPID_PRIVATE_KEY secret" };
  const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
  if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`;
  const res = await doFetch(`${url}/rest/v1/rpc/push_claim`, { method: "POST", headers, body: "{}" });
  if (!res.ok) return { error: `push_claim failed (${res.status}): ${await res.text()}` };
  const rows = await res.json() as Row[];
  const dead: string[] = []; let sent = 0, failed = 0;
  await Promise.all(rows.flatMap(r => r.subs.map(async s => {
    try {
      const out = await sendPush(s, JSON.stringify({ title: r.title, body: r.body, tag: r.tag, url: r.url, kind: r.kind }), vapid, doFetch);
      if (out.status === 404 || out.status === 410) dead.push(s.endpoint);
      else if (out.ok) sent++; else failed++;
    } catch (_e) { failed++; }
  })));
  if (dead.length) await doFetch(`${url}/rest/v1/rpc/push_drop`, { method: "POST", headers, body: JSON.stringify({ p_endpoints: dead }) });
  return { claimed: rows.length, sent, failed, removed: dead.length };
}

// deno-lint-ignore no-explicit-any
const D = (globalThis as any).Deno;
if (D && D.serve) D.serve(async () => new Response(JSON.stringify(await run(k => D.env.get(k))), { headers: { "Content-Type": "application/json" } }));
