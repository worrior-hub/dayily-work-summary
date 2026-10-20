// 한곳 색인 - Vercel 서버리스 함수 공용 부분 (Upstash Redis REST API 사용, 별도 패키지 불필요)
// 응답 형식과 입력 정리 규칙은 한곳색인/server.ps1 과 같게 맞춘다.
const crypto = require('crypto');
let seed = [];
try { seed = require('../한곳색인/seed.json'); } catch (e) { console.error('seed.json not loaded', e); }

const KEY = 'hangot:items';         // 해시: id -> 자료 JSON
const SEEDED_KEY = 'hangot:seeded'; // 예시 자료를 한 번 넣었는지 표시

const LOCATIONS = ['노션', '카톡', '메신저', '수첩', '출력본', 'PC 폴더', '인터넷', '기타'];

// Vercel 마켓플레이스의 Upstash 연결은 KV_* 또는 UPSTASH_REDIS_REST_* 이름으로 환경변수를 넣는다
const REDIS_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const REDIS_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

async function redis(...command) {
  if (!REDIS_URL || !REDIS_TOKEN) throw new Error('storage not configured');
  const res = await fetch(REDIS_URL, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + REDIS_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify(command),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.error) throw new Error('storage error: ' + (data.error || res.status));
  return data.result;
}

function sendJson(res, code, obj) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(obj));
}

function sendEmpty(res, code) {
  res.statusCode = code;
  res.setHeader('Cache-Control', 'no-store');
  res.end();
}

// 접근 코드: 환경변수 ACCESS_CODE 와 요청 헤더 X-Access-Code 가 같아야 한다.
// ACCESS_CODE 를 설정하지 않았으면 공개되지 않도록 아예 막는다.
function checkAccess(req, res) {
  const expected = process.env.ACCESS_CODE;
  if (!expected) { sendJson(res, 500, { error: 'ACCESS_CODE not configured' }); return false; }
  const given = String(req.headers['x-access-code'] || '');
  const a = crypto.createHash('sha256').update(given).digest();
  const b = crypto.createHash('sha256').update(expected).digest();
  if (!crypto.timingSafeEqual(a, b)) { sendJson(res, 401, { error: 'access code required' }); return false; }
  return true;
}

function clean(v, max) {
  if (v === null || v === undefined) return '';
  const s = String(v).trim();
  return s.length > max ? s.substring(0, max) : s;
}

// 예시 자료(seed.json)와 같은 한국 시간 표기: 2026-10-20T09:10:00+09:00
function kstNow() {
  const t = new Date(Date.now() + 9 * 3600 * 1000).toISOString().substring(0, 19);
  return t + '+09:00';
}

function readBody(req) {
  const b = req.body;
  if (b && typeof b === 'object') return b;
  if (typeof b === 'string' && b) return JSON.parse(b);
  return {};
}

function toItem(body, existing) {
  const title = clean(body.title, 200);
  let loc = clean(body.location, 20);
  if (!title) { const e = new Error('title required'); e.status = 400; throw e; }
  if (!LOCATIONS.includes(loc)) loc = '기타';
  const now = kstNow();
  return {
    id: existing ? existing.id : crypto.randomUUID().replace(/-/g, ''),
    title,
    location: loc,
    detail: clean(body.detail, 500),
    summary: clean(body.summary, 2000),
    createdAt: existing ? existing.createdAt : now,
    updatedAt: now,
  };
}

async function listItems() {
  // server.ps1 처럼 처음 한 번은 시연용 예시 자료로 시작 (모두 지운 뒤에는 다시 넣지 않음)
  if (await redis('SET', SEEDED_KEY, '1', 'NX')) {
    const args = [];
    for (const s of seed) args.push(s.id, JSON.stringify(s));
    if (args.length) await redis('HSET', KEY, ...args);
  }
  const flat = (await redis('HGETALL', KEY)) || [];
  const items = [];
  for (let i = 1; i < flat.length; i += 2) {
    try { items.push(JSON.parse(flat[i])); } catch {}
  }
  items.sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
  return items;
}

async function getItem(id) {
  const raw = await redis('HGET', KEY, id);
  return raw ? JSON.parse(raw) : null;
}

async function saveItem(item) {
  await redis('HSET', KEY, item.id, JSON.stringify(item));
}

async function removeItem(id) {
  await redis('HDEL', KEY, id);
}

function sendError(res, err) {
  console.error(err);
  sendJson(res, err.status || (err instanceof SyntaxError ? 400 : 500), { error: err.message });
}

module.exports = {
  sendJson, sendEmpty, sendError, checkAccess, readBody, toItem,
  listItems, getItem, saveItem, removeItem,
};
