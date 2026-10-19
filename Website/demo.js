'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const shell = document.querySelector('.demo-shell');
  const phases = [
    {key:'healthy',duration:4800,title:'Business as usual.',description:'Server A renews its permission while Server B waits.',owner:'Server A',authority:'Keeping watch',message:'One active owner. One ready standby.',a:['active','Active','Running','Handling the workload','Lease renewed. Output enabled.','Ownership granted','TERM 041'],b:['','Standby','Waiting','Ready when needed','Watching for available permission.','No active lease','STANDBY'],pathA:true,pathB:false},
    {key:'lost',duration:4400,title:'Server A loses contact.',description:'Its permission counts down. Server B must wait for expiry.',owner:'Server A',authority:'Awaiting expiry',message:'The old lease must expire before a new grant.',a:['warning','No contact','Stopping','Permission expiring','Output stops by the local deadline.','Waiting for expiry','TERM 041'],b:['','Standby','Waiting','Waiting for permission','No takeover while the old lease is live.','No active lease','STANDBY'],pathA:true,pathB:false},
    {key:'failover',duration:5200,title:'The backup takes its turn.',description:'The old lease expires. Server B acquires a new grant and starts work.',owner:'Server B',authority:'New lease granted',message:'Permission granted to Server B. A new ownership term.',a:['offline','Offline','Stopped','Server unavailable','Previous permission has expired.','No active lease','EXPIRED'],b:['active','Active','Running','Handling the workload','New lease acquired. Output enabled.','Ownership granted','TERM 042'],pathA:false,pathB:true},
    {key:'recovered',duration:4200,title:'Server A comes back.',description:'It joins as standby. Recovery alone doesn’t change ownership.',owner:'Server B',authority:'Keeping watch',message:'Server A is back. Server B still owns the lease.',a:['','Standby','Waiting','Back and ready','Waiting for coordinated handback.','No active lease','STANDBY'],b:['active','Active','Running','Still handling the workload','Permission remains with Server B.','Ownership granted','TERM 042'],pathA:false,pathB:true},
    {key:'handback',duration:4400,title:'A careful return to primary.',description:'Compatible clients drain, release, then reacquire on Server A.',owner:'Server A',authority:'Handover complete',message:'Server B released. Server A acquired a new lease.',a:['active','Active','Running','Primary takes its turn','New lease acquired after release.','Ownership granted','TERM 043'],b:['','Standby','Waiting','Back on standby','Output drained before releasing.','No active lease','STANDBY'],pathA:true,pathB:false}
  ];
  let index = 0;
  let timer;
  let playing = !reducedMotion.matches;
  let deadline = 0;
  let remaining = phases[0].duration;
  function renderServer(id, data) {
    const [kind, status, app, activity, detail, foot, term] = data;
    $('server-'+id).className = 'server'+(kind?' '+kind:'');
    $('status-'+id).textContent = status;
    $('status-'+id).className = 'status'+(kind?' '+kind+'-status':'');
    $('app-state-'+id).textContent = app;
    $('activity-'+id).textContent = activity;
    $('detail-'+id).textContent = detail;
    $('foot-'+id).textContent = foot;
    $('term-'+id).textContent = term;
    $('server-'+id).querySelector('.activity-icon').textContent = kind==='active'?'✓':kind==='offline'?'!':kind==='warning'?'⌛':'·';
  }
  function render(announce = false) {
    const phase = phases[index];
    shell.dataset.phase = phase.key;
    $('authority-status').textContent = phase.authority;
    $('authority-owner').textContent = phase.owner;
    $('lease-message').textContent = phase.message;
    $('step-number').textContent = String(index+1).padStart(2,'0');
    $('step-title').textContent = phase.title;
    $('step-description').textContent = phase.description;
    renderServer('a',phase.a); renderServer('b',phase.b);
    $('path-a').classList.toggle('live',phase.pathA);
    $('path-a').classList.toggle('warning',phase.key==='lost');
    $('path-b').classList.toggle('live',phase.pathB);
    document.querySelectorAll('.step-progress i').forEach((dot,i)=>dot.classList.toggle('selected',i===index));
    if (announce) $('demo-announcement').textContent = phase.title+' '+phase.description;
  }
  function syncControls() {
    $('pause-demo').innerHTML = '<span aria-hidden="true">'+(playing?'Ⅱ':'▷')+'</span>';
    $('pause-demo').setAttribute('aria-label',playing?'Pause animation':'Play animation');
    shell.classList.toggle('paused',!playing);
  }
  function schedule() {
    clearTimeout(timer);
    if (!playing || document.hidden) return;
    deadline = performance.now()+remaining;
    timer = setTimeout(()=>{index=(index+1)%phases.length;remaining=phases[index].duration;render();schedule();},remaining);
  }
  function stopClock() {
    clearTimeout(timer);
    if (deadline) remaining = Math.max(0,deadline-performance.now());
    deadline = 0;
  }
  $('pause-demo').addEventListener('click',()=>{if(playing)stopClock();playing=!playing;syncControls();schedule();if(!playing)render(true);});
  $('restart-demo').addEventListener('click',()=>{index=0;remaining=phases[0].duration;deadline=0;render(true);schedule();});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stopClock();else schedule();});
  reducedMotion.addEventListener('change',event=>{if(event.matches){stopClock();playing=false;syncControls();}});
  function updateConnections() {
    const network = document.querySelector('.network');
    const svg = network.querySelector('.connections');
    const bounds = network.getBoundingClientRect();
    const authority = network.querySelector('.authority').getBoundingClientRect();
    const x = authority.left + authority.width / 2 - bounds.left;
    const y = authority.bottom - bounds.top;
    svg.setAttribute('viewBox', `0 0 ${bounds.width} ${bounds.height}`);
    const paths = svg.querySelectorAll('.base');
    ['a','b'].forEach((id,i) => {
      const server = $('server-'+id).getBoundingClientRect();
      const targetX = server.left + server.width / 2 - bounds.left;
      const targetY = server.top - bounds.top;
      const bendY = y + (targetY-y)*0.7;
      const direction = targetX < x ? -1 : 1;
      const d = `M${x} ${y} V${bendY-12} Q${x} ${bendY} ${x+direction*12} ${bendY} H${targetX-direction*12} Q${targetX} ${bendY} ${targetX} ${bendY+12} V${targetY}`;
      paths[i].setAttribute('d',d);
      $('path-'+id).setAttribute('d',d);
    });
  }
  new ResizeObserver(updateConnections).observe(document.querySelector('.network'));
  render();syncControls();schedule();
  const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
  function selectTab(tab) {
    tabs.forEach(t=>{t.setAttribute('aria-selected',String(t===tab));t.tabIndex=t===tab?0:-1;});
    $('app-screenshot').src = 'assets/'+tab.dataset.image;
    $('app-screenshot').alt = tab.dataset.caption+' Isolated development preview.';
    $('app-panel').setAttribute('aria-labelledby',tab.id);
    $('screenshot-caption').textContent = tab.dataset.caption;
  }
  tabs.forEach((tab,i)=>{
    tab.addEventListener('click',()=>selectTab(tab));
    tab.addEventListener('keydown',event=>{
      let target;
      if(event.key==='ArrowRight')target=tabs[(i+1)%tabs.length];
      if(event.key==='ArrowLeft')target=tabs[(i+tabs.length-1)%tabs.length];
      if(event.key==='Home')target=tabs[0];
      if(event.key==='End')target=tabs[tabs.length-1];
      if(target){event.preventDefault();selectTab(target);target.focus();}
    });
  });
})();
