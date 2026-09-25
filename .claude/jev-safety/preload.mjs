import { request } from 'node:http';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const originalFetch = globalThis.fetch.bind(globalThis);
const safetyRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function gate(payload) {
  return new Promise((resolve, reject) => {
    const req = request(
      { hostname: '127.0.0.1', port: 48752, path: '/check', method: 'POST', headers: { 'content-type': 'application/json' } },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (part) => { raw += part; });
        res.on('end', () => {
          try {
            const verdict = JSON.parse(raw);
            resolve(res.statusCode === 200 && verdict.allowed === true);
          } catch { resolve(false); }
        });
      },
    );
    req.setTimeout(5000, () => req.destroy(new Error('safety gate timeout')));
    req.on('error', reject);
    req.end(payload);
  });
}

async function verifyService() {
  const key = (await readFile(resolve(safetyRoot, '.claude/jev-safety/.gate-key'), 'utf8')).trim();
  const nonce = randomBytes(32).toString('hex');
  return new Promise((resolve) => {
    const req = request(
      { hostname: '127.0.0.1', port: 48752, path: `/health?nonce=${nonce}`, method: 'GET' },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (part) => { raw += part; });
        res.on('end', () => {
          try {
            const identity = JSON.parse(raw);
            if (res.statusCode !== 200 || identity.nonce !== nonce || !/^[a-f0-9]{64}$/.test(identity.proof)) {
              resolve(false);
              return;
            }
            const actual = Buffer.from(identity.proof, 'hex');
            const expected = createHmac('sha256', key).update(nonce).digest();
            resolve(timingSafeEqual(actual, expected));
          } catch { resolve(false); }
        });
      },
    );
    req.setTimeout(5000, () => req.destroy(new Error('safety gate timeout')));
    req.on('error', () => resolve(false));
    req.end();
  });
}

globalThis.fetch = async (input, init = {}) => {
  const method = (init.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const url = typeof input === 'string' ? input : input.url;
  if (method === 'POST' && !url.startsWith('http://127.0.0.1') && !url.startsWith('http://localhost')) {
    let payload = init.body;
    if (payload === undefined && input instanceof Request) payload = await input.clone().text();
    if (typeof payload !== 'string') {
      throw new Error('Jev safety gate cannot inspect this request body; blocked');
    }
    let allowed = false;
    try { allowed = await verifyService() && await gate(payload); } catch { allowed = false; }
    if (!allowed) throw new Error('Jev safety gate blocked or was unavailable; request not sent');
  }
  return originalFetch(input, init);
};
