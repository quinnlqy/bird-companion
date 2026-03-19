/**
 * Bird Companion Relay Server
 * - WebSocket port 18790: bird client connects here
 * - HTTP port 18791: OpenClaw POSTs events here
 *
 * OpenClaw needs to add header: x-secret: birdsecret123
 */

const http = require('http');
const WebSocket = require('ws');

const WS_PORT   = 18790;
const HTTP_PORT = 18800;
const SECRET    = 'birdsecret123'; // 和 bird.gd 里保持一致

// ── WebSocket 服务（鸟鸟连这里）─────────────────────────────
const wss = new WebSocket.Server({ port: WS_PORT });
const clients = new Set();

wss.on('connection', (ws) => {
  clients.add(ws);
  console.log(`[WS] 鸟鸟已连接，当前连接数: ${clients.size}`);

  // 发送欢迎包，让鸟鸟知道已连上
  ws.send(JSON.stringify({ type: 'welcome' }));

  ws.on('close', () => {
    clients.delete(ws);
    console.log(`[WS] 鸟鸟断开，当前连接数: ${clients.size}`);
  });

  ws.on('error', (err) => {
    console.error('[WS] 错误:', err.message);
  });
});

function broadcast(payload) {
  const msg = JSON.stringify(payload);
  let sent = 0;
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(msg);
      sent++;
    }
  }
  console.log(`[WS] 推送给 ${sent} 个客户端:`, JSON.stringify(payload));
}

// ── 事件映射表 ───────────────────────────────────────────────
const EVENT_MAP = {
  '/event/work-start': { stream: 'lifecycle', data: { phase: 'start' } },
  '/event/work-end':   { stream: 'lifecycle', data: { phase: 'end'   } },
  '/event/sedentary':  { stream: 'sedentary', data: {} },
  '/event/sleep':      { stream: 'sleep',     data: {} },
  '/event/wake':       { stream: 'wake',      data: {} },
};

// ── HTTP 服务（OpenClaw 调这里）──────────────────────────────
const server = http.createServer((req, res) => {
  // 只接受 POST
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  // 鉴权
  if (req.headers['x-secret'] !== SECRET) {
    res.writeHead(401, { 'Content-Type': 'text/plain' });
    res.end('Unauthorized');
    console.warn('[HTTP] 未授权请求来自:', req.socket.remoteAddress);
    return;
  }

  const eventPayload = EVENT_MAP[req.url];
  if (eventPayload) {
    broadcast({
      type: 'event',
      event: 'agent',
      payload: eventPayload,
    });
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
    console.log('[HTTP] 收到事件:', req.url);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end(`Unknown event: ${req.url}`);
    console.warn('[HTTP] 未知路径:', req.url);
  }
});

server.listen(HTTP_PORT, '0.0.0.0', () => {
  console.log(`✅ Relay 已启动`);
  console.log(`   WS  (鸟鸟连接): ws://0.0.0.0:${WS_PORT}`);
  console.log(`   HTTP (OpenClaw): http://0.0.0.0:${HTTP_PORT}`);
});
