// Preload (-r) tracer: logs fs, child_process, net/dns/http, native addons and a heartbeat.
'use strict';
if (!require('worker_threads').isMainThread) return;
const fs = require('fs');
{
  const { Worker: W0 } = require('worker_threads');
  const code = `const {Session}=require('inspector');const fs=require('fs');const {workerData}=require('worker_threads');
  const L=(m)=>fs.appendFileSync(workerData.log,'WATCH '+m+'\\n');
  setTimeout(()=>{try{const s=new Session();s.connectToMainThread();L('connected');
    s.on('Debugger.paused',(m)=>{L('PAUSED reason='+m.params.reason+' '+m.params.callFrames.slice(0,20).map(f=>(f.functionName||'?')+'@'+f.url.split(/[\\\\/]/).pop()+':'+f.location.lineNumber+':'+f.location.columnNumber).join(' <- '));process.exit(0);});
    s.post('Debugger.enable',(e)=>{L('enabled '+(e&&e.message));s.post('Debugger.pause',(e2)=>L('pause sent '+(e2&&e2.message)));});
  }catch(e){L('err '+e.stack)}},4000);
  setTimeout(()=>{L('no pause within 15s (main thread stuck in native code?)');process.exit(0)},19000);`;
  try { const w = new W0(code, { eval: true, execArgv: [], workerData: { log: process.env.XTRACE_LOG } }); w.unref(); } catch (e) {}
}
const LOG = process.env.XTRACE_LOG;
const append = fs.appendFileSync.bind(fs);
const t0 = Date.now();
function s(a) { try { return typeof a === 'string' ? a : (a && a.href) || (Buffer.isBuffer(a) ? a.toString() : typeof a === 'object' ? JSON.stringify(a).slice(0, 200) : String(a)); } catch { return '?'; } }
let busy = false;
function log(m) { if (busy) return; busy = true; try { append(LOG, (Date.now() - t0) + ' ' + m + '\n'); } catch {} finally { busy = false; } }
log('start pid ' + process.pid + ' argv ' + process.argv.join(' '));

function wrap(obj, name, label) {
  const orig = obj[name];
  if (typeof orig !== 'function' || orig.__x) return;
  const w = function (...args) {
    log(label + '.' + name + ' ' + s(args[0]).slice(0, 300) + (args[1] !== undefined && typeof args[1] !== 'function' ? ' | ' + s(args[1]).slice(0, 200) : ''));
    return orig.apply(this, args);
  };
  w.__x = true;
  Object.defineProperties(w, Object.getOwnPropertyDescriptors(orig));
  try { obj[name] = w; } catch {}
}
for (const k of Object.keys(fs)) { if (k !== 'appendFileSync' && /^[a-z]/.test(k)) wrap(fs, k, 'fs'); }
if (fs.promises) for (const k of Object.keys(fs.promises)) wrap(fs.promises, k, 'fsp');
const cp = require('child_process'); for (const k of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) wrap(cp, k, 'cp');
const net = require('net'); for (const k of ['connect', 'createConnection']) wrap(net, k, 'net');
const dns = require('dns'); for (const k of ['lookup', 'resolve', 'resolve4']) wrap(dns, k, 'dns');
for (const m of ['http', 'https']) { const mod = require(m); wrap(mod, 'request', m); wrap(mod, 'get', m); }
{
  const od = process.dlopen;
  process.dlopen = function (mod, file, ...rest) {
    log('dlopen ' + file);
    const r = od.call(this, mod, file, ...rest);
    const tag = require('path').basename(String(file));
    const ex = mod && mod.exports;
    if (ex && typeof ex === 'object') for (const k of Object.keys(ex)) if (typeof ex[k] === 'function') {
      const f = ex[k];
      ex[k] = function (...a) { log('napi ' + tag + '.' + k); const v = new.target ? Reflect.construct(f, a, new.target) : f.apply(this, a); log('napi-done ' + tag + '.' + k); return v; };
      Object.setPrototypeOf(ex[k], f); ex[k].prototype = f.prototype;
    }
    log('dlopen-done ' + tag);
    return r;
  };
}
const wt = require('worker_threads'); const OW = wt.Worker;
wt.Worker = class extends OW { constructor(f, o) { log('Worker ' + s(f).slice(0, 200)); super(f, o); log('Worker-created'); } };
const aw = Atomics.wait; Atomics.wait = function (...a) { log('Atomics.wait timeout=' + a[3]); const v = aw.apply(Atomics, a); log('Atomics.wait-done ' + v); return v; };
const crypto = require('crypto'); for (const k of ['randomBytes', 'randomUUID', 'randomFillSync', 'createHash', 'pbkdf2Sync', 'scryptSync', 'generateKeyPairSync']) wrap(crypto, k, 'crypto');
const os = require('os'); for (const k of Object.keys(os)) if (typeof os[k] === 'function') wrap(os, k, 'os');
{ const ap = os.availableParallelism; os.availableParallelism = function () { log('STACK ' + new Error().stack.replace(/\n/g, ' <- ')); return ap.call(os); }; }
const Module = require('module'); const ol = Module._load;
Module._load = function (req, parent, isMain) { log('require ' + req); const v = ol.apply(this, arguments); log('required ' + req); return v; };
process.on('exit', (c) => log('exit ' + c));
process.on('uncaughtException', (e) => { log('uncaught ' + (e && e.stack)); process.exit(70); });
process.on('unhandledRejection', (e) => log('unhandledRejection ' + (e && e.stack)));
let n = 0;
const iv = setInterval(() => {
  n++;
  let h = []; try { h = process._getActiveHandles().map((x) => x.constructor && x.constructor.name); } catch {}
  let r = []; try { r = process._getActiveRequests().map((x) => x.constructor && x.constructor.name); } catch {}
  log('tick ' + n + ' handles=' + h.join(',') + ' requests=' + r.join(','));
}, 2000);
iv.unref();
