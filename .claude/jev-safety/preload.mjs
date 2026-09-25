import { request } from 'node:http';

const originalFetch = globalThis.fetch.bind(globalThis);

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

function verifyService() {
  return new Promise((resolve) => {
    const req = request(
      { hostname: '127.0.0.1', port: 48752, path: '/health', method: 'GET' },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (part) => { raw += part; });
        res.on('end', () => {
          try {
            const identity = JSON.parse(raw);
            resolve(res.statusCode === 200 && identity.service === 'firstmate-jev-safety' && identity.protocol === 1);
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
