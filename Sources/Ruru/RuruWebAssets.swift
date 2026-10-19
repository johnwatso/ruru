/// Static assets for the browser console, following the approved web mockup: a
/// floating sidebar, a dusk-landscape status banner, summary cards, a monitors
/// table, recent events and quick actions. Appearance follows the system with a
/// manual light/dark switch. Everything is served from `'self'`: no inline
/// script or style, no third-party assets, and all dynamic text is inserted
/// with `textContent`. Only live data is shown; nothing is placeholder content.
enum RuruWebAssets {
    static let page = #"""
    <!doctype html>
    <html lang=en>
    <head>
    <meta charset=utf-8>
    <meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name=color-scheme content="light dark">
    <title>Ruru</title>
    <link rel=stylesheet href="/web/app.css">
    </head>
    <body>
    <main id=login class=login hidden>
      <section class="card login-card">
        <div class=owl><img src="/web/ruru.png" alt="Ruru" width=64 height=64></div>
        <h1>ruru</h1>
        <p class=muted id=loginMessage>Checking secure access…</p>
        <button class="primary block" id=signIn hidden>Unlock with Passkey</button>
        <details id=firstTime>
          <summary>First time here?</summary>
          <p class=muted>Enter the one-time code shown in Ruru’s native console, or the code your owner shared with you.</p>
          <input id=email type=email autocomplete=email placeholder="Your email (first owner only)" aria-label="Your email">
          <input id=code autocomplete=one-time-code placeholder="Enrolment code" aria-label="Enrolment code">
          <button class=block id=enrol>Register Passkey</button>
        </details>
      </section>
    </main>

    <div class=app id=app hidden>
      <aside class=sidebar>
        <div class=brand>
          <div class=owl><img src="/web/ruru.png" alt="Ruru" width=64 height=64></div>
          <div><div class=wordmark>ruru <span class=beta>Beta</span></div><p class=muted>Keep an eye on what matters.</p></div>
        </div>
        <nav aria-label=Ruru>
          <a href="#overview" data-page=overview><svg viewBox="0 0 24 24"><path d="M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10"/></svg>Overview</a>
          <a href="#guarding" data-page=guarding><svg viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 4.5-3.2 8-8 9-4.8-1-8-4.5-8-9V6z"/><path d="M8.5 12l2.5 2.5L15.5 10"/></svg>Guarding</a>
          <a href="#monitors" data-page=monitors><svg viewBox="0 0 24 24"><path d="M3 12h4l3-8 4 16 3-8h4"/></svg>Monitors</a>
          <a href="#operators" data-page=operators id=operatorsLink hidden><svg viewBox="0 0 24 24"><circle cx=9 cy=8 r=3.5 /><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14.5a6.5 6.5 0 0 1 3.5 5.5"/></svg>Operators</a>
        </nav>
        <div class=spacer></div>
        <div class="sidecard" id=sideStatus></div>
        <div class=sidebar-foot>
          <label class=switch><svg viewBox="0 0 24 24"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z"/></svg><span>Dark Mode</span><input type=checkbox id=darkToggle role=switch><i aria-hidden=true></i></label>
          <button class=link id=logout><svg viewBox="0 0 24 24"><path d="M10 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h5M16 8l4 4-4 4M20 12H9"/></svg>Sign Out</button>
        </div>
      </aside>
      <main class=main id=main></main>
    </div>

