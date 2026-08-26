// Demo target for the README recording: a service with a finite worker pool, so
// latency stays flat until the offered rate crosses capacity and then queues.
const http = require('http');
const body = Buffer.from(JSON.stringify({ ok: true, region: 'eu-central-1', items: 12 }));

let seed = 0x2545F491;
function rnd() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return ((seed >>> 0) / 4294967296); }
function gauss() { return Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd()); }

const SLOTS = Number(process.env.SLOTS || 24);   // concurrent workers
const SERVICE_MS = Number(process.env.SERVICE_MS || 8);
let busy = 0;
const queue = [];

function service() {
  let d = Math.exp(Math.log(SERVICE_MS) + 0.45 * gauss());
  if (rnd() < 0.02) d *= 4;                       // occasional slow request
  return d;
}

function pump() {
  while (busy < SLOTS && queue.length) {
    const res = queue.shift();
    busy++;
    setTimeout(() => {
      busy--;
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': body.length });
      res.end(body);
      pump();
    }, service());
  }
}

const srv = http.createServer((req, res) => { queue.push(res); pump(); });
srv.keepAliveTimeout = 60000; srv.headersTimeout = 65000;
srv.listen(8080, '127.0.0.1', () => console.log('listening'));
