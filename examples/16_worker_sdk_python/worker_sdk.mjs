// Thin Node port: exact 4-byte big-endian AF_UNIX framing used by EffectSocket.
import net from 'node:net';
export async function request(socketPath, request) {
  const payload = Buffer.from(JSON.stringify({protocol: 1, request_id: crypto.randomUUID().replaceAll('-', ''), ...request}));
  if (payload.length === 0 || payload.length > 1048576) throw new Error('frame out of bounds');
  const header = Buffer.alloc(4); header.writeUInt32BE(payload.length);
  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath); let data = Buffer.alloc(0), expected = null;
    socket.on('connect', () => socket.write(Buffer.concat([header, payload])));
    socket.on('data', chunk => { data = Buffer.concat([data, chunk]); if (expected === null && data.length >= 4) expected = data.readUInt32BE(0); if (expected !== null && data.length >= 4 + expected) { const msg = JSON.parse(data.subarray(4, 4 + expected)); socket.end(); msg.ok ? resolve(msg.result) : reject(new Error(msg.error)); }});
    socket.on('error', reject);
  });
}