    <div class=scrim id=scrim hidden>
      <section class=sheet role=dialog aria-modal=true aria-labelledby=sheetTitle>
        <header><h2 id=sheetTitle></h2><button class=plain id=sheetClose aria-label=Close>Done</button></header>
        <div id=sheetBody></div>
      </section>
    </div>
    <div class=toast id=toast role=status hidden></div>
    <script src="/web/app.js"></script>
    </body>
    </html>
    """#

    static let stylesheet = #"""
    :root{color-scheme:light;--page:linear-gradient(180deg,#7a7fb3 0%,#a9a6c9 45%,#58648f 100%);--panel:#ffffff;--panel-2:#f6f6fb;--sidebar:#fbfbfe;--line:#ebebf3;--text:#1b1b30;--muted:#6c6c88;--accent:#6d5ef0;--accent-soft:#ecebfe;--ok:#16a34a;--ok-soft:#e3f6ea;--bad:#e5484d;--bad-soft:#fdeaea;--warn:#e8890c;--warn-soft:#fff1de;--idle:#7d7d96;--idle-soft:#efeff5;--field:#f4f4fa;--shadow:0 10px 30px rgba(40,40,90,.12)}
    @media (prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--page:linear-gradient(180deg,#232a4a 0%,#1a1d33 55%,#13152a 100%);--panel:#1d2033;--panel-2:#252940;--sidebar:#1a1c30;--line:#2d3150;--text:#eef0fb;--muted:#9ea3c4;--accent:#8a7dff;--accent-soft:#2a2a52;--ok:#3ddc84;--ok-soft:#173a2a;--bad:#ff6b70;--bad-soft:#42212a;--warn:#ffb347;--warn-soft:#41311a;--idle:#9a9ebd;--idle-soft:#2b2f48;--field:#252940;--shadow:0 10px 30px rgba(0,0,0,.4)}}
    :root[data-theme=dark]{color-scheme:dark;--page:linear-gradient(180deg,#232a4a 0%,#1a1d33 55%,#13152a 100%);--panel:#1d2033;--panel-2:#252940;--sidebar:#1a1c30;--line:#2d3150;--text:#eef0fb;--muted:#9ea3c4;--accent:#8a7dff;--accent-soft:#2a2a52;--ok:#3ddc84;--ok-soft:#173a2a;--bad:#ff6b70;--bad-soft:#42212a;--warn:#ffb347;--warn-soft:#41311a;--idle:#9a9ebd;--idle-soft:#2b2f48;--field:#252940;--shadow:0 10px 30px rgba(0,0,0,.4)}
    *{box-sizing:border-box}
    html,body{margin:0;min-height:100%}
    body{background:var(--page) fixed;color:var(--text);font:15px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    [hidden]{display:none!important}
    h1,h2,h3,p{margin:0}
    .muted{color:var(--muted)}
    svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round;flex:none}

    button,input,select{font:inherit;color:inherit}
    button{cursor:pointer;border:1px solid var(--line);background:var(--panel);padding:9px 16px;border-radius:12px;transition:background .15s,transform .1s}
    button:hover{background:var(--panel-2)}
    button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible,a:focus-visible,.row:focus-visible,.switch:focus-within{outline:2px solid var(--accent);outline-offset:2px}
    button.primary{background:var(--accent);border-color:transparent;color:#fff;font-weight:600;display:inline-flex;align-items:center;gap:8px}
    button.primary:hover{filter:brightness(1.08);background:var(--accent)}
    button.danger{color:var(--bad)}
    button.plain,button.link{background:none;border:0;padding:6px 8px;color:var(--accent)}
    button.block{display:block;width:100%;margin-top:12px}
    button:disabled{opacity:.5;cursor:default}
    input[type=text],input[type=email],input[type=number],input[type=search],input:not([type]),select{width:100%;padding:10px 12px;border-radius:12px;border:1px solid var(--line);background:var(--field);margin-top:6px}
    label{display:block;margin-top:14px;font-size:.85rem;color:var(--muted)}
    .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    .grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}

    .card{background:var(--panel);border-radius:22px;box-shadow:var(--shadow)}
    .login{min-height:100vh;display:grid;place-items:center;padding:24px}
    .login-card{width:min(400px,100%);padding:32px;text-align:center}
    .login-card .owl{width:64px;height:64px;margin:0 auto 10px}
    .login-card h1{font-size:2rem;letter-spacing:.02em;font-weight:800}
    .login-card .muted{margin-top:6px}
    .login-card details{margin-top:18px;text-align:left}
    .login-card summary{cursor:pointer;color:var(--muted);text-align:center}

    .owl{border-radius:22%;background:linear-gradient(160deg,#bc8cf8,#778af7);display:grid;place-items:center;box-shadow:0 4px 12px rgba(80,60,160,.3);overflow:hidden}
    .owl img{width:82%;height:82%;object-fit:contain;display:block;margin-top:-4%}
    @media (prefers-color-scheme:dark){:root:not([data-theme=light]) .owl{background:linear-gradient(160deg,#7b4f8d,#4c4789)}}
    :root[data-theme=dark] .owl{background:linear-gradient(160deg,#7b4f8d,#4c4789)}

    .app{display:grid;grid-template-columns:272px minmax(0,1fr);gap:0;margin:20px;min-height:calc(100vh - 40px);background:var(--panel);border-radius:30px;box-shadow:0 24px 70px rgba(10,10,40,.35);overflow:hidden}
    .sidebar{background:var(--sidebar);padding:24px 16px 16px;display:flex;flex-direction:column;gap:6px;border-right:1px solid var(--line)}
    .brand{display:flex;gap:12px;align-items:center;padding:0 8px 22px}
    .brand .owl{width:52px;height:52px;flex:none}
    .wordmark{font-size:1.9rem;font-weight:800;letter-spacing:.01em;line-height:1.1;display:flex;align-items:center;gap:8px}
    .beta{font-size:.7rem;font-weight:600;letter-spacing:0;padding:3px 8px;border-radius:99px;background:var(--accent-soft);color:var(--accent)}
    .brand p{font-size:.85rem;margin-top:4px}
    .sidebar nav{display:flex;flex-direction:column;gap:4px}
    .sidebar nav a{display:flex;align-items:center;gap:14px;padding:12px 14px;border-radius:14px;color:var(--text);text-decoration:none;font-weight:500}
    .sidebar nav a svg{color:var(--muted);width:22px;height:22px}
    .sidebar nav a:hover{background:var(--panel-2)}
    .sidebar nav a[aria-current=page]{background:var(--accent-soft);color:var(--accent);font-weight:600}
    .sidebar nav a[aria-current=page] svg{color:var(--accent)}
    .spacer{flex:1;min-height:20px}
    .sidecard{display:flex;align-items:center;gap:12px;padding:14px;border-radius:16px;background:var(--panel-2);border:1px solid var(--line)}
    .sidecard b{display:block;font-size:.95rem}
    .sidecard span.muted{font-size:.82rem}
    .dot{width:10px;height:10px;border-radius:50%;background:var(--idle);flex:none;box-shadow:0 0 0 4px var(--idle-soft)}
    .dot.ok{background:var(--ok);box-shadow:0 0 0 4px var(--ok-soft)}.dot.bad{background:var(--bad);box-shadow:0 0 0 4px var(--bad-soft)}.dot.warn{background:var(--warn);box-shadow:0 0 0 4px var(--warn-soft)}
    .sidebar-foot{display:flex;flex-direction:column;gap:4px;margin-top:10px}
    .switch{position:relative;display:flex;align-items:center;gap:12px;padding:8px 10px;margin:0;border-radius:14px;color:var(--text);font-size:.92rem;cursor:pointer}
    .switch svg{color:var(--muted);width:20px;height:20px}
    .switch span{flex:1}
    .switch input{position:absolute;opacity:0;inset:0;width:100%;height:100%;margin:0;cursor:pointer}
    .switch i{width:44px;height:26px;border-radius:99px;background:var(--idle-soft);border:1px solid var(--line);position:relative;transition:background .2s}
    .switch i::after{content:"";position:absolute;left:2px;top:2px;width:20px;height:20px;border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.3);transition:transform .2s}
    .switch input:checked~i{background:var(--accent)}
    .switch input:checked~i::after{transform:translateX(18px)}
    .sidebar-foot button.link{display:flex;align-items:center;gap:12px;color:var(--muted);text-align:left;padding:8px 10px}
    .sidebar-foot button.link svg{width:20px;height:20px}

    .main{background:var(--panel-2);padding:0 0 28px;min-width:0}
    .hero{position:relative;overflow:hidden;color:#fff;padding:60px 48px 100px;min-height:230px;display:flex;align-items:flex-start;justify-content:space-between;gap:20px;flex-wrap:wrap}
    .hero>svg.art{position:absolute;inset:0;width:100%;height:100%;stroke:none;z-index:0}
    .hero>*:not(svg.art){position:relative;z-index:1}
    .hero h1{font-size:clamp(2rem,4.4vw,3.1rem);font-weight:700;letter-spacing:-.02em;display:flex;align-items:center;gap:16px}
    .hero h1 .dot{width:18px;height:18px;box-shadow:0 0 14px currentColor}
    .hero p{margin-top:8px;font-size:1.1rem;opacity:.9}
    .running{display:flex;align-items:center;gap:14px;padding:14px 18px;min-width:250px;border-radius:16px;background:rgba(20,22,48,.55);border:1px solid rgba(255,255,255,.18);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px)}
    .running .shield{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;background:rgba(61,220,132,.2);color:#3ddc84}
    .running .shield svg{width:24px;height:24px}
    .running.bad .shield{background:rgba(255,107,112,.22);color:#ff8a8f}
    .running b{display:block}.running span{font-size:.85rem;opacity:.8}

    .body{padding:0 36px;margin:-62px auto 0;max-width:1180px;position:relative;display:flex;flex-direction:column;gap:32px}
    .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px}
    .stat{display:flex;align-items:center;gap:16px;padding:22px 22px;text-align:left;border-radius:18px;background:var(--panel);border:0;box-shadow:var(--shadow);color:var(--text)}
    .stat:hover{background:var(--panel)}
    .stat .tile{width:50px;height:50px;border-radius:50%}
    .stat .meta{flex:1;min-width:0}
    .stat .label{font-size:.88rem;color:var(--muted)}
    .stat strong{display:block;font-size:1.85rem;line-height:1.15;font-weight:700;font-variant-numeric:tabular-nums}
    .stat .note{font-size:.82rem;color:var(--muted)}
    .stat .go{color:var(--muted);width:16px;height:16px}
    .tile{display:grid;place-items:center;border-radius:12px;background:var(--accent-soft);color:var(--accent);width:40px;height:40px;flex:none}
    .tile.ok{background:var(--ok-soft);color:var(--ok)}.tile.bad{background:var(--bad-soft);color:var(--bad)}.tile.warn{background:var(--warn-soft);color:var(--warn)}.tile.idle{background:var(--idle-soft);color:var(--idle)}.tile.teal{background:#dff5f3;color:#0f9d8f}.tile.pink{background:#fde8f1;color:#d6336c}
    @media (prefers-color-scheme:dark){:root:not([data-theme=light]) .tile.teal{background:#163a38;color:#4fd1c5}:root:not([data-theme=light]) .tile.pink{background:#3f2030;color:#ff7aa8}}
    :root[data-theme=dark] .tile.teal{background:#163a38;color:#4fd1c5}:root[data-theme=dark] .tile.pink{background:#3f2030;color:#ff7aa8}

    .columns{display:grid;grid-template-columns:minmax(0,1.8fr) minmax(300px,1fr);gap:32px;align-items:start}
    .side-col{display:flex;flex-direction:column;gap:32px}
    .section{padding:26px 28px;display:flex;flex-direction:column;gap:20px}
    .section>header{display:flex;justify-content:space-between;align-items:center;gap:12px}
    .section h2{font-size:1.2rem;font-weight:700}
    .section .tools{display:flex;gap:10px;align-items:center}
    .search{position:relative;display:flex;align-items:center;margin:0}
    .search svg{position:absolute;left:10px;color:var(--muted);width:16px;height:16px;pointer-events:none}
    .search input{margin:0!important;padding-left:34px!important;width:180px!important}
    .link-btn{background:none;border:0;padding:0;color:var(--accent);font-size:.9rem}
    .link-btn:hover{background:none;text-decoration:underline}

    .table{display:flex;flex-direction:column}
    .table .head,.table .row{display:grid;grid-template-columns:minmax(0,2.2fr) 70px 104px 84px 84px;align-items:center;gap:16px;padding:14px 16px}
    .table.compact .head,.table.compact .row{grid-template-columns:minmax(0,2fr) minmax(0,1.2fr) 104px}
    .table .head{background:var(--panel-2);border-radius:12px;font-size:.82rem;color:var(--muted);font-weight:600}
    .table .row{width:100%;border:0;border-bottom:1px solid var(--line);border-radius:0;background:none;text-align:left}
    .table .row:last-child{border-bottom:0}
    .table .row.simple{grid-template-columns:minmax(0,1fr) auto;cursor:default}
    .table .row.simple:hover{background:none}
    .table .row:hover{background:var(--panel-2)}
    .cell-name{display:flex;align-items:center;gap:12px;min-width:0}
    .cell-name b,.cell-name div span{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .cell-name div span{font-size:.82rem;color:var(--muted)}
    .cell-name>div{min-width:0}
    .num{font-variant-numeric:tabular-nums}
    .pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:99px;font-size:.82rem;font-weight:600;background:var(--idle-soft);color:var(--idle);white-space:nowrap;width:max-content}
    .pill.dotted::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
    .pill.ok{background:var(--ok-soft);color:var(--ok)}.pill.bad{background:var(--bad-soft);color:var(--bad)}.pill.warn{background:var(--warn-soft);color:var(--warn)}
    .pill.type{border-radius:8px;background:var(--panel-2);color:var(--muted);font-size:.74rem;border:1px solid var(--line)}

    .events{display:flex;flex-direction:column}
    .event{display:flex;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid var(--line)}
    .event:last-child{border-bottom:0}
    .event .dot{width:9px;height:9px;box-shadow:none}
    .event .tile{width:36px;height:36px;border-radius:50%}
    .event .text{flex:1;min-width:0}
    .event b{display:block;font-size:.92rem;font-weight:600}
    .event .sub{display:block;font-size:.8rem;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .event time{font-size:.8rem;color:var(--muted);white-space:nowrap}

    .quick{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    .quick button{display:flex;align-items:center;gap:12px;padding:12px;text-align:left;border-radius:14px;background:var(--panel);border:1px solid var(--line);font-size:.92rem}
    .quick button .tile{width:36px;height:36px;border-radius:50%}
    .quick button:hover{background:var(--panel-2)}

    .svc-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:24px}
    .svc{padding:26px;display:flex;flex-direction:column;gap:22px}
    .svc header{display:flex;align-items:center;gap:12px}
    .svc header h3{font-size:1.1rem;font-weight:700;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .svc .owner{display:flex;align-items:center;gap:16px}
    .svc .owner .who{flex:1;min-width:0}
    .svc .owner .who span{font-size:.82rem;color:var(--muted)}
    .svc .owner .who b{display:block;font-size:1.15rem;overflow-wrap:anywhere}
    .term{font:600 1.5rem ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.06em;font-variant-numeric:tabular-nums}
    .ring{width:64px;height:64px;position:relative;flex:none}
    .ring svg{width:64px;height:64px;transform:rotate(-90deg);stroke-width:5}
    .ring .track{stroke:var(--idle-soft)}.ring .arc{stroke:var(--ok)}.ring.late .arc{stroke:var(--warn)}.ring.urgent .arc{stroke:var(--bad)}
    .ring b{position:absolute;inset:0;display:grid;place-items:center;font-size:.8rem;font-variant-numeric:tabular-nums}
    .svc .sub{font-size:.82rem;color:var(--muted)}
    .svc ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:6px;font-size:.88rem}
    .svc ul li{display:flex;justify-content:space-between;gap:10px}
    .svc ul li span:last-child{color:var(--muted);white-space:nowrap}
    .svc h4{margin:0 0 6px;font-size:.78rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:600}
    .notice{padding:12px 14px;border-radius:12px;background:var(--warn-soft);color:var(--text);font-size:.9rem}
    .empty{display:flex;flex-direction:column;align-items:center;gap:8px;padding:28px 12px;text-align:center}
    .empty svg{width:30px;height:30px;color:var(--muted)}
    .page-top{padding:40px 36px 0;max-width:1180px;margin:0 auto;width:100%;display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap}
    .page-top h1{font-size:2rem;font-weight:700;letter-spacing:-.01em}
    .page-top p{margin-top:6px}
    .page-body{padding:28px 36px 0;display:flex;flex-direction:column;gap:28px;max-width:1180px;margin:0 auto;width:100%}

    .scrim{position:fixed;inset:0;z-index:10;background:rgba(10,12,30,.5);display:grid;place-items:center;padding:20px}
    .sheet{width:min(520px,100%);max-height:calc(100vh - 40px);overflow:auto;border-radius:24px;padding:22px;background:var(--panel);box-shadow:0 30px 80px rgba(0,0,0,.45)}
    .sheet>header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
    .sheet h2{font-size:1.25rem;font-weight:700}
    .inset{margin:14px 0;border-radius:16px;background:var(--panel-2);list-style:none;padding:0;border:1px solid var(--line)}
    .inset li{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:10px 14px}
    .inset li+li{border-top:1px solid var(--line)}
    .inset li span:first-child{color:var(--muted)}
    .inset li span:last-child{text-align:right;overflow-wrap:anywhere}
    .spark{display:block;width:100%;height:56px;color:var(--accent)}
    .actions{display:flex;gap:10px;margin-top:16px}
    .actions button{flex:1}
    .code{font:600 1.05rem ui-monospace,SFMono-Regular,Menlo,monospace;padding:12px;border-radius:12px;background:var(--field);overflow-wrap:anywhere;margin-top:10px;letter-spacing:.04em}
    .toast{position:fixed;left:50%;top:16px;transform:translateX(-50%);z-index:20;padding:11px 16px;border-radius:12px;background:#2b2e4a;color:#fff;max-width:calc(100vw - 32px);box-shadow:0 8px 24px rgba(0,0,0,.3)}

    @media (max-width:1100px){.columns{grid-template-columns:1fr}}
    @media (max-width:860px){
      .body,.page-body,.page-top{padding-left:16px;padding-right:16px}
      .section{padding:20px}
      .hero{padding:32px 20px 90px}
      .table.compact .head,.table.compact .row{grid-template-columns:minmax(0,1fr) auto}
      .app{grid-template-columns:1fr;margin:0;border-radius:0;min-height:100vh}
      .sidebar{flex-direction:row;flex-wrap:wrap;align-items:center;padding:12px;border-right:0;border-bottom:1px solid var(--line)}
      .brand{padding:0;flex:1 1 100%}.brand p{display:none}
      .sidebar nav{flex-direction:row;flex:1}.sidebar nav a{padding:8px 12px}
      .spacer,.sidecard{display:none}.sidebar-foot{flex-direction:row;margin:0}.switch span{display:none}
      .sidebar-foot button.link{font-size:0;gap:0}
      .hero{padding:32px 20px 80px}.body,.page-body{padding-left:16px;padding-right:16px}.page-top{padding:24px 16px 0}
      .table .head{display:none}
      .table .row{grid-template-columns:minmax(0,1fr) auto;gap:6px}
      .table .row .hide-sm{display:none}
      .grid2,.grid3,.quick{grid-template-columns:1fr}
    }
    @media (prefers-reduced-motion:reduce){*{transition:none!important}}
    """#

    static let script = #"""
    'use strict';
    const $ = (selector) => document.querySelector(selector);
    const state = { csrf: '', monitors: [], service: { running: false, startedAt: null }, guarded: [], guardedAt: 0, role: null, timer: null, filter: '' };
    const pages = { overview: renderOverview, guarding: renderGuarding, monitors: renderMonitors, operators: renderOperators };

    // MARK: Helpers

    const b64 = (text) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(text.length / 4) * 4, '=')), (c) => c.charCodeAt(0));
    const enc = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const adapt = (options) => {
      options.challenge = b64(options.challenge);
      if (options.user) options.user.id = b64(options.user.id);
      for (const item of options.allowCredentials || []) item.id = b64(item.id);
      for (const item of options.excludeCredentials || []) item.id = b64(item.id);
      return options;
    };
    const credentialJSON = (c) => ({
      id: c.id, rawId: enc(c.rawId), type: c.type, authenticatorAttachment: c.authenticatorAttachment,
      response: Object.fromEntries(['clientDataJSON', 'attestationObject', 'authenticatorData', 'signature', 'userHandle']
        .filter((key) => c.response[key]).map((key) => [key, enc(c.response[key])])),
    });

    async function api(path, { method = 'GET', body } = {}) {
      const headers = {};
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      if (method !== 'GET') headers['X-Ruru-CSRF'] = state.csrf;
      const response = await fetch(path, { method, headers, credentials: 'same-origin', body: body === undefined ? undefined : JSON.stringify(body) });
      const json = await response.json().catch(() => ({}));
      if (!response.ok) throw Object.assign(new Error(json.error || 'request_failed'), { status: response.status });
      return json;
    }

    const friendly = {
      passkey_required: 'Unlock with your passkey first.', passkey_not_enrolled: 'No passkey is registered for this account.',
      enrollment_code_required: 'That enrolment code is missing, wrong or expired.', email_required: 'Enter your email address to register the first passkey.', too_many_attempts: 'Too many attempts. Wait a minute and try again.', operator_already_enrolled: 'This operator already has a passkey.',
      tunnel_required: 'Ruru only accepts this page through its tunnel.', invalid_monitor: 'That monitor could not be saved. Check the details.',
      monitor_target_not_permitted: 'Use a numeric, non-local IP address for a web-console monitor.',
      owner_required: 'Only the owner can do that.', web_ui_unavailable: 'The web console is not enabled yet.',
      passkey_authentication_failed: 'Passkey sign-in failed.', passkey_registration_failed: 'Passkey registration failed.',
      invalid_operator_invitation: 'That email cannot be invited. It may already have access.', too_many_operators: 'The operator limit has been reached.',
    };
    const say = (error) => friendly[error.message] || (error.message || 'Something went wrong.').replace(/_/g, ' ');

    function toast(message) {
      const box = $('#toast');
      box.textContent = message; box.hidden = false;
      clearTimeout(toast.timer);
      toast.timer = setTimeout(() => { box.hidden = true; }, 4500);
    }

    function el(tag, props = {}, ...children) {
      const { dataset, ...rest } = props;
      const node = Object.assign(document.createElement(tag), rest);
      if (dataset) Object.assign(node.dataset, dataset);
      node.append(...children.filter((child) => child !== null && child !== undefined && child !== false));
      return node;
    }

    const svgNS = 'http://www.w3.org/2000/svg';
    function icon(paths, className) {
      const svg = document.createElementNS(svgNS, 'svg');
      svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
      if (className) svg.setAttribute('class', className);
      for (const d of paths) { const path = document.createElementNS(svgNS, 'path'); path.setAttribute('d', d); svg.append(path); }
      return svg;
    }
    const icons = {
      pulse: ['M3 12h4l3-8 4 16 3-8h4'], check: ['M5 12.5l4.5 4.5L19 7.5'], alert: ['M12 4l9 16H3z', 'M12 10v4M12 17.5v.5'],
      pause: ['M9 6v12M15 6v12'], clock: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M12 7v5l3 2'], chevron: ['M9 5l7 7-7 7'],
      globe: ['M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z', 'M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18'], server: ['M4 6h16v5H4zM4 13h16v5H4z', 'M7.5 8.5h.01M7.5 15.5h.01'],
      dns: ['M12 3v4M12 17v4M3 12h4M17 12h4', 'M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z'], plus: ['M12 5v14M5 12h14'],
      search: ['M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z', 'M20 20l-4-4'], refresh: ['M20 11a8 8 0 0 0-14-4M4 4v4h4', 'M4 13a8 8 0 0 0 14 4M20 20v-4h-4'],
      shield: ['M12 3l8 3v6c0 4.5-3.2 8-8 9-4.8-1-8-4.5-8-9V6z', 'M8.5 12l2.5 2.5L15.5 10'], people: ['M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z', 'M4 21a8 8 0 0 1 16 0'],
      up: ['M5 12.5l4.5 4.5L19 7.5'], down: ['M12 4l9 16H3z', 'M12 10v4M12 17.5v.5'],
    };
    const kindIcon = (kind) => icon(kind === 'HTTP' ? icons.globe : kind === 'DNS' ? icons.dns : icons.server);
    const kindTone = (kind) => (kind === 'HTTP' ? '' : kind === 'DNS' ? 'teal' : 'pink');

    // MARK: Theme

    function applyTheme(theme) {
      if (theme) document.documentElement.dataset.theme = theme; else delete document.documentElement.dataset.theme;
      $('#darkToggle').checked = theme ? theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    }
    try { applyTheme(localStorage.getItem('ruru-theme')); } catch { applyTheme(null); }
    $('#darkToggle').onchange = (event) => {
      const theme = event.target.checked ? 'dark' : 'light';
      applyTheme(theme);
      try { localStorage.setItem('ruru-theme', theme); } catch { /* the choice just will not persist */ }
    };

    // MARK: Sign in

    async function authenticate(register) {
      const kind = register ? 'registration' : 'authentication';
      const options = adapt(register
        ? await api('/api/web/passkeys/registration/options', { method: 'POST', body: { code: $('#code').value.trim(), email: $('#email').value.trim() } })
        : await api('/api/web/passkeys/authentication/options'));
      const credential = register ? await navigator.credentials.create({ publicKey: options }) : await navigator.credentials.get({ publicKey: options });
      const done = await api(`/api/web/passkeys/${kind}/finish`, { method: 'POST', body: credentialJSON(credential) });
      state.csrf = done.csrf;
      await enter();
    }

    async function start() {
      try {
        const status = await api('/api/web/status');
        $('#login').hidden = false;
        $('#loginMessage').textContent = status.passkeyEnrolled ? 'Use your passkey to open the console.' : 'Register the first passkey to take ownership of this console.';
        $('#signIn').hidden = !status.passkeyEnrolled;
        $('#firstTime').open = !status.passkeyEnrolled;
      } catch (error) {
        $('#login').hidden = false;
        $('#loginMessage').textContent = say(error);
      }
    }

    $('#signIn').onclick = () => authenticate(false).catch((error) => { $('#loginMessage').textContent = say(error); });
    $('#enrol').onclick = () => authenticate(true).catch((error) => { $('#loginMessage').textContent = say(error); });
    $('#logout').onclick = async () => { try { await api('/api/web/logout', { method: 'POST' }); } finally { location.reload(); } };

    // MARK: Shell

    async function enter() {
      $('#login').hidden = true;
      $('#app').hidden = false;
      try { await api('/api/web/operators'); state.role = 'owner'; } catch { state.role = 'administrator'; }
      $('#operatorsLink').hidden = state.role !== 'owner';
      await refresh();
      clearInterval(state.timer);
      state.timer = setInterval(() => { if (document.visibilityState === 'visible' && $('#scrim').hidden) refresh(); }, 15000);
    }

    const currentPage = () => { const name = location.hash.slice(1); return pages[name] && !(name === 'operators' && state.role !== 'owner') ? name : 'overview'; };
    window.addEventListener('hashchange', () => { closeSheet(); state.filter = ''; render(); });

    async function refresh() {
      try {
        [state.monitors, state.service, state.guarded] = await Promise.all([api('/api/web/monitors'), api('/api/web/service'), api('/api/web/guarded')]);
        state.guardedAt = Date.now();
        render();
      } catch (error) { if (error.status === 401) location.reload(); else toast(say(error)); }
    }

    function render() {
      const name = currentPage();
      document.querySelectorAll('.sidebar nav a').forEach((link) => { if (link.dataset.page === name) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current'); });
      renderSide();
      Promise.resolve(pages[name]()).then((nodes) => $('#main').replaceChildren(...nodes));
    }

    function stats() {
      const active = state.monitors.filter((m) => m.enabled);
      const latencies = active.map((m) => m.latencyMilliseconds).filter((n) => Number.isFinite(n));
      const samples = active.flatMap((m) => (m.history || []).filter((h) => !h.inconclusive));
      const dayAgo = Date.now() - 24 * 3600 * 1000;
      const changes = state.monitors.flatMap((m) => (m.changes || []).map((c) => ({ ...c, monitor: m, at: Date.parse(c.time) }))).sort((a, b) => b.at - a.at);
      return {
        total: state.monitors.length, active: active.length, paused: state.monitors.length - active.length,
        up: active.filter((m) => m.status === 'up').length, down: active.filter((m) => m.status === 'down').length,
        waiting: active.filter((m) => m.status === 'unknown').length,
        average: latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : null,
        uptime: samples.length ? (samples.filter((h) => h.ok).length / samples.length) * 100 : null,
        incidents: changes.filter((c) => c.status === 'down' && c.at >= dayAgo).length,
        recovered: changes.filter((c) => c.status === 'up' && c.at >= dayAgo).length,
        changes,
      };
    }

    function uptimeOf(m) {
      const samples = (m.history || []).filter((h) => !h.inconclusive);
      return samples.length ? (samples.filter((h) => h.ok).length / samples.length) * 100 : null;
    }
    const percent = (value) => (value === null ? '—' : `${value >= 99.95 || value === 0 ? Math.round(value) : value.toFixed(1)}%`);

    function ago(iso) {
      const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
      if (seconds < 60) return 'just now';
      if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
      if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
      return `${Math.floor(seconds / 86400)}d ago`;
    }

    setInterval(() => {
      if ($('#app').hidden || !state.guarded.some((g) => g.owner)) return;
      if (currentPage() === 'guarding') render();
      else document.querySelectorAll('[data-lease]').forEach((cell) => { const g = state.guarded.find((item) => item.id === cell.dataset.lease); if (g) cell.textContent = `${Math.ceil(remaining(g))} s`; });
    }, 1000);

    function renderSide() {
      const s = stats();
      const tone = !state.service.running ? 'bad' : s.down ? 'warn' : 'ok';
      const title = !state.service.running ? 'Stopped' : s.down ? 'Needs attention' : 'Guarding';
      const note = !state.service.running ? 'Ruru is not running' : s.down ? `${s.down} ${s.down === 1 ? 'target' : 'targets'} unreachable` : 'All systems operational';
      $('#sideStatus').replaceChildren(el('span', { className: `dot ${tone}` }), el('div', {}, el('b', { textContent: title }), el('span', { className: 'muted', textContent: note })));
    }

    // MARK: Overview

    const heroArt = () => {
      const svg = document.createElementNS(svgNS, 'svg');
      svg.setAttribute('class', 'art'); svg.setAttribute('viewBox', '0 0 1200 320'); svg.setAttribute('preserveAspectRatio', 'xMidYMid slice'); svg.setAttribute('aria-hidden', 'true');
      const add = (tag, attrs, parent = svg) => { const node = document.createElementNS(svgNS, tag); for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v); parent.append(node); return node; };
      const defs = add('defs', {});
      const sky = add('linearGradient', { id: 'sky', x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
      [['0', '#3d3f86'], ['.45', '#8a5fb0'], ['.72', '#e9876f'], ['1', '#f3b17a']].forEach(([o, c]) => add('stop', { offset: o, 'stop-color': c }, sky));
      const lake = add('linearGradient', { id: 'lake', x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
      [['0', '#7a6aa8'], ['1', '#3f4478']].forEach(([o, c]) => add('stop', { offset: o, 'stop-color': c }, lake));
      const shade = add('linearGradient', { id: 'shade', x1: 0, y1: 0, x2: 1, y2: 0 }, defs);
      [['0', '#14162e'], ['.55', '#14162e']].forEach(([o, c]) => add('stop', { offset: o, 'stop-color': c, 'stop-opacity': o === '0' ? '.55' : '0' }, shade));
      add('rect', { width: 1200, height: 320, fill: 'url(#sky)' });
      add('path', { d: 'M0 190 L80 140 L150 175 L250 100 L330 160 L430 90 L520 170 L610 120 L700 180 L800 105 L890 165 L990 95 L1080 160 L1200 120 V250 H0Z', fill: '#4b4580', opacity: '.75' });
      add('path', { d: 'M0 215 L90 175 L180 205 L280 150 L380 200 L470 160 L570 210 L680 155 L780 205 L880 160 L980 210 L1090 170 L1200 200 V260 H0Z', fill: '#2c2a58' });
      add('rect', { y: 238, width: 1200, height: 82, fill: 'url(#lake)' });
      add('rect', { width: 1200, height: 320, fill: 'url(#shade)' });
      return svg;
    };

    function heroSummary(s) {
      const g = state.guarded.length;
      const parts = [];
      if (g) parts.push(`Guarding ${g} ${g === 1 ? 'service' : 'services'}`);
      if (s.total) parts.push(`monitoring ${s.total} ${s.total === 1 ? 'target' : 'targets'}`);
      if (!parts.length) return 'Nothing is configured yet.';
      const text = parts.join(' · ');
      return `${text.charAt(0).toUpperCase()}${text.slice(1)}${s.down ? ` · ${s.down} unreachable` : ''}.`;
    }

    function statCard(label, iconPaths, tone, value, note, target) {
      const card = el('button', { className: 'stat' }, el('span', { className: `tile ${tone}` }, icon(iconPaths)),
        el('span', { className: 'meta' }, el('span', { className: 'label', textContent: label }), el('strong', { textContent: value }), el('span', { className: 'note', textContent: note })), icon(icons.chevron, 'go'));
      card.onclick = () => { location.hash = target; };
      return card;
    }

    function renderOverview() {
      const s = stats();
      const running = state.service.running;
      const started = state.service.startedAt ? new Date(state.service.startedAt).toLocaleString([], { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : null;
      const hero = el('header', { className: 'hero' }, heroArt(),
        el('div', {}, el('h1', {}, el('span', { className: `dot ${running ? (s.down ? 'warn' : 'ok') : 'bad'}` }), running ? 'Ruru is guarding' : 'Ruru is stopped'),
          el('p', { textContent: heroSummary(s) })),
        el('div', { className: `running ${running ? '' : 'bad'}` }, el('span', { className: 'shield' }, icon(icons.shield)),
          el('div', {}, el('b', { textContent: running ? 'Running' : 'Not running' }), el('span', { textContent: started ? `Since ${started}` : 'Start Ruru in its native console' }))));
      const cards = el('section', { className: 'stats', ariaLabel: 'Summary' },
        statCard('Monitors', icons.globe, '', String(s.total), s.total ? `${s.up} online · ${s.down} offline` : 'None yet', '#monitors'),
        statCard('Incidents (24h)', icons.alert, s.incidents ? 'bad' : 'idle', String(s.incidents), `${s.recovered} recovered`, '#monitors'),
        statCard('Uptime (recent)', icons.clock, 'ok', percent(s.uptime), 'Recent checks', '#monitors'),
        statCard('Avg. Response', icons.pulse, 'teal', s.average === null ? '—' : `${s.average} ms`, 'Across monitors', '#monitors'));
      const events = el('section', { className: 'card section' }, el('header', {}, el('h2', { textContent: 'Recent Events' })),
        s.changes.length ? el('div', { className: 'events' }, ...s.changes.slice(0, 5).map((c) => {
          const down = c.status === 'down';
          return el('div', { className: 'event' }, el('span', { className: `dot ${down ? 'bad' : c.status === 'up' ? 'ok' : ''}` }),
            el('span', { className: `tile ${down ? 'bad' : 'ok'}` }, icon(down ? icons.down : icons.up)),
            el('div', { className: 'text' }, el('b', { textContent: `${c.monitor.name} is ${down ? 'offline' : c.status === 'up' ? 'back online' : 'waiting'}` }), el('span', { className: 'sub', textContent: c.detail || address(c.monitor) })),
            el('time', { textContent: ago(c.time), dateTime: c.time }));
        }))
        : el('div', { className: 'empty' }, icon(icons.check), el('p', { className: 'muted', textContent: 'No status changes yet.' })));
      return [hero, el('div', { className: 'body' }, cards, el('div', { className: 'columns' }, el('div', { className: 'side-col' }, guardedCard(), monitorsCard(5, true)), events))];
    }

    async function checkAll() {
      const targets = state.monitors.filter((m) => m.enabled);
      if (!targets.length) { toast('No active monitors to check.'); return; }
      try { for (const m of targets) await api('/api/web/monitors/check', { method: 'POST', body: { id: m.id } }); toast(`Checking ${targets.length} ${targets.length === 1 ? 'monitor' : 'monitors'}…`); setTimeout(refresh, 3000); }
      catch (error) { toast(say(error)); }
    }

    // MARK: Guarding

    const stateLabel = { owned: ['Owned', 'ok'], waiting: ['Waiting', ''], recovering: ['Recovering', 'warn'] };
    const groupDigits = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');

    function remaining(service) {
      if (!service.owner) return 0;
      return Math.max(0, service.owner.remainingSeconds - (Date.now() - state.guardedAt) / 1000);
    }

    function guardedCard() {
      const rows = state.guarded.length
        ? el('div', { className: 'table compact' },
            el('div', { className: 'head', ariaHidden: 'true' }, el('span', { textContent: 'Service' }), el('span', { className: 'hide-sm', textContent: 'Owner' }), el('span', { textContent: 'Status' })),
            ...state.guarded.map((g) => {
              const [text, tone] = stateLabel[g.state] || ['Unknown', ''];
              const row = el('button', { className: 'row guard-row' },
                el('span', { className: 'cell-name' }, el('span', { className: 'tile' }, icon(icons.shield)), el('div', {}, el('b', { textContent: g.name, title: g.name }), el('span', { textContent: g.kind }))),
                el('span', { className: 'hide-sm', textContent: g.owner ? g.owner.name : '—' }),
                el('span', { className: `pill dotted ${tone}`, textContent: text }));
              row.onclick = () => { location.hash = '#guarding'; };
              return row;
            }))
        : el('div', { className: 'empty' }, icon(icons.shield), el('p', { className: 'muted', textContent: 'No guarded services configured.' }));
      const more = el('button', { className: 'link-btn', textContent: 'Open Guarding' });
      more.onclick = () => { location.hash = '#guarding'; };
      return el('section', { className: 'card section' }, el('header', {}, el('h2', { textContent: 'Guarded Services' }), state.guarded.length ? more : null), rows);
    }

    function ring(service) {
      const total = service.leaseSeconds, left = remaining(service), fraction = Math.min(1, left / total);
      const wrap = el('div', { className: `ring ${fraction < 1 / 3 ? (left < 5 ? 'urgent' : 'late') : ''}`, role: 'img', ariaLabel: `${Math.ceil(left)} seconds left on this grant` });
      const svg = document.createElementNS(svgNS, 'svg');
      svg.setAttribute('viewBox', '0 0 64 64'); svg.setAttribute('fill', 'none');
      const circle = (cls) => { const c = document.createElementNS(svgNS, 'circle'); c.setAttribute('cx', 32); c.setAttribute('cy', 32); c.setAttribute('r', 28); c.setAttribute('class', cls); svg.append(c); return c; };
      circle('track');
      const arc = circle('arc'); const circumference = 2 * Math.PI * 28;
      arc.setAttribute('stroke-dasharray', `${(circumference * fraction).toFixed(1)} ${circumference.toFixed(1)}`); arc.setAttribute('stroke-linecap', 'round');
      wrap.append(svg, el('b', { textContent: `${Math.ceil(left)}s` }));
      return wrap;
    }

    const actionText = { acquire: 'took ownership', release: 'released ownership', expire: 'lost ownership' };

    function serviceCard(g) {
      const [text, tone] = stateLabel[g.state] || ['Unknown', ''];
      const owner = g.owner
        ? el('div', { className: 'owner' }, ring(g), el('div', { className: 'who' }, el('span', { textContent: 'Current owner' }), el('b', { textContent: g.owner.name, title: g.owner.name }), el('span', { textContent: `Lease ${g.leaseSeconds} s` })),
            el('div', {}, el('span', { className: 'sub', textContent: 'Term' }), el('div', { className: 'term', textContent: groupDigits(g.owner.term) })))
        : el('div', { className: 'owner' }, el('div', { className: 'who' }, el('span', { textContent: 'Current owner' }), el('b', { textContent: g.state === 'recovering' ? 'Recovering' : 'No owner yet' }), el('span', { textContent: g.state === 'recovering' ? `Grants refused for about ${Math.ceil(g.recoverySeconds)} s while earlier leases expire.` : 'Waiting for a server to acquire it.' })));
      const people = g.participants.length
        ? el('div', {}, el('h4', { textContent: 'Servers' }), el('ul', {}, ...g.participants.map((p) => el('li', {}, el('span', { textContent: `${p.name}${p.role !== 'unknown' ? ` · ${p.role}` : ''}` }), el('span', { textContent: p.fresh ? 'Present' : 'Not seen recently' })))))
        : null;
      const activity = g.activity.length
        ? el('div', {}, el('h4', { textContent: 'Recent ownership' }), el('ul', {}, ...g.activity.map((a) => el('li', {}, el('span', { textContent: `${a.name} ${actionText[a.action] || a.action}` }), el('time', { textContent: ago(a.time), dateTime: a.time })))))
        : null;
      return el('section', { className: 'card svc' },
        el('header', {}, el('span', { className: 'tile' }, icon(icons.shield)), el('h3', { textContent: g.name, title: g.name }), el('span', { className: `pill dotted ${tone}`, textContent: text })),
        g.state === 'recovering' ? el('div', { className: 'notice', textContent: 'Restart quarantine is active. Ownership will resume once earlier leases have expired.' }) : null,
        owner, people, activity);
    }

    function renderGuarding() {
      const body = state.guarded.length
        ? el('div', { className: 'svc-grid' }, ...state.guarded.map(serviceCard))
        : el('section', { className: 'card section' }, el('div', { className: 'empty' }, icon(icons.shield), el('p', { className: 'muted', textContent: 'No guarded services are configured. Add one in Ruru’s native console.' })));
      return [el('header', { className: 'page-top' }, el('div', {}, el('h1', { textContent: 'Guarding' }), el('p', { className: 'muted', textContent: 'Read-only view of lease ownership. Ownership can only be changed by the servers themselves.' }))),
        el('div', { className: 'page-body' }, body)];
    }

    // MARK: Monitors

    const reported = (m) => (m.app && m.app.current && (m.app.state === 'degraded' || m.app.state === 'outdated') ? m.app.state : null);
    const titleCase = (s) => s.charAt(0).toUpperCase() + s.slice(1);
    const statusOf = (m) => (!m.enabled ? { cls: '', text: 'Paused' } : m.status === 'up' ? (reported(m) ? { cls: 'warn', text: titleCase(reported(m)) } : { cls: 'ok', text: 'Online' }) : m.status === 'down' ? { cls: 'bad', text: 'Offline' } : { cls: '', text: 'Waiting' });
    const address = (m) => (m.kind === 'HTTP' ? m.url : m.kind === 'DNS' ? `${m.host}:${m.port} · ${m.dnsQueryName}` : `${m.host}:${m.port}`);

    function monitorsCard(limit, withLink) {
      const query = state.filter.trim().toLowerCase();
      const matches = state.monitors.filter((m) => !query || `${m.name} ${address(m)} ${m.kind}`.toLowerCase().includes(query));
      const shown = limit ? matches.slice(0, limit) : matches;
      const search = el('label', { className: 'search' }, icon(icons.search), el('input', { type: 'search', placeholder: 'Search', value: state.filter, ariaLabel: 'Search monitors' }));
      const input = search.querySelector('input');
      input.oninput = () => { state.filter = input.value; const caret = input.selectionStart; render(); setTimeout(() => { const next = document.querySelector('.search input'); if (next) { next.focus(); next.setSelectionRange(caret, caret); } }, 0); };
      const add = el('button', { className: 'primary' }, icon(icons.plus), 'Add Monitor');
      add.onclick = openAdd;
      const body = shown.length
        ? el('div', { className: `table${limit ? ' compact' : ''}` },
            el('div', { className: 'head', ariaHidden: 'true' }, el('span', { textContent: 'Name' }), limit ? el('span', { className: 'hide-sm', textContent: 'Response' }) : el('span', { className: 'hide-sm', textContent: 'Type' }), el('span', { textContent: 'Status' }), ...(limit ? [] : [el('span', { className: 'hide-sm', textContent: 'Response' }), el('span', { className: 'hide-sm', textContent: 'Uptime' })])),
            ...shown.map((m) => monitorRow(m, !!limit)))
        : el('div', { className: 'empty' }, icon(icons.pulse), el('p', { className: 'muted', textContent: state.monitors.length ? 'No monitors match your search.' : 'No monitors yet. Add a website, TCP port or DNS server to watch.' }));
      const more = withLink && matches.length > shown.length ? el('button', { className: 'link-btn', textContent: `View all ${matches.length}` }) : null;
      if (more) more.onclick = () => { location.hash = '#monitors'; };
      return el('section', { className: 'card section' }, el('header', {}, el('h2', { textContent: 'Monitors' }), el('div', { className: 'tools' }, search, add)), body, more);
    }

    function monitorRow(m, compact) {
      const status = statusOf(m);
      const row = el('button', { className: 'row' },
        el('span', { className: 'cell-name' }, el('span', { className: `tile ${kindTone(m.kind)}` }, kindIcon(m.kind)), el('div', {}, el('b', { textContent: m.name, title: m.name }), el('span', { textContent: address(m), title: address(m) }))),
        compact ? null : el('span', { className: 'hide-sm' }, el('span', { className: 'pill type', textContent: m.kind })),
        compact ? el('span', { className: 'num hide-sm', textContent: m.enabled && Number.isFinite(m.latencyMilliseconds) ? `${m.latencyMilliseconds} ms` : '—' }) : null,
        el('span', { className: `pill dotted ${status.cls}`, textContent: status.text }),
        compact ? null : el('span', { className: 'num hide-sm', textContent: m.enabled && Number.isFinite(m.latencyMilliseconds) ? `${m.latencyMilliseconds} ms` : '—' }),
        compact ? null : el('span', { className: 'num hide-sm', textContent: m.enabled ? percent(uptimeOf(m)) : '—' }));
      row.onclick = () => openDetail(m.id);
      return row;
    }

    function renderMonitors() {
      const checkAllButton = el('button', { textContent: 'Check All Now' });
      checkAllButton.onclick = checkAll;
      return [el('header', { className: 'page-top' }, el('div', {}, el('h1', { textContent: 'Monitors' }), el('p', { className: 'muted', textContent: 'Checks are bounded and observational; they never affect lease ownership.' })), checkAllButton),
        el('div', { className: 'page-body' }, monitorsCard(0, false))];
    }

    // MARK: Operators

    async function renderOperators() {
      let operators = [];
      try { operators = await api('/api/web/operators'); } catch (error) { toast(say(error)); }
      const invite = el('button', { className: 'primary' }, icon(icons.plus), 'Invite Operator');
      invite.onclick = openInvite;
      const list = el('div', { className: 'table' }, ...operators.map((o) => {
        const item = el('div', { className: 'row simple' }, el('span', { className: 'cell-name' }, el('span', { className: 'tile' }, icon(icons.people)), el('div', {}, el('b', { textContent: o.email }), el('span', { textContent: o.role === 'owner' ? 'Owner' : 'Administrator' }))));
        if (o.role !== 'owner') {
          const remove = el('button', { className: 'danger', textContent: 'Remove' });
          remove.onclick = async () => { if (!confirm(`Remove ${o.email}? They will be signed out.`)) return; try { await api('/api/web/operators/remove', { method: 'POST', body: { email: o.email } }); render(); } catch (e) { toast(say(e)); } };
          item.append(remove);
        }
        return item;
      }));
      return [el('header', { className: 'page-top' }, el('div', {}, el('h1', { textContent: 'Operators' }), el('p', { className: 'muted', textContent: 'People who can open this console. Each signs in with their own passkey.' })), invite),
        el('div', { className: 'page-body' }, el('section', { className: 'card section' }, el('header', {}, el('h2', { textContent: 'Operators' })), list))];
    }

    function openInvite() {
      const email = el('input', { type: 'email', required: true, placeholder: 'name@example.com', autocomplete: 'off' });
      const result = el('div', { hidden: true });
      const submit = el('button', { className: 'primary block', textContent: 'Create Invitation', type: 'submit' });
      const form = el('form', {}, field('Email', email), submit, result);
      form.onsubmit = async (event) => {
        event.preventDefault();
        try {
          const invite = await api('/api/web/operators/invitations', { method: 'POST', body: { email: email.value.trim() } });
          result.hidden = false;
          result.replaceChildren(el('p', { className: 'muted', textContent: `Share this one-time code privately with ${invite.email}. It expires at ${new Date(invite.expiresAt).toLocaleTimeString()}.` }), el('div', { className: 'code', textContent: invite.code }));
          submit.disabled = true;
        } catch (error) { toast(say(error)); }
      };
      openSheet('Invite Operator', form);
      email.focus();
    }

    // MARK: Sheets

    function openSheet(title, ...content) {
      $('#sheetTitle').textContent = title;
      $('#sheetBody').replaceChildren(...content);
      $('#scrim').hidden = false;
      $('#sheetClose').focus();
    }
    function closeSheet() { if ($('#scrim').hidden) return; $('#scrim').hidden = true; $('#sheetBody').replaceChildren(); }
    $('#sheetClose').onclick = closeSheet;
    $('#scrim').onclick = (event) => { if (event.target === $('#scrim')) closeSheet(); };
    document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeSheet(); });

    function sparkline(history) {
      const svg = document.createElementNS(svgNS, 'svg');
      svg.setAttribute('viewBox', '0 0 240 56'); svg.setAttribute('class', 'spark'); svg.setAttribute('preserveAspectRatio', 'none');
      svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'Recent response times; red bars mark failed checks');
      const values = history.map((h) => (h.ok && Number.isFinite(h.ms) ? h.ms : null));
      const max = Math.max(1, ...values.filter((v) => v !== null));
      const step = history.length > 1 ? 240 / (history.length - 1) : 240;
      let path = '';
      values.forEach((v, i) => { if (v === null) return; path += `${path && values[i - 1] !== null ? 'L' : 'M'}${(i * step).toFixed(1)},${(52 - (v / max) * 46).toFixed(1)}`; });
      const line = document.createElementNS(svgNS, 'path');
      line.setAttribute('d', path || 'M0,28L240,28'); line.setAttribute('fill', 'none'); line.setAttribute('stroke', 'currentColor');
      line.setAttribute('stroke-width', '2'); line.setAttribute('vector-effect', 'non-scaling-stroke');
      svg.append(line);
      history.forEach((h, i) => {
        if (h.ok || h.inconclusive) return;
        const mark = document.createElementNS(svgNS, 'rect');
        mark.setAttribute('x', (i * step - 1).toFixed(1)); mark.setAttribute('y', '0'); mark.setAttribute('width', '2'); mark.setAttribute('height', '56'); mark.setAttribute('fill', '#e5484d');
        svg.append(mark);
      });
      return svg;
    }

    function openDetail(id) {
      const m = state.monitors.find((item) => item.id === id);
      if (!m) return;
      const status = statusOf(m);
      const line = (label, value) => el('li', {}, el('span', { textContent: label }), value instanceof Node ? value : el('span', { textContent: value }));
      const check = el('button', { className: 'primary', textContent: 'Check Now' });
      check.onclick = async () => {
        check.disabled = true;
        try { await api('/api/web/monitors/check', { method: 'POST', body: { id } }); toast('Checking…'); setTimeout(async () => { await refresh(); if (!$('#scrim').hidden) openDetail(id); }, 2500); }
        catch (e) { toast(say(e)); check.disabled = false; }
      };
      const remove = el('button', { className: 'danger', textContent: 'Remove…' });
      remove.onclick = async () => {
        if (!confirm(`Remove “${m.name}”? Its history will be lost.`)) return;
        try { await api('/api/web/monitors/delete', { method: 'POST', body: { id } }); closeSheet(); await refresh(); } catch (e) { toast(say(e)); }
      };
      openSheet(m.name,
        el('ul', { className: 'inset' },
          line('Status', el('span', { className: `pill dotted ${status.cls}`, textContent: status.text })), line('Type', m.kind), line('Target', address(m)),
          line('Last check', m.detail || 'No result yet'), line('Response', Number.isFinite(m.latencyMilliseconds) ? `${m.latencyMilliseconds} ms` : '—'), line('Uptime (recent)', percent(uptimeOf(m))),
          line('Schedule', `Every ${m.intervalSeconds} s · down after ${m.failureThreshold} ${m.failureThreshold === 1 ? 'failure' : 'failures'}`)),
        sparkline(m.history || []),
        appStatus(m),
        el('div', { className: 'actions' }, remove, check));
    }

    // Enhanced monitors: the app's own report, rendered as text only.
    function appStatus(m) {
      if (!m.app) return null;
      const a = m.app;
      const line = (label, value) => el('li', {}, el('span', { textContent: label }), el('span', { textContent: value }));
      const items = [];
      if (a.name) items.push(line('App', [a.name, a.version].filter(Boolean).join(' ')));
      if (a.state) items.push(line('Reported', titleCase(a.state) + (a.current ? '' : ' (stale)')));
      if (a.issue) items.push(line('Status document', a.issue));
      for (const c of a.components || []) items.push(line(c.name, titleCase(c.state)));
      for (const x of a.metrics || []) items.push(line(x.name, `${Number(x.value).toLocaleString()}${x.unit && x.unit !== 'count' ? ' ' + x.unit : ''}`));
      if (!items.length) items.push(line('App status', 'Waiting for the first report'));
      return el('ul', { className: 'inset' }, ...items);
    }

    function field(label, input) { return el('label', { textContent: label }, input); }

    function openAdd() {
      const name = el('input', { required: true, maxLength: 60, placeholder: 'Home router' });
      const kind = el('select', {}, ...[['HTTP', 'Website (HTTP/S)'], ['TCP', 'TCP port'], ['DNS', 'DNS server']].map(([v, t]) => el('option', { value: v, textContent: t })));
      const url = el('input', { placeholder: 'https://203.0.113.10/health', inputMode: 'url' });
      const host = el('input', { placeholder: '192.168.1.1' });
      const port = el('input', { type: 'number', min: 1, max: 65535, value: 443 });
      const dnsName = el('input', { value: 'example.com' });
      const interval = el('input', { type: 'number', min: 30, max: 3600, value: 60 });
      const timeout = el('input', { type: 'number', min: 1, max: 60, value: 10 });
      const threshold = el('input', { type: 'number', min: 1, max: 10, value: 3 });
      const groups = { url: field('Address', url), host: field('Host', host), port: field('Port', port), dns: field('Name to look up', dnsName) };
      const sync = () => {
        groups.url.hidden = kind.value !== 'HTTP';
        groups.host.hidden = groups.port.hidden = kind.value === 'HTTP';
        groups.dns.hidden = kind.value !== 'DNS';
        if (kind.value === 'DNS') port.value = 53; else if (port.value === '53') port.value = 443;
      };
      kind.onchange = sync; sync();
      const save = el('button', { className: 'primary block', textContent: 'Add Monitor', type: 'submit' });
      const form = el('form', {}, field('Name', name), field('Type', kind), groups.url, el('div', { className: 'grid2' }, groups.host, groups.port), groups.dns,
        el('div', { className: 'grid3' }, field('Every (s)', interval), field('Timeout (s)', timeout), field('Down after', threshold)), save);
      form.onsubmit = async (event) => {
        event.preventDefault(); save.disabled = true;
        const http = kind.value === 'HTTP';
        const target = { id: crypto.randomUUID(), name: name.value.trim(), kind: kind.value, host: http ? '' : host.value.trim(), port: http ? 0 : Number(port.value),
          url: http ? url.value.trim() : '', dnsQueryName: dnsName.value.trim() || 'example.com', intervalSeconds: Number(interval.value),
          timeoutSeconds: Number(timeout.value), failureThreshold: Number(threshold.value), enabled: true, needsAttention: false };
        try { await api('/api/web/monitors', { method: 'POST', body: target }); closeSheet(); await refresh(); toast(`Added ${target.name}`); }
        catch (error) { toast(say(error)); save.disabled = false; }
      };
      openSheet('Add Monitor', form);
      name.focus();
    }

    start();
    """#
}
