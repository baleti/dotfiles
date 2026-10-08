// CDP driver for the WhatsApp PWA (needs WA_DEBUG=1 bin/whatsapp-web). Usage: node whatsapp-cdp.mjs click:X:Y wait:MS shot:file.png esc ...
// Slow, human-paced input via Input.dispatch*; no Runtime/Page enable. See memory whatsapp_pwa_cdp_strategy.
import fs from 'node:fs';
const port = fs.readFileSync(process.env.HOME + '/.brave-whatsapp/DevToolsActivePort', 'utf8').split('\n')[0];
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find(t => t.type === 'page' && t.url.startsWith('https://web.whatsapp.com'));
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); });
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const jitter = (a, b) => sleep(a + Math.random() * (b - a));
const shot = async f => fs.writeFileSync(f, Buffer.from((await send('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
const click = async (x, y) => {
  x += Math.random() * 8 - 4; y += Math.random() * 4 - 2;
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x - 40, y: y + 25 }); await jitter(250, 600);
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }); await jitter(250, 500);
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1, buttons: 1 }); await jitter(60, 140);
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1, buttons: 0 });
};
const steps = process.argv.slice(2);
for (const s of steps) {
  const [name, a, b] = s.split(':');
  if (name === 'click') await click(+a, +b);
  if (name === 'esc') { await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }); await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }); }
  if (name === 'wait') await sleep(+a);
  if (name === 'shot') await shot(a);
  await jitter(1500, 2800);
}
console.log('done'); process.exit(0);
