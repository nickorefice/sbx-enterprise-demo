'use strict';

const http = require('http');
const url  = require('url');

const VOTE_SERVICE = process.env.VOTE_SERVICE || 'http://localhost:5000';

function fetchResults(cb) {
  http.get(`${VOTE_SERVICE}/results`, (res) => {
    let data = '';
    res.on('data', chunk => { data += chunk; });
    res.on('end', () => {
      try { cb(null, JSON.parse(data)); }
      catch (e) { cb(e); }
    });
  }).on('error', cb);
}

const server = http.createServer((req, res) => {
  const { pathname } = url.parse(req.url);

  if (pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', service: 'result' }));
  }

  if (pathname === '/') {
    fetchResults((err, totals) => {
      if (err) {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'upstream unavailable' }));
      }
      const total = (totals.a || 0) + (totals.b || 0);
      const pctA  = total ? Math.round((totals.a / total) * 100) : 0;
      const pctB  = total ? 100 - pctA : 0;
      const html  = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Vote Results</title>
<style>body{font-family:sans-serif;max-width:480px;margin:2rem auto}
.bar{height:2rem;border-radius:4px;display:flex;align-items:center;padding:0 .5rem;color:#fff;font-weight:bold}
.a{background:#0073e6}.b{background:#e65000}</style></head>
<body>
<h1>Vote Results</h1>
<p>Option A: ${totals.a} vote(s)</p>
<div class="bar a" style="width:${pctA}%">${pctA}%</div>
<p>Option B: ${totals.b} vote(s)</p>
<div class="bar b" style="width:${pctB}%">${pctB}%</div>
<p><small>Total: ${total}</small></p>
</body></html>`;
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(html);
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

const port = parseInt(process.env.PORT || '3000', 10);
server.listen(port, '0.0.0.0', () => {
  console.log(`result service listening on :${port}`);
});
