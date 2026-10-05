/* ════════════════════════════════════════════════════════════════════════
   MODO TESTE (temporário)  ·  só liga com  ?teste=1  no endereço
   - Troca o servidor por uma simulação dentro do navegador: nada vai para o Supabase.
   - Os dados ficam no localStorage (chave av_teste_db), compartilhados entre as abas deste navegador.
   - Para remover: apague este arquivo e a linha "document.write(... teste.js ...)" do index.html.
   ════════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  var KEY = 'av_teste_db';
  var RPC = 'https://taugeysuczntdgwtrcsx.supabase.co/rest/v1/rpc/';
  var ALL = ['A', 'B1', 'B2', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'];
  var SYMS = ['amp', 'fem', 'pro', 'sor', 'pct', 'mas'];
  var CH = { amp: '&', fem: '♀', pro: '⊘', sor: '☺', pct: '%', mas: '♂' };
  var NAMES = ['Ana', 'Bruno', 'Carla', 'Davi', 'Eva', 'Fabio', 'Gui', 'Helena', 'Igor', 'Julia', 'Lucas'];
  var CODE_CH = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  var netFail = false;              // "queda de conexão" (só nesta aba)

  document.title = '[TESTE] ' + document.title;

  // ───────────────────────── banco simulado
  function fresh() { return { skew: 0, sessions: {}, planes: {}, parts: {}, msgs: [], mid: 0, pend: [], pidn: 0, auto: true }; }
  function load() { try { var d = JSON.parse(localStorage.getItem(KEY)); if (d && d.sessions) return d; } catch (e) {} return fresh(); }
  function save(d) { try { localStorage.setItem(KEY, JSON.stringify(d)); } catch (e) {} }
  function now(d) { return Date.now() + d.skew; }
  function rnd(n) { return Math.floor(Math.random() * n); }
  function shuffle(a) { a = a.slice(); for (var i = a.length - 1; i > 0; i--) { var j = rnd(i + 1), t = a[i]; a[i] = a[j]; a[j] = t; } return a; }
  function mkCode(used) { for (;;) { var c = ''; for (var i = 0; i < 4; i++) c += CODE_CH[rnd(CODE_CH.length)]; if (!used[c]) return c; } }
  function botToken() { var s = 'bot-'; while (s.length < 36) s += Math.floor(Math.random() * 16).toString(16); return s; }
  function canSend(f, t) { if (f === 'A') return t === 'B1' || t === 'B2'; if (f === 'B1' || f === 'B2') return t !== f && ALL.indexOf(t) >= 0; return t === 'B1' || t === 'B2'; }
  function online(d, x) { return x.bot ? !x.off : x.last_seen > now(d) - 30000; }
  function partsOf(d, pc) { return Object.keys(d.parts).map(function (k) { return d.parts[k]; }).filter(function (x) { return x.plane === pc; }); }
  function byRole(d, pc, role) { return partsOf(d, pc).filter(function (x) { return x.role === role; })[0]; }
  function pj(d, pc) {
    var o = {}; partsOf(d, pc).forEach(function (x) { o[x.id] = { name: x.name, role: x.role, seat: x.seat || null, online: online(d, x), connectedAt: x.connected }; }); return o;
  }
  function tick(d, p) { if (p.phase === 'playing' && p.timer_end && p.timer_end <= now(d)) p.phase = 'ended'; }
  function sweep(d, pc) {
    if (d.planes[pc].phase !== 'lobby') return;
    partsOf(d, pc).forEach(function (x) { if (!x.bot && x.role == null && x.last_seen < now(d) - 90000) delete d.parts[x.id]; });
  }
  function me(d, pc, tok) { return partsOf(d, pc).filter(function (x) { return x.tok === tok; })[0]; }
  function facPlane(d, tok, code) {
    var p = d.planes[(code || '').toUpperCase()];
    return p && d.sessions[p.session] && d.sessions[p.session].tok === tok ? p : null;
  }
  function msgJson(m) { return { _key: m.id, fromRole: m.f, fromName: m.fn, toRole: m.t, text: m.body, ts: m.ts }; }
  function meta(p) { return { numParticipants: p.num, timerMinutes: p.timer, planeVersion: p.version }; }
  function addMsg(d, pc, f, t, body, ts) {
    var from = byRole(d, pc, f); d.mid++;
    d.msgs.push({ id: d.mid, plane: pc, f: f, fn: from ? from.name : '?', t: t, body: body, ts: ts || now(d) });
  }
  function sheetText(x) { return (x && x.symbols ? x.symbols : []).slice(0, 3).map(function (s) { return CH[s]; }).join(' '); }
  // respostas automáticas das pessoas simuladas (entram depois de alguns segundos)
  function flush(d) {
    var keep = [];
    d.pend.forEach(function (r) {
      if (r.due > now(d)) { keep.push(r); return; }
      var p = d.planes[r.plane]; if (p && p.phase === 'playing') addMsg(d, r.plane, r.f, r.t, r.body);
    });
    d.pend = keep;
  }
  // folhas de teste: cada pessoa tem o símbolo-resposta e 4 dos outros 5 (cada outro some de alguém)
  function startCore(d, p) {
    var ch = partsOf(d, p.code).sort(function (a, b) { return a.connected - b.connected; }).slice(0, p.num);
    var pool = ALL.slice(0, ch.length);
    var used = ch.map(function (x) { return x.seat; }).filter(function (s) { return pool.indexOf(s) >= 0; });
    var free = shuffle(pool.filter(function (r) { return used.indexOf(r) < 0; }));
    var others = SYMS.filter(function (s) { return s !== p.key; });
    ch.forEach(function (x) {
      x.role = pool.indexOf(x.seat) >= 0 ? x.seat : free.shift();
      var skip = others[pool.indexOf(x.role) % others.length];
      x.symbols = shuffle([p.key].concat(others.filter(function (s) { return s !== skip; })));
    });
    p.phase = 'playing'; p.revealed = false; p.answer = null; p.correct = null; p.by = null;
    p.timer_end = p.timer > 0 ? now(d) + p.timer * 60000 : null;
  }

  var api = {
    av_create_session: function (d, a) {
      var sc = mkCode(d.sessions); d.sessions[sc] = { tok: a.p_token, created: now(d) }; var pl = [];
      for (var i = 0; i < a.p_num_planes; i++) {
        var pc = mkCode(d.planes);
        d.planes[pc] = { code: pc, session: sc, idx: i, version: i % 5 + 1, key: SYMS[rnd(6)], num: a.p_num_part, timer: a.p_timer, phase: 'lobby', timer_end: null, revealed: false, answer: null, correct: null, by: null };
        pl.push({ code: pc, version: i % 5 + 1, numParticipants: a.p_num_part, timerMinutes: a.p_timer });
      }
      return { sessionCode: sc, planes: pl, now: now(d) };
    },
    av_fac_load: function (d, a) {
      var sc = (a.p_session || '').toUpperCase(), se = d.sessions[sc];
      if (!se) return { error: 'not_found' };
      if (se.tok !== a.p_token) return { error: 'forbidden' };
      return { sessionCode: sc, now: now(d), planes: sessionPlanes(d, sc).map(function (p) { return { code: p.code, version: p.version, numParticipants: p.num, timerMinutes: p.timer }; }) };
    },
    av_fac_poll: function (d, a) {
      var sc = (a.p_session || '').toUpperCase(), se = d.sessions[sc];
      if (!se) return { error: 'not_found' };
      if (se.tok !== a.p_token) return { error: 'forbidden' };
      var out = {};
      sessionPlanes(d, sc).forEach(function (p) {
        tick(d, p); sweep(d, p.code);
        var since = parseInt((a.p_since || {})[p.code] || 0, 10) || 0;
        out[p.code] = {
          state: { phase: p.phase, timerEnd: p.timer_end, revealed: p.revealed, answer: p.answer, correct: p.correct, answeredBy: p.by },
          key: p.key, parts: pj(d, p.code),
          msgs: d.msgs.filter(function (m) { return m.plane === p.code && m.id > since; }).slice(0, 300).map(msgJson),
        };
      });
      return { planes: out, now: now(d) };
    },
    av_join: function (d, a) {
      var pc = (a.p_code || '').toUpperCase(), name = (a.p_name || '').trim();
      var p = d.planes[pc]; if (!p) return { error: 'not_found' };
      if (name.length < 1 || name.length > 30) return { error: 'bad_name' };
      tick(d, p);
      var x = me(d, pc, a.p_token);
      if (x) { x.name = name; x.last_seen = now(d); }
      else {
        if (p.phase === 'ended') return { error: 'ended' };
        if (p.phase === 'playing') return { error: 'started' };
        sweep(d, pc);
        if (partsOf(d, pc).length >= p.num) return { error: 'full' };
        d.pidn++; x = { id: 'pid-' + d.pidn + '-' + rnd(1e6), plane: pc, tok: a.p_token, name: name, role: null, seat: null, symbols: null, connected: now(d), last_seen: now(d), bot: false };
        d.parts[x.id] = x;
      }
      return { pid: x.id, role: x.role, now: now(d), meta: meta(p) };
    },
    av_leave: function () { return { ok: true }; },   // no modo teste, recarregar a página não tira ninguém da sala
    av_poll: function (d, a) {
      var pc = (a.p_code || '').toUpperCase(), x = me(d, pc, a.p_token);
      if (!x) return { error: 'not_member' };
      if (!x.bot) x.last_seen = now(d);
      var p = d.planes[pc]; tick(d, p); sweep(d, pc);
      var st = { phase: p.phase, timerEnd: p.timer_end, revealed: p.revealed, answered: p.answer != null };
      if (p.revealed) { st.answer = p.answer; st.correct = p.correct; st.answeredBy = p.by; st.key = p.key; }
      var since = parseInt(a.p_since || 0, 10) || 0;
      var ms = !x.role ? [] : d.msgs.filter(function (m) { return m.plane === pc && m.id > since && (m.t === x.role || m.f === x.role); }).slice(0, 300).map(msgJson);
      return { now: now(d), meta: meta(p), state: st, parts: pj(d, pc), me: { pid: x.id, role: x.role, seat: x.seat || null, symbols: x.symbols }, msgs: ms };
    },
    av_start: function (d, a) {
      var p = facPlane(d, a.p_token, a.p_code); if (!p) return { error: 'forbidden' };
      tick(d, p); sweep(d, p.code);
      if (p.phase !== 'lobby') return { error: 'bad_phase' };
      if (partsOf(d, p.code).length < 6) return { error: 'too_few', min: 6 };
      startCore(d, p); return { ok: true };
    },
    av_pick_seat: function (d, a) {
      var pc = (a.p_code || '').toUpperCase(), p = d.planes[pc]; if (!p) return { error: 'not_found' };
      var x = me(d, pc, a.p_token); if (!x) return { error: 'not_member' };
      if (p.phase !== 'lobby') return { error: 'not_lobby' };
      var r = a.p_role; if (!r) { x.seat = null; return { ok: true }; }
      if (ALL.slice(0, p.num).indexOf(r) < 0) return { error: 'bad_seat' };
      if (partsOf(d, pc).some(function (y) { return y.seat === r && y.id !== x.id; })) return { error: 'seat_taken' };
      x.seat = r; return { ok: true };
    },
    av_end: function (d, a) { var p = facPlane(d, a.p_token, a.p_code); if (!p) return { error: 'forbidden' }; if (p.phase === 'playing') p.phase = 'ended'; return { ok: true }; },
    av_reveal: function (d, a) { var p = facPlane(d, a.p_token, a.p_code); if (!p) return { error: 'forbidden' }; if (p.phase === 'ended') p.revealed = true; return { ok: true }; },
    av_send: function (d, a) {
      var pc = (a.p_code || '').toUpperCase(), x = me(d, pc, a.p_token); if (!x) return { error: 'not_member' };
      var p = d.planes[pc]; tick(d, p);
      if (p.phase !== 'playing') return { error: 'not_playing' };
      if (!x.role) return { error: 'no_role' };
      var t = (a.p_text || '').trim(); if (t.length < 1 || t.length > 500) return { error: 'bad_text' };
      var to = byRole(d, pc, a.p_to);
      if (!canSend(x.role, a.p_to || '') || !to) return { error: 'not_allowed' };
      addMsg(d, pc, x.role, a.p_to, t);
      var m = d.msgs[d.msgs.length - 1];
      if (d.auto && to.bot && online(d, to)) {
        d.pend.push({ plane: pc, f: to.role, t: x.role, due: now(d) + 1800 + rnd(2400), body: 'Na minha folha tem ' + sheetText(to) + '. E na sua?' });
      }
      return { ok: true, id: m.id, ts: m.ts };
    },
    av_answer: function (d, a) {
      var pc = (a.p_code || '').toUpperCase(), x = me(d, pc, a.p_token); if (!x) return { error: 'not_member' };
      var p = d.planes[pc]; tick(d, p);
      if (p.phase !== 'playing' || p.answer) return { error: 'not_playing' };
      if (x.role !== 'A') return { error: 'not_allowed' };
      if (SYMS.indexOf(a.p_symbol) < 0) return { error: 'bad_symbol' };
      p.answer = a.p_symbol; p.correct = a.p_symbol === p.key; p.by = 'A'; p.phase = 'ended';
      return { ok: true };
    },
  };
  function sessionPlanes(d, sc) {
    return Object.keys(d.planes).map(function (k) { return d.planes[k]; }).filter(function (p) { return p.session === sc; }).sort(function (a, b) { return a.idx - b.idx; });
  }

  // intercepta só as chamadas ao Supabase; o resto (fontes etc.) passa normalmente
  var realFetch = window.fetch.bind(window);
  window.fetch = function (url, opts) {
    var u = typeof url === 'string' ? url : (url && url.url) || '';
    if (u.indexOf(RPC) !== 0) return realFetch(url, opts);
    if (netFail) return Promise.reject(new TypeError('Failed to fetch (teste)'));
    var fn = u.slice(RPC.length).split('?')[0], args = {};
    try { args = JSON.parse((opts && opts.body) || '{}'); } catch (e) {}
    var d = load(), out;
    try {
      flush(d);
      out = api[fn] ? api[fn](d, args) : { error: 'unknown_fn' };
      save(d);
    } catch (e) { return Promise.resolve(new Response(JSON.stringify({ code: 'P0001', message: String(e) }), { status: 400, headers: { 'content-type': 'application/json' } })); }
    return new Promise(function (r) { setTimeout(function () { r(new Response(JSON.stringify(out), { status: 200, headers: { 'content-type': 'application/json' } })); }, 60); });
  };
  // recarregar para trocar de ponto de vista não deve abrir o aviso "sair da página?"
  window.addEventListener('beforeunload', function (e) { e.stopImmediatePropagation(); }, true);

  // ───────────────────────── montagem de cenários
  var STATES = [
    ['lobby0', 'Sala de espera vazia'],
    ['lobbyfree', 'Sala de espera com 1 vaga livre'],
    ['lobbyfull', 'Sala de espera completa'],
    ['play', 'Em andamento, com conversa'],
    ['play1', 'Em andamento, falta 1 minuto'],
    ['waiting', 'Encerrado, aguardando revelar'],
    ['rightRev', 'Resultado revelado: acertou'],
    ['wrongRev', 'Resultado revelado: errou'],
    ['noAnsRev', 'Encerrado sem resposta, revelado'],
  ];
  function wrongSym(p) { return SYMS.filter(function (s) { return s !== p.key; })[rnd(5)]; }
  function sampleChat(d, p) {
    var t0 = now(d), roles = partsOf(d, p.code).map(function (x) { return x.role; }), n = 0;
    function say(f, t, extra) {
      if (roles.indexOf(f) < 0 || roles.indexOf(t) < 0) return;
      var x = byRole(d, p.code, f); n++;
      addMsg(d, p.code, f, t, extra || ('Na minha folha tem ' + sheetText(x) + '. E na sua?'), t0 - (12 - n) * 25000);
    }
    say('B1', 'A'); say('A', 'B1', 'Anotei. Alguém mais tem ' + CH[p.key] + '?'); say('B2', 'A'); say('B1', 'B2', 'Vocês também têm ' + CH[p.key] + '?');
    say('C', 'B1'); say('B1', 'C', 'Obrigado, anotei.'); say('D', 'B2'); say('B2', 'D', 'Valeu! Vou cruzar com as outras folhas.');
    say('E', 'B1'); say('F', 'B2');
  }
  function build(o) {
    var d = fresh(), ft = window.facToken(), sc = mkCode({});
    d.sessions[sc] = { tok: ft, created: now(d) };
    for (var i = 0; i < o.planes; i++) {
      var pc = mkCode(d.planes);
      var p = d.planes[pc] = { code: pc, session: sc, idx: i, version: i % 5 + 1, key: SYMS[rnd(6)], num: o.people, timer: o.minutes, phase: 'lobby', timer_end: null, revealed: false, answer: null, correct: null, by: null };
      var n = o.state === 'lobby0' ? 0 : o.state === 'lobbyfree' ? o.people - 1 : o.people;
      for (var k = 0; k < n; k++) {
        d.pidn++; var id = 'pid-b' + d.pidn;
        d.parts[id] = { id: id, plane: pc, tok: botToken(), name: NAMES[k % NAMES.length], role: null, seat: null, symbols: null, connected: now(d) - (n - k) * 4000, last_seen: now(d), bot: true };
      }
      var bots = partsOf(d, pc);
      if (o.state.indexOf('lobby') === 0 && bots.length > 2) { bots[1].seat = 'C'; bots[2].seat = 'B1'; }
      if (o.state.indexOf('lobby') !== 0) {
        startCore(d, p);
        if (o.state === 'play1') p.timer_end = now(d) + 60000;
        sampleChat(d, p);
        if (o.state === 'waiting' || o.state === 'rightRev') { p.answer = p.key; p.correct = true; p.by = 'A'; p.phase = 'ended'; }
        if (o.state === 'wrongRev') { p.answer = wrongSym(p); p.correct = false; p.by = 'A'; p.phase = 'ended'; }
        if (o.state === 'noAnsRev') p.phase = 'ended';
        if (/Rev$/.test(o.state)) p.revealed = true;
      }
    }
    save(d); return sc;
  }
  function setView(kind, sc, pc, tok, name) {
    ['av_session', 'av_room', 'av_role', 'av_name', 'av_par_token'].forEach(function (k) { sessionStorage.removeItem(k); });
    if (kind === 'fac') {
      sessionStorage.setItem('av_session', sc); sessionStorage.setItem('av_role', 'fac');
      try { localStorage.setItem('av_fac_session', sc); } catch (e) {}
    } else {
      sessionStorage.setItem('av_par_token', tok); sessionStorage.setItem('av_room', pc);
      sessionStorage.setItem('av_role', 'par'); sessionStorage.setItem('av_name', name);
    }
    var u = new URL(location.href); u.searchParams.delete('code'); location.href = u.toString();
  }

  // ───────────────────────── painel
  var css = '.tm-btn{position:fixed;left:12px;bottom:12px;z-index:9000;display:inline-flex;align-items:center;gap:8px;min-height:40px;padding:0 14px;border:none;border-radius:999px;background:#B45309;color:#fff;font:800 13px Raleway,system-ui,sans-serif;cursor:pointer;box-shadow:0 6px 18px rgba(33,0,0,.3)}' +
    '.tm-btn::before{content:"";width:8px;height:8px;border-radius:50%;background:#FDE68A}' +
    '.tm-panel{position:fixed;left:12px;bottom:60px;z-index:9001;width:min(360px,calc(100vw - 24px));max-height:calc(100dvh - 80px);overflow:auto;background:#fff;color:#210000;border:1.5px solid #B45309;border-radius:16px;box-shadow:0 18px 50px rgba(33,0,0,.35);padding:14px 14px 16px;font:14px/1.45 Aptos,"Segoe UI",system-ui,sans-serif}' +
    '.tm-panel[hidden]{display:none}.tm-panel h2{font:800 16px Raleway,system-ui,sans-serif;color:#B45309;margin:0 0 2px}.tm-panel h3{font:800 13px Raleway,system-ui,sans-serif;color:#001B71;margin:14px 0 8px;padding-top:12px;border-top:1px solid #DDE3EC}' +
    '.tm-panel p{margin:0 0 6px;color:#5B6472;font-size:13px}.tm-row{display:flex;gap:8px;margin-bottom:8px}.tm-row>*{flex:1;min-width:0}' +
    '.tm-panel label{display:block;font-size:12px;font-weight:700;margin:0 0 3px;color:#210000}.tm-panel select,.tm-panel input[type=number]{width:100%;min-height:38px;padding:6px 8px;border:1.5px solid #C3CCD9;border-radius:8px;font:inherit;background:#fff;color:#210000}' +
    '.tm-b{min-height:38px;padding:6px 10px;border:1.5px solid #C3CCD9;border-radius:8px;background:#fff;color:#210000;font:800 12px Raleway,system-ui,sans-serif;cursor:pointer}.tm-b:hover{border-color:#007BEA}' +
    '.tm-b.p{background:#0067C9;border-color:#0067C9;color:#fff}.tm-b.w{border-color:#B91C1C;color:#B91C1C}.tm-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px}.tm-chk{display:flex;align-items:center;gap:8px;margin:8px 0 0;font-weight:600!important}' +
    '.tm-x{float:right;border:none;background:none;font-size:20px;line-height:1;cursor:pointer;color:#5B6472}';
  function el(h) { var t = document.createElement('div'); t.innerHTML = h.trim(); return t.firstChild; }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;'); }
  function say(m) { if (typeof window.toast === 'function') window.toast(m, 3500); }

  function mySession(d) {
    var ft; try { ft = window.facToken(); } catch (e) { return null; }
    var cur = sessionStorage.getItem('av_session'), list = Object.keys(d.sessions).filter(function (k) { return d.sessions[k].tok === ft; });
    return list.indexOf(cur) >= 0 ? cur : list[list.length - 1] || null;
  }

  function init() {
    var st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);
    var btn = el('<button class="tm-btn" type="button" aria-expanded="false" aria-controls="tmPanel">Modo teste</button>');
    var panel = el('<aside class="tm-panel" id="tmPanel" hidden aria-label="Modo teste"></aside>');
    document.body.appendChild(btn); document.body.appendChild(panel);
    btn.onclick = function () { panel.hidden = !panel.hidden; btn.setAttribute('aria-expanded', String(!panel.hidden)); if (!panel.hidden) render(); };

    function render() {
      var d = load(), sc = mySession(d), planes = sc ? sessionPlanes(d, sc) : [];
      var keepPlane = (panel.querySelector('#tmPlane') || {}).value, keepWho = (panel.querySelector('#tmWho') || {}).value;
      var h = '<button class="tm-x" type="button" aria-label="Fechar" id="tmClose">×</button><h2>Modo teste</h2>' +
        '<p>Dados simulados neste navegador. Nada é enviado ao Supabase.</p>' +
        '<h3>Montar cenário</h3>' +
        '<div class="tm-row"><div><label for="tmPl">Aviões</label><select id="tmPl"><option>1</option><option>2</option><option>3</option></select></div>' +
        '<div><label for="tmPe">Pessoas por avião</label><select id="tmPe">' + [6, 7, 8, 9, 10, 11].map(function (n) { return '<option' + (n === 8 ? ' selected' : '') + '>' + n + '</option>'; }).join('') + '</select></div>' +
        '<div><label for="tmMin">Minutos</label><input id="tmMin" type="number" min="0" max="90" value="15"></div></div>' +
        '<label for="tmState">Estado</label><select id="tmState">' + STATES.map(function (s) { return '<option value="' + s[0] + '"' + (s[0] === 'play' ? ' selected' : '') + '>' + s[1] + '</option>'; }).join('') + '</select>' +
        '<div style="margin-top:8px"><button class="tm-b p" style="width:100%" id="tmBuild" type="button">Montar e abrir como facilitação</button></div>';
      if (sc) {
        h += '<h3>Ver como</h3><div class="tm-row"><div><label for="tmPlane">Avião</label><select id="tmPlane">' +
          planes.map(function (p, i) { return '<option value="' + p.code + '">Avião ' + (i + 1) + ' · ' + p.code + '</option>'; }).join('') + '</select></div>' +
          '<div><label for="tmWho">Quem</label><select id="tmWho"></select></div></div>' +
          '<div class="tm-grid"><button class="tm-b" id="tmView" type="button">Abrir</button><button class="tm-b" id="tmTab" type="button">Link do avião em nova aba</button></div>' +
          '<p style="margin-top:6px">Dica: abra duas abas (facilitação e uma pessoa) e veja as duas se atualizando.</p>' +
          '<h3>Ações no avião selecionado</h3><div class="tm-grid">' +
          '<button class="tm-b" data-a="fill" type="button">Encher a sala</button><button class="tm-b" data-a="start" type="button">Iniciar</button>' +
          '<button class="tm-b" data-a="chat" type="button">Mensagens de exemplo</button><button class="tm-b" data-a="off" type="button">Alternar alguém offline</button>' +
          '<button class="tm-b" data-a="right" type="button">A responde certo</button><button class="tm-b" data-a="wrong" type="button">A responde errado</button>' +
          '<button class="tm-b" data-a="t1" type="button">Avançar 1 min</button><button class="tm-b" data-a="left1" type="button">Faltar 1 min</button>' +
          '<button class="tm-b w" data-a="end" type="button">Encerrar</button><button class="tm-b" data-a="reveal" type="button">Revelar resultado</button></div>' +
          '<label class="tm-chk"><input type="checkbox" id="tmAuto"' + (d.auto ? ' checked' : '') + '> Pessoas simuladas respondem às mensagens</label>' +
          '<label class="tm-chk"><input type="checkbox" id="tmNet"' + (netFail ? ' checked' : '') + '> Simular queda de conexão (só esta aba)</label>';
      }
      h += '<h3>Outros</h3><div class="tm-grid"><button class="tm-b w" id="tmReset" type="button">Apagar dados do teste</button><button class="tm-b" id="tmExit" type="button">Sair do modo teste</button></div>';
      panel.innerHTML = h;
      var q = function (s) { return panel.querySelector(s); };
      q('#tmClose').onclick = function () { btn.click(); };
      q('#tmBuild').onclick = function () {
        var sc2 = build({ planes: +q('#tmPl').value, people: +q('#tmPe').value, minutes: Math.max(0, Math.min(90, +q('#tmMin').value || 0)), state: q('#tmState').value });
        setView('fac', sc2);
      };
      q('#tmReset').onclick = function () { localStorage.removeItem(KEY); ['av_session', 'av_room', 'av_role', 'av_name', 'av_par_token'].forEach(function (k) { sessionStorage.removeItem(k); }); try { localStorage.removeItem('av_fac_session'); } catch (e) {} var u = new URL(location.href); u.searchParams.delete('code'); location.href = u.toString(); };
      q('#tmExit').onclick = function () { var u = new URL(location.href); u.searchParams.delete('teste'); u.searchParams.delete('code'); location.href = u.toString(); };
      if (!sc) return;
      var selPlane = q('#tmPlane'); if (keepPlane && planes.some(function (p) { return p.code === keepPlane; })) selPlane.value = keepPlane;
      function fillWho() {
        var dd = load(), pc = selPlane.value, list = partsOf(dd, pc).sort(function (a, b) { return (ALL.indexOf(a.role || a.seat) < 0 ? 99 : ALL.indexOf(a.role || a.seat)) - (ALL.indexOf(b.role || b.seat) < 0 ? 99 : ALL.indexOf(b.role || b.seat)) || a.connected - b.connected; });
        q('#tmWho').innerHTML = '<option value="fac">Facilitação</option>' + list.map(function (x) { return '<option value="' + x.id + '">' + esc(x.name) + (x.role ? ' · Pessoa ' + x.role : x.seat ? ' · assento ' + x.seat : '') + '</option>'; }).join('');
        if (keepWho && q('#tmWho').querySelector('option[value="' + keepWho + '"]')) q('#tmWho').value = keepWho;
      }
      fillWho(); selPlane.onchange = function () { keepWho = null; fillWho(); };
      q('#tmView').onclick = function () {
        var dd = load(), v = q('#tmWho').value;
        if (v === 'fac') return setView('fac', sc);
        var x = dd.parts[v]; if (x) setView('par', sc, x.plane, x.tok, x.name);
      };
      q('#tmTab').onclick = function () { var u = new URL(location.href); u.searchParams.set('code', selPlane.value); window.open(u.toString(), '_blank'); };
      q('#tmAuto').onchange = function (e) { var dd = load(); dd.auto = e.target.checked; save(dd); };
      q('#tmNet').onchange = function (e) { netFail = e.target.checked; say(netFail ? 'Conexão simulada como fora do ar.' : 'Conexão restabelecida.'); };
      panel.querySelectorAll('[data-a]').forEach(function (b) {
        b.onclick = function () { act(b.getAttribute('data-a'), selPlane.value); setTimeout(render, 50); };
      });
    }

    function act(a, pc) {
      var d = load(), p = d.planes[pc]; if (!p) return;
      var ps = partsOf(d, pc), msg = '';
      if (a === 'fill') {
        var add = p.num - ps.length; if (p.phase !== 'lobby') msg = 'Só dá para encher a sala antes de iniciar.';
        else if (add <= 0) msg = 'A sala já está completa.';
        else {
          var usedNames = ps.map(function (x) { return x.name; });
          for (var i = 0; i < add; i++) {
            d.pidn++; var nm = NAMES.filter(function (n) { return usedNames.indexOf(n) < 0; })[0] || ('Pessoa ' + d.pidn); usedNames.push(nm);
            var id = 'pid-b' + d.pidn; d.parts[id] = { id: id, plane: pc, tok: botToken(), name: nm, role: null, seat: null, symbols: null, connected: now(d), last_seen: now(d), bot: true };
          }
          msg = add + (add === 1 ? ' pessoa simulada entrou.' : ' pessoas simuladas entraram.');
        }
      } else if (a === 'start') {
        if (p.phase !== 'lobby') msg = 'Este avião já foi iniciado.'; else if (ps.length < 6) msg = 'Faltam pessoas: use "Encher a sala".'; else { startCore(d, p); msg = 'Avião iniciado.'; }
      } else if (a === 'chat') {
        if (p.phase === 'lobby') msg = 'Inicie o avião primeiro.'; else { sampleChat(d, p); msg = 'Mensagens de exemplo adicionadas.'; }
      } else if (a === 'off') {
        var bots = ps.filter(function (x) { return x.bot; });
        if (!bots.length) msg = 'Não há pessoas simuladas neste avião.';
        else { var tgt = bots.filter(function (x) { return x.off; })[0] || bots[rnd(bots.length)]; tgt.off = !tgt.off; msg = tgt.name + (tgt.off ? ' ficou offline.' : ' voltou a ficar online.'); }
      } else if (a === 'right' || a === 'wrong') {
        if (p.phase !== 'playing') msg = 'O avião precisa estar em andamento.';
        else { p.answer = a === 'right' ? p.key : wrongSym(p); p.correct = a === 'right'; p.by = 'A'; p.phase = 'ended'; msg = 'A enviou a resposta (' + (a === 'right' ? 'certa' : 'errada') + ').'; }
      } else if (a === 't1') { d.skew += 60000; msg = 'Relógio adiantado em 1 minuto.'; }
      else if (a === 'left1') {
        if (p.phase !== 'playing') msg = 'O avião precisa estar em andamento.'; else { p.timer_end = now(d) + 60000; msg = 'Falta 1 minuto.'; }
      } else if (a === 'end') {
        if (p.phase === 'playing') { p.phase = 'ended'; msg = 'Avião encerrado.'; } else msg = 'O avião não está em andamento.';
      } else if (a === 'reveal') {
        if (p.phase === 'ended') { p.revealed = true; msg = 'Resultado revelado ao grupo.'; } else msg = 'Encerre o avião antes de revelar.';
      }
      save(d); say(msg);
    }

    // abre já com o painel visível na primeira vez
    try { if (!sessionStorage.getItem('av_teste_seen')) { sessionStorage.setItem('av_teste_seen', '1'); btn.click(); } } catch (e) {}
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
