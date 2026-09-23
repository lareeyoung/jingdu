import { createProject, clipsOf, placements, shots, shotAt, locateTime, addCut, removeCut, createNote, collectRange, appendCollection, scriptCurrent, activeCue, subtitleCurrent, sharedDialogues, formatTime, noteTitle } from '../shared/model.mjs';

const api = window.jingdu;
const $ = (q, parent = document) => parent.querySelector(q);
const h = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const tracks = [{id:'story',title:'叙事逻辑',short:'叙事',color:'var(--story)',prompt:'下一镜新增了什么信息？为什么在这里切？'}, {id:'camera',title:'镜头设计',short:'镜头',color:'var(--camera)',prompt:'景别、构图与运动，如何引导注意力？'}, {id:'sound',title:'声音设计',short:'声音',color:'var(--sound)',prompt:'先听音轨：声音何时进入，如何影响情绪？'}, {id:'learning',title:'学习启发',short:'心得',color:'var(--learning)',prompt:'换一个角色或场景，这个方法还能怎样用？'}];
const languages = {zh:'中文',en:'英语',ja:'日语',ko:'韩语',es:'西语',fr:'法语'};
const state = {projects:[],id:null,time:0,reader:'none',readerMode:'full',follow:true,layout:'picture',notes:false,noteId:null,zoom:1,loop:false,loopShot:null,rangeIn:null,rangeOut:null,thumbs:[],waves:[],busy:false,settings:{},filter:'',rate:1,muted:false,clipId:null,loadToken:0,seekToken:0,status:'视频与笔记保存在本机',undo:[]};
let video, videoLoad=null, editingNote=null, saveTimer, saveChain = Promise.resolve(), toastTimer, currentCueId, frameCallback, timelineObserver;
let remoteBusy=false, localMutationPending=0, closingRequested=false, thumbnailToken=0;
const pendingMutations=new Set();
const p = () => state.projects.find(x => x.id === state.id);
const duration = () => p()?.duration || 0;
const button = (action,label,cls='',title='') => `<button data-action="${action}" class="${cls}"${title ? ` title="${h(title)}"` : ''}>${label}</button>`;
function toast(message, error=false) { const node=$('#toast'); node.textContent=String(message).replace(/^Error invoking remote method '[^']+': (Error: )?/,''); node.className='show'+(error?' error':''); clearTimeout(toastTimer); toastTimer=setTimeout(()=>node.className='', error?9500:4200); }
async function call(channel,payload) { return api.invoke(channel,payload); }
function persist() { clearTimeout(saveTimer); const snapshot=structuredClone(state.projects); saveChain=saveChain.catch(()=>{}).then(()=>call('save',{projects:snapshot})).catch(e=>{toast(e.message,true);throw e}); return saveChain; }
function scheduleSave() { clearTimeout(saveTimer); saveTimer=setTimeout(()=>persist().catch(()=>{}),350); }
function syncBusy() { state.busy=remoteBusy||localMutationPending>0||closingRequested;updateStatus(); }
function runLocalMutation(work) {
  // Main-process progress may finish before its invoke result reaches this view.
  // Keep edits locked until the saved snapshot and returned result are reconciled.
  let complete;
  const settled=new Promise(resolve=>{complete=resolve});
  pendingMutations.add(settled);localMutationPending++;syncBusy();
  return (async()=>{try{await persist();return await work();}
    finally{pendingMutations.delete(settled);localMutationPending--;if(!localMutationPending&&!remoteBusy)state.status='本地工作区 · 内容自动保存';syncBusy();complete();}})();
}
function replaceProject(project) { state.projects=state.projects.map(x=>x.id===project.id?project:x); }
function checkpoint() { state.undo.push({id:state.id,project:structuredClone(p())}); if(state.undo.length>40)state.undo.shift(); }
function touch() { if(p())p().updatedAt=new Date().toISOString(); scheduleSave(); renderLibrary(); }
function modal(content) { const d=$('#modal'); d.innerHTML=content; if(!d.open)d.showModal(); }
function closeModal() { $('#modal').close(); }
function withTitle(title,body,footer) { return `<div class="row spread"><h2>${h(title)}</h2>${button('close-modal','×','quiet')}</div>${body}<div class="footer">${footer}</div>`; }
function currentShot() { return p()?shotAt(p(),Math.min(state.time,Math.max(0,duration()-0.001))):null; }
function displayTime(t) { return formatTime(t,p()?.frameRate||30); }

function renderShell() {
  const project=p();
  $('#app').innerHTML=`<div class="workspace ${state.layout==='balanced'?'balanced':state.layout==='vertical'?'vertical':''}">
    <aside class="sidebar"><div class="brand"><span class="brand-mark">⌗</span><div><strong>镜读</strong><small>FRAME STUDY</small></div></div><input class="search" id="search" aria-label="查找作品" placeholder="⌕  查找作品" value="${h(state.filter)}"><div class="project-list" id="project-list"></div><div class="sidebar-footer">${button('import-backup','↥  导入项目备份','quiet')}${button('settings','⚙  模型设置','quiet')}${button('help','?  使用方法与快捷键','quiet')}<div class="small muted" style="padding:8px">Windows 同事测试版 · ${h(state.version)}</div></div></aside>
    <header class="header" id="header"></header>
    <main class="content">${project?`<aside class="reader hidden" id="reader"></aside><section class="viewer"><div class="viewer-label"><span>${project.kind==='remix'?'灵感预览':'视频预览'} <span class="muted"> / TIMELINE</span></span><span class="pill" id="shot-number"></span></div><div class="video-wrap"><video id="video" playsinline preload="auto"></video><div class="video-message" id="video-message">正在准备播放…</div><div class="subtitles-overlay" id="subtitle-overlay"></div></div><div class="transport">${button('previous-shot','|‹','', '上一镜头 Shift + ←')}${button('previous-frame','‹','', '上一帧 ←')}${button('play','▶','play','播放 / 暂停 空格')}${button('next-frame','›','', '下一帧 →')}${button('next-shot','›|','', '下一镜头 Shift + →')}<span class="clock" id="clock">${displayTime(0)}</span><span class="grow"></span><select id="speed" aria-label="播放速度">${[0.25,0.5,0.75,1,1.5,2].map(x=>`<option value="${x}" ${x===state.rate?'selected':''}>${x}×</option>`).join('')}</select>${button('loop','↻',state.loop?'active':'','循环当前镜头 L')}${button('mute',state.muted?'静音':'声音','','静音切换')}</div><div class="context-shots" id="context-shots"></div></section><aside class="notes hidden" id="notes"></aside>`:`<section class="empty"><div class="eyebrow">WATCH · UNDERSTAND · CREATE</div><h1>把好作品，<br>变成自己的创作方法。</h1><p>逐帧看镜头，对照脚本与台词，留下你的观察。<br>从第一段值得反复看的视频开始。</p><div class="row">${button('import','＋ 导入视频','primary')}${button('import-backup','导入 Mac 项目备份','quiet')}</div><div class="steps"><div><span>01</span> 看镜头</div><div><span>02</span> 读台词</div><div><span>03</span> 记灵感</div></div></section>`}</main>
    <section class="timeline" id="timeline"></section><footer class="status"><span class="dot">●</span><span id="status-text"></span>${button('cancel','取消任务','quiet hidden')}<span class="shortcuts">空格 播放　← → 逐帧　C 镜头笔记　S 声音笔记　Esc 退出输入</span></footer></div>`;
  renderLibrary(); renderHeader(); renderTimeline(); renderReader(); renderNotes(); updateStatus();
  if(project){ video=$('#video'); bindVideo(); renderContext(); updateTime(); }
  else video=null;
}
function renderHeader(){ const project=p(); $('#header').innerHTML=`<div class="grow"><div class="row"><span class="project-name">${h(project?.title||'你的拉片工作区')}</span>${project?button('rename','✎','quiet','重命名项目，不修改视频文件名'):''}</div><div class="metadata">${project?`${project.width} × ${project.height}　·　${project.frameRate.toFixed(2)} fps　·　${displayTime(project.duration)}`:'本地作品库　/　WINDOWS'}</div></div><div class="toolbar">${project?`${button('reader-script','▤ 脚本',state.reader==='script'?'active':'quiet')}${button('reader-subtitles','▱ 字幕',state.reader==='subtitles'?'active':'quiet')}<select id="layout" aria-label="工作区布局"><option value="picture" ${state.layout==='picture'?'selected':''}>画面优先</option><option value="balanced" ${state.layout==='balanced'?'selected':''}>左右对照</option><option value="vertical" ${state.layout==='vertical'?'selected':''}>上下对照</option></select>${button('notes','✎ 笔记',state.notes?'active':'quiet')}${button('collect','◇ 收集','quiet')}${button('export','导出','quiet')}`:''}${button('import','＋ 导入视频','primary')}</div>`; }
function renderLibrary(){ const list=$('#project-list'); if(!list)return; const filtered=state.projects.filter(x=>x.title.toLowerCase().includes(state.filter.toLowerCase())); list.innerHTML=['study','remix'].map(kind=>`<div class="section-label">${kind==='study'?'作品库':'灵感空间'}<span>${state.projects.filter(x=>x.kind===kind).length}</span></div>${filtered.filter(x=>x.kind===kind).map(x=>`<button class="project ${x.id===state.id?'active':''}" data-project="${h(x.id)}"><strong>${kind==='study'?'▥':'◇'}　${h(x.title)}</strong><small>${shots(x).length} 镜头　·　${x.notes.length} 标记</small></button>`).join('')}`).join(''); }
function updateLocks(){ const locked=state.busy; document.querySelectorAll('#notes input,#notes textarea,#notes select').forEach(el=>el.disabled=locked); document.querySelectorAll('[data-new-note]').forEach(el=>el.disabled=locked); }
function updateStatus(){ updateLocks(); const node=$('#status-text'); if(node)node.textContent=state.status; $('[data-action="cancel"]')?.classList.toggle('hidden',!state.busy); }

async function selectProject(id){
  if(video){video.pause(); if(frameCallback)video.cancelVideoFrameCallback?.(frameCallback);}
  const token=++state.loadToken; ++state.seekToken; state.id=id; state.time=0;state.clipId=null;state.thumbs=[];state.waves=[];state.noteId=null;editingNote=null;videoLoad=null;state.rangeIn=null;state.rangeOut=null;state.loop=false;currentCueId=null;renderShell();
  if(!p())return;
  const projectId=id;
  const open=seek(0,false);
  refreshThumbnails(projectId).catch(()=>{});
  call('waveform',{projectId}).then(values=>{if(token!==state.loadToken)return;state.waves=values;drawWaveform()}).catch(()=>{});
  await open;
  Promise.all([...pendingMutations]).then(()=>{
    if(token===state.loadToken && state.id===projectId && state.settings.autoScript && state.settings.hasKey && !p().scriptAnalyses.length && !state.busy && p().duration<=300) runScript({start:0,end:p().duration,mode:'storyboard',focus:''}).catch(e=>toast(e.message,true));
  });
}
async function refreshThumbnails(projectId=state.id) {
  const token=++thumbnailToken,load=state.loadToken;
  const values=await call('thumbnails',{projectId});
  if(token!==thumbnailToken||load!==state.loadToken||state.id!==projectId)return;
  state.thumbs=values;renderTimeline();renderContext();
}
async function refreshCutThumbnails(projectId=state.id) {
  // Existing index-based thumbnails no longer identify the same shots after a cut.
  ++thumbnailToken;state.thumbs=[];renderTimeline();renderContext();
  await persist();await refreshThumbnails(projectId);
}
function ensureClip(clip, projectId) {
  if(videoLoad?.clipId===clip.id && videoLoad.projectId===projectId) return videoLoad.promise;
  if(state.clipId===clip.id && video.readyState>=1) return Promise.resolve();
  const element=video,record={clipId:clip.id,projectId,promise:null};
  state.clipId=null;video.pause();
  record.promise=(async()=>{
    const url=await call('playback',{projectId,clipId:clip.id});
    if(videoLoad!==record||state.id!==projectId||video!==element) throw new Error('已切换素材');
    await new Promise((resolve,reject)=>{
      const cleanup=()=>{clearTimeout(timer);element.removeEventListener('loadedmetadata',loaded);element.removeEventListener('error',failed);};
      const loaded=()=>{cleanup();resolve()};const failed=()=>{cleanup();reject(new Error('视频无法播放，请重新关联原素材。'))};
      const timer=setTimeout(()=>{cleanup();reject(new Error('视频载入超时，请重新关联原素材。'))},20000);
      element.addEventListener('loadedmetadata',loaded,{once:true});element.addEventListener('error',failed,{once:true});element.src=url;element.load();
    });
    if(videoLoad!==record||state.id!==projectId||video!==element) throw new Error('已切换素材');
    state.clipId=clip.id;
  })().finally(()=>{if(videoLoad===record)videoLoad=null});
  videoLoad=record;return record.promise;
}
async function seek(time, resume=video&&!video.paused){
  if(!p()||!video)return;
  if(!resume)video.pause();
  const token=++state.seekToken,projectId=state.id;state.time=Math.max(0,Math.min(Number(time)||0,duration()));
  const loc=locateTime(p(),state.time);if(!loc)return;state.reviewEnd=undefined;if(state.loop)state.loopShot=shotAt(p(),state.time);updateTime();
  if(state.clipId!==loc.clip.id||videoLoad){$('#video-message').textContent='正在准备兼容播放缓存，首次导入需要稍等…';$('#video-message').classList.remove('hidden');}
  try{
    await ensureClip(loc.clip,projectId);
    if(token!==state.seekToken||state.id!==projectId)return;
    $('#video-message').classList.add('hidden');
    video.currentTime=Math.max(0,Math.min(loc.sourceTime,Math.max(0,video.duration-0.0001)));video.playbackRate=state.rate;video.muted=state.muted;video.volume=p().originalVolume??1;
    if(resume)await video.play();
    renderContext();if(!state.noteId)renderNotes();
  }catch(e){if(token===state.seekToken){$('#video-message').textContent=e.message;toast(e.message,true);}}
}
function bindVideo(){
  video.addEventListener('play',()=>{$('[data-action="play"]').textContent='Ⅱ';tickFrame()});
  video.addEventListener('pause',()=>{$('[data-action="play"]')?.replaceChildren(document.createTextNode('▶'))});
  video.addEventListener('timeupdate',onVideoTime);
  video.addEventListener('ended',()=>{const place=placements(p()).find(x=>x.clip.id===state.clipId); if(place?.end<duration()-0.01)seek(place.end,true);});
}
function tickFrame(){ if(!video||video.paused)return;onVideoTime();if(video.requestVideoFrameCallback)frameCallback=video.requestVideoFrameCallback(tickFrame); }
let switching=false, contextShotKey=null;
function onVideoTime(){
  if(!p()||!video||switching)return;
  const place=placements(p()).find(x=>x.clip.id===state.clipId);if(!place)return;
  // Media timestamps are microseconds; round subtraction noise at trimmed seams
  // so a seek to a caption's exact start still selects that caption.
  state.time=Math.max(place.start,Math.min(place.end,Math.round((place.start+video.currentTime-place.clip.sourceIn)*1e6)/1e6));
  if(!video.paused && state.reviewEnd!==undefined && state.time>=state.reviewEnd-0.015){ video.pause();state.time=state.reviewEnd;state.reviewEnd=undefined;updateTime();return;}
  if(!video.paused && state.loop && state.loopShot && state.time>=state.loopShot.end-0.025){switching=true;seek(state.loopShot.start,true).finally(()=>switching=false);return;}
  if(!video.paused && video.currentTime>=place.clip.sourceOut-0.018){
    if(place.end<duration()-0.02){switching=true;seek(place.end+0.00001,true).finally(()=>switching=false);return;}else{video.pause();state.time=duration();}
  }
  updateTime();
}
function updateTime(){
  if(!p())return; const shot=currentShot();$('#clock')?.replaceChildren(document.createTextNode(displayTime(state.time)));$('#shot-number')?.replaceChildren(document.createTextNode(`SHOT ${String((shot?.index||0)+1).padStart(2,'0')}`));
  const contextKey=`${state.id}:${shot?.start}:${shot?.end}`;
  if(contextKey!==contextShotKey){contextShotKey=contextKey;renderContext();if(!state.noteId)renderNotes();}
  const inner=$('#timeline-inner'),head=$('#playhead');if(head&&inner)head.style.left=(state.time/duration()*inner.clientWidth)+'px';
  document.querySelectorAll('.shot-block').forEach(node=>node.classList.toggle('current',Number(node.dataset.shot)===shot?.index));
  const cues=sharedDialogues(p()),current=activeCue(cues,state.time);
  document.querySelectorAll('[data-cue-id]').forEach(node=>node.classList.toggle('current',node.dataset.cueId===current?.id));
  if(currentCueId!==current?.id){currentCueId=current?.id;if(state.follow&&current){const el=$(`[data-cue-id="${CSS.escape(current.id)}"]`,$('#reader')||document);el?.scrollIntoView({block:'nearest',behavior:video?.paused?'auto':'smooth'});}}
  const subtitle=subtitleCurrent(p())?activeCue(p().subtitleTrack.cues,state.time):null;
  $('#subtitle-overlay').innerHTML=subtitle?`<span>${h(subtitle.text)}</span>${subtitle.language!=='zh'&&subtitle.chineseText?`<span class="zh">${h(subtitle.chineseText)}</span>`:''}`:'';
}
function renderContext(){if(!p()||!$('#context-shots'))return;const all=shots(p()),current=currentShot()?.index||0;$('#context-shots').innerHTML=[current-1,current,current+1].map((index,i)=>{const shot=all[index],img=state.thumbs.find(x=>x.index===index)?.url;return shot?`<button class="context-shot ${i===1?'is-current':''}" data-seek="${shot.start}">${img?`<img src="${h(img)}" alt="${i===0?'前一镜':i===1?'当前镜头':'后一镜'}">`:'<div class="thumb-placeholder"></div>'}<span class="caption"><span>${i===0?'前一镜':i===1?'当前镜头':'后一镜'}</span><span>${(shot.end-shot.start).toFixed(2)}s</span></span></button>`:'<div></div>'}).join('');}

function renderTimeline(){
  const node=$('#timeline');if(!p()){node.innerHTML='<div class="empty-timeline">导入视频后，在这里拆解镜头、字幕与自己的发现。</div>';return;}
  const all=shots(p()),oldScroll=$('#timeline-scroll')?.scrollLeft||0;
  node.innerHTML=`<div class="timeline-toolbar"><h3>镜头时间轴</h3><span class="small muted">${all.length} 镜头</span><span class="grow"></span>${button('detect','⌕ 识别切镜')}${button('split','✂ 拆分','','在播放头拆分 B')}${button('merge','合并','','与前一镜合并')}${button('range-in','I 入点',state.rangeIn!==null?'active':'quiet')}${button('range-out','O 出点',state.rangeOut!==null?'active':'quiet')}${button('clear-range','清除区间','quiet')}${button('undo','↶','quiet','撤销 Ctrl+Z')}<span class="small muted">缩放</span><input id="zoom" type="range" min="1" max="12" step="0.1" value="${state.zoom}" aria-label="时间轴缩放"></div><div class="timeline-body"><div class="track-labels"><div class="shot-label">▥ 镜头</div><div class="wave-label" style="color:var(--sound)">▥ 原声</div><div class="sub-label" style="color:var(--subtitle)">▱ 字幕</div>${tracks.map(t=>`<div class="note-label" style="color:${t.color}">${t.short}</div>`).join('')}</div><div class="timeline-scroll" id="timeline-scroll"><div class="timeline-inner" id="timeline-inner"><div class="ruler" id="ruler"></div><div class="shot-row">${all.map(shot=>{const img=state.thumbs.find(x=>x.index===shot.index)?.url;return `<button class="shot-block" data-shot="${shot.index}" data-seek="${shot.start}" style="left:${shot.start/duration()*100}%;width:${(shot.end-shot.start)/duration()*100}%;${img?`background-image:url('${h(img)}')`:''}"><span>${String(shot.index+1).padStart(2,'0')}</span></button>`}).join('')}</div><canvas class="waveform" id="waveform"></canvas><div class="cue-row">${(subtitleCurrent(p())?p().subtitleTrack.cues:[]).map(c=>`<button class="cue-block" data-cue-id="${h(c.id)}" data-seek="${c.start}" title="${h(c.text)}" style="left:${c.start/duration()*100}%;width:${Math.max(0.1,(c.end-c.start)/duration()*100)}%">${h(c.text)}</button>`).join('')}</div>${tracks.map(t=>`<div class="note-row">${p().notes.filter(n=>n.track===t.id).map(n=>`<button class="note-block" data-note="${h(n.id)}" title="${h(noteTitle(n))}" style="--track:${t.color};left:${n.start/duration()*100}%;width:${Math.max(0.2,(n.end-n.start)/duration()*100)}%">● ${h(noteTitle(n))}</button>`).join('')}</div>`).join('')}<div class="range-selection hidden" id="range-selection"></div><div class="playhead" id="playhead"></div></div></div></div>`;
  sizeTimeline();$('#timeline-scroll').scrollLeft=oldScroll;
  timelineObserver?.disconnect();timelineObserver=new ResizeObserver(sizeTimeline);timelineObserver.observe($('#timeline-scroll'));
  $('#timeline-scroll').addEventListener('wheel',event=>{if(event.ctrlKey){event.preventDefault();const before=state.zoom;state.zoom=Math.max(1,Math.min(12,state.zoom*Math.exp(-event.deltaY*0.008)));const viewport=event.currentTarget;const position=event.clientX-viewport.getBoundingClientRect().left;const anchor=(viewport.scrollLeft+position)/before;sizeTimeline();viewport.scrollLeft=anchor*state.zoom-position;$('#zoom').value=state.zoom; }},{passive:false});
}
function sizeTimeline(){const scroll=$('#timeline-scroll'),inner=$('#timeline-inner');if(!scroll||!p())return;inner.style.width=Math.max(1,scroll.clientWidth*state.zoom)+'px';const intervals=[.1,.25,.5,1,2,5,10,15,30,60,120,300,600,1800],step=intervals.find(x=>x/duration()*inner.clientWidth>=72)||3600;let html='';for(let t=0;t<duration();t+=step)html+=`<span class="tick" style="left:${t/duration()*100}%">${t<60?`${Number(t.toFixed(2))} s`:`${Math.floor(t/60)}:${String(Math.round(t%60)).padStart(2,'0')}`}</span>`;$('#ruler').innerHTML=html;drawWaveform();const range=$('#range-selection');if(state.rangeIn!==null&&state.rangeOut!==null){range.classList.remove('hidden');range.style.left=Math.min(state.rangeIn,state.rangeOut)/duration()*100+'%';range.style.width=Math.abs(state.rangeOut-state.rangeIn)/duration()*100+'%'}updateTime();}
function drawWaveform(){const canvas=$('#waveform');if(!canvas||!p())return;const width=canvas.clientWidth,ratio=devicePixelRatio||1;canvas.width=width*ratio;canvas.height=27*ratio;const ctx=canvas.getContext('2d');ctx.scale(ratio,ratio);ctx.fillStyle='#3c9db9';for(const place of placements(p())){const wave=state.waves.find(x=>x.clipId===place.clip.id);if(!wave?.samples.length)continue;const start=place.start/duration()*width,end=place.end/duration()*width;for(let x=start;x<end;x+=2){const time=place.clip.sourceIn+(x-start)/(end-start)*(place.end-place.start);const value=wave.samples[Math.min(wave.samples.length-1,Math.floor(time/wave.sourceDuration*wave.samples.length))]||0;const height=Math.max(1,value*24);ctx.fillRect(x,(27-height)/2,1.4,height);}}}

function cueHTML(c){return `<div class="cue" tabindex="0" role="button" data-cue-id="${h(c.id)}" data-dialogue-seek="${c.start}"><div class="cue-meta"><span>${h(c.speaker||languages[c.language]||'对白')}</span><span class="mono">${displayTime(c.start)}–${displayTime(c.end)}</span></div><div class="original">${h(c.text)}</div>${c.chineseText&&c.language!=='zh'&&c.chineseText!==c.text?`<div class="translation">${h(c.chineseText)}</div>`:''}</div>`;}
function renderReader(){const node=$('#reader');if(!node||!p())return;node.classList.toggle('hidden',state.reader==='none');if(state.reader==='none')return;const isSub=state.reader==='subtitles',analysis=p().scriptAnalyses.findLast(a=>scriptCurrent(p(),a)),cues=sharedDialogues(p(),analysis);node.innerHTML=`<div class="reader-head row spread"><strong>${isSub?'字幕':'脚本'}</strong><div class="row">${button(isSub?'generate-subtitles':'generate-script',isSub?'生成字幕':'生成脚本','quiet small')}${button('close-reader','×','quiet')}</div></div><div class="reader-tools"><div class="row">${isSub?'<span class="small muted">原文 · 中文</span>':`${button('reader-full','全文',state.readerMode==='full'?'active':'quiet')}${button('reader-dialogue','台词',state.readerMode==='dialogue'?'active':'quiet')}`}</div><label class="row small"><input id="follow" type="checkbox" ${state.follow?'checked':''}>双向跟随</label></div><div class="reader-body" id="reader-body"></div>`;
  const body=$('#reader-body');
  if(isSub){if(!subtitleCurrent(p())){body.innerHTML=`<div class="reader-empty"><div class="large-icon">▱</div><h2>听懂每一句</h2><p>识别中、英、日、韩、西、法语人声，保留原文；非中文附上中文译文。字幕与脚本台词共享。</p>${button('generate-subtitles','✦ 生成字幕','primary')}<p class="small">语音识别在本机完成。中文翻译使用你配置的 Seed 服务。</p></div>`;}else{body.innerHTML=p().subtitleTrack.cues.map(cueHTML).join('')+`<p class="small muted" style="margin-top:20px">${h(p().subtitleTrack.sourceDescription)}</p><div class="row">${button('export-srt','导出 SRT','quiet')}${button('translate-subtitles','补全中文翻译','quiet')}</div>`;}}
  else if(state.readerMode==='dialogue'){body.innerHTML=cues.length?cues.map(cueHTML).join(''):`<div class="reader-empty"><h2>台词与画面，同步阅读</h2><p>先生成字幕，脚本会直接复用同一份原文、译文与时间。</p>${button('generate-subtitles','生成字幕','primary')}</div>`;}
  else if(!analysis){body.innerHTML=`<div class="reader-empty"><div class="large-icon">▤</div><h2>让故事完整展开</h2><p>把视频还原为故事、动作、对白与镜头表达，在画面旁逐段阅读。</p>${button('generate-script','✦ 生成完整脚本','primary')}<p class="small">视频会发送到你配置的 Seed 服务；已有字幕将作为共享台词。</p></div>`;}
  else {body.innerHTML=`<h2>${h(analysis.title)}</h2><div class="small muted mono">${displayTime(analysis.rangeStart)}–${displayTime(analysis.rangeEnd)}</div><p class="synopsis">${h(analysis.synopsis)}</p>${analysis.segments.map((seg,index)=>`<div class="script-section"><span class="segment-time" data-dialogue-seek="${seg.start}">${String(index+1).padStart(2,'0')}　${displayTime(seg.start)}–${displayTime(seg.end)}</span><p>${h(seg.screenplay||[seg.visual,seg.action].filter(Boolean).join('\n\n'))}</p>${cues.filter(c=>{if(c.end<=analysis.rangeStart||c.start>=analysis.rangeEnd)return false;const owner=analysis.segments.findIndex(s=>c.start<s.end&&c.end>s.start);return owner>=0?owner===index:index===analysis.segments.length-1}).map(cueHTML).join('')}${seg.camera?`<div class="script-details">镜头 · ${h(seg.camera)}</div>`:''}${seg.sound?`<div class="script-details">声音 · ${h(seg.sound)}</div>`:''}</div>`).join('')}<p class="small muted">${h(analysis.caveats)}</p>`;}
  currentCueId=null;updateTime();
}
function renderNotes(){const node=$('#notes');if(!node||!p())return;node.classList.toggle('hidden',!state.notes);if(!state.notes)return;const note=p().notes.find(x=>x.id===state.noteId);const shot=currentShot();node.innerHTML=`<div class="row spread"><strong>${note?'编辑标记':'镜头笔记'}</strong>${button(note?'back-notes':'notes','×','quiet')}</div>${note?`<div class="note-editor stack" style="margin-top:20px"><span class="small" style="color:var(--accent)">● 自动保存到本机</span><label>笔记类型<select id="note-track">${tracks.map(t=>`<option value="${t.id}" ${t.id===note.track?'selected':''}>${t.title}</option>`).join('')}</select></label><input id="note-title" aria-label="笔记标题" placeholder="给这个发现起个名字" value="${h(note.title)}"><div class="row"><label>起点（秒）<input id="note-start" type="number" min="0" max="${duration()}" step="0.001" value="${String(note.start)}"></label><label>终点（秒）<input id="note-end" type="number" min="0" max="${duration()}" step="0.001" value="${String(note.end)}"></label></div><label>我观察到的<textarea id="note-body" placeholder="记录画面、动作或实际听到的声音…">${h(note.body)}</textarea></label><label>原理与可复用方法<textarea id="note-takeaway" placeholder="为什么有效？如何用到自己的创作中？">${h(note.takeaway)}</textarea></label><div class="row">${button('note-review','回看这一段')}${button('note-collect','收集片段','quiet')}</div>${button('delete-note','删除标记','quiet danger')}</div>`:`<div class="row spread" style="margin:22px 0"><span class="mono" style="font-size:34px">${String((shot?.index||0)+1).padStart(2,'0')}</span><span class="muted mono">${((shot?.end||0)-(shot?.start||0)).toFixed(2)} 秒</span></div><div class="small muted mono">${displayTime(shot?.start||0)} → ${displayTime(shot?.end||0)}</div><div class="section-label">从一个问题开始</div>${tracks.map(t=>`<button class="note-track" style="--track:${t.color}" data-new-note="${t.id}"><strong>${t.title}　＋</strong><small>${t.prompt}</small></button>`).join('')}<div class="section-label">此镜头的标记</div>${p().notes.filter(n=>n.start<(shot?.end||0)&&n.end>(shot?.start||0)).map(n=>`<button class="note-item" data-note="${h(n.id)}" style="--track:${tracks.find(t=>t.id===n.track)?.color}">${h(noteTitle(n))}<small>${displayTime(n.start)}</small></button>`).join('')}`}`;updateLocks();}
function newNote(track='camera'){if(!p()||state.busy)return;checkpoint();const shot=currentShot();const note=createNote(p(),{time:state.time,track,start:shot?.start,end:shot?.end});p().notes.push(note);state.notes=true;state.noteId=note.id;touch();renderNotes();renderHeader();renderTimeline();$('#note-title')?.focus();}

async function importVideos(){const metas=await call('importVideos');if(!metas.length)return;if(metas.length===1){await finishImport(metas,false);return;}modal(withTitle('如何整理这批素材？',`<p>已选 ${metas.length} 段视频。顺序与选择的文件顺序一致。</p><label class="field">同一项目的名称<input id="import-title" value="新建拉片项目"></label><p class="help">同一时间轴：连续研究多个片段。分别建项目：每部作品独立整理。</p>`,button('import-separate','分别建项目')+button('import-combined','同一时间轴','primary')));state.pendingImport=metas;}
async function finishImport(metas,combined){const next=combined?[createProject(metas,{combined:true,title:$('#import-title')?.value||'新建拉片项目'})]:metas.map(m=>createProject([m]));state.projects.unshift(...next);closeModal();await persist();await selectProject(next[0].id);toast(`已导入 ${metas.length} 段素材`);}
function openSettings(){const c=state.settings;modal(withTitle('模型设置',`<p>人声识别在本机运行；脚本与中文翻译使用你自己的 Seed 服务。</p><label class="field">服务地址<input id="config-baseURL" placeholder="https://your-relay.example" value="${h(c.baseURL)}"></label><div class="two-col"><label class="field">AppID<input id="config-appID" value="${h(c.appID)}" autocomplete="off"></label><label class="field">Key<input id="config-key" type="password" autocomplete="off" placeholder="${c.hasKey?'已保存，留空保持原 Key':'输入你自己的 Key'}"></label></div><label class="field">模型 ID<input id="config-modelID" value="${h(c.modelID)}"></label><div class="two-col"><label class="field">接口方式<select id="config-route"><option value="passthrough" ${c.route==='passthrough'?'selected':''}>供应商透传</option><option value="chatCompletions" ${c.route==='chatCompletions'?'selected':''}>Chat Completions</option></select></label><label class="field">超时（秒）<input id="config-timeout" type="number" min="30" max="900" value="${c.timeout||300}"></label></div><label class="field">供应商模型 ID（可选）<input id="config-providerModel" value="${h(c.providerModel)}"></label><label class="inline"><input id="config-autoScript" type="checkbox" ${c.autoScript?'checked':''}>打开没有脚本的项目时自动生成（将上传视频）</label><div style="border-top:1px solid var(--line);margin-top:20px;padding-top:18px"><strong>本地字幕模型</strong><p class="help">选择 Whisper small 多语言模型，约 466 MiB。六种语言共用同一模型，不使用 small.en。</p><p class="file-path" id="model-path">${h(c.modelPath||'尚未选择模型')}</p><div class="row">${button('choose-model','选择已下载模型')}${button('download-model','官方模型下载','quiet')}</div></div><p class="help">Windows 使用当前账户的系统加密保存 Key。项目备份不包含 Key 或模型配置。</p>`,button('test-model','保存并测试连接')+button('save-settings','保存设置','primary')));state.pendingModelPath=c.modelPath;}
async function saveSettings(){const config={...state.settings};for(const name of ['baseURL','appID','modelID','providerModel','route'])config[name]=$('#config-'+name).value.trim();config.timeout=Number($('#config-timeout').value);config.key=$('#config-key').value.trim();config.autoScript=$('#config-autoScript').checked;config.modelPath=state.pendingModelPath;delete config.hasKey;state.settings=await call('saveSettings',config);}
function scriptDialog(){if(!p())return;const shot=currentShot();modal(withTitle('生成完整脚本',`<p>保留完整故事与对白，细化镜头与视听表达。已有字幕会直接复用。</p><label class="field">脚本形式<select id="script-mode"><option value="storyboard">分镜脚本</option><option value="screenplay">剧情脚本</option></select></label><label class="field">视频范围<select id="script-range"><option value="whole">整段视频</option><option value="shot">当前镜头</option><option value="custom">自定义区间</option></select></label><div class="two-col"><label class="field">起点（秒）<input id="script-start" type="number" min="0" value="0" step="0.01"></label><label class="field">终点（秒）<input id="script-end" type="number" max="${duration()}" value="${String(Math.min(duration(),300))}" step="0.01"></label></div><label class="field">特别想研究什么（可选）<textarea id="script-focus" rows="3" placeholder="例如：开场如何吸引注意、镜头怎样衔接"></textarea></label><div class="notice">所选视频和共享字幕会发送到你配置的 Seed 服务。每次最多 5 分钟；模型时间和声音描述需要回看核对。</div>`,button('close-modal','取消','quiet')+button('run-script','✦ 生成完整脚本','primary')));state.dialogShot=shot;}
function runScript(options){return runLocalMutation(async()=>{closeModal();state.reader='script';state.readerMode='full';renderHeader();renderReader();const projectId=state.id;const updated=await call('script',{projectId,...options});replaceProject(updated);if(state.id===projectId){renderReader();renderTimeline();}toast('脚本已保存');});}
function generateSubtitles(){if(!p())return;return runLocalMutation(async()=>{try{state.reader='subtitles';renderHeader();renderReader();const projectId=state.id;const result=await call('subtitles',{projectId});replaceProject(result.project);if(state.id===projectId){renderReader();renderTimeline();}toast(result.warning||'字幕已生成，与脚本台词同步',!!result.warning);}catch(e){const loaded=await call('load');state.projects=loaded.projects;renderReader();renderTimeline();throw e;}});}
function collectDialog(range){if(!p())return;const shot=currentShot();const start=range?.start??Math.min(state.rangeIn??shot.start,state.rangeOut??shot.end),end=range?.end??Math.max(state.rangeIn??shot.start,state.rangeOut??shot.end);modal(withTitle('收集到灵感空间',`<p>把不同作品的好片段放在一起，集中回看并练习节奏。</p><label class="field">片段或空间名称<input id="collect-title" value="${h(p().title+' · 灵感片段')}"></label><div class="two-col"><label class="field">起点（秒）<input id="collect-start" type="number" step="0.001" value="${String(start)}"></label><label class="field">终点（秒）<input id="collect-end" type="number" step="0.001" value="${String(end)}"></label></div><label class="field">放入<select id="collect-target"><option value="new">新建灵感空间</option>${state.projects.filter(x=>x.kind==='remix'&&x.id!==state.id).map(x=>`<option value="${h(x.id)}">${h(x.title)}</option>`).join('')}</select></label><p class="help">本测试版支持片段收集和连续预览；音乐剪辑与成片导出将在后续版本加入。</p>`,button('close-modal','取消','quiet')+button('run-collect','收集片段','primary')));}
async function collect(){const fragment=collectRange(p(),Number($('#collect-start').value),Number($('#collect-end').value),$('#collect-title').value.trim()||'灵感练习');const target=$('#collect-target').value;let destination=fragment;if(target!=='new'){destination=state.projects.find(x=>x.id===target);destination=appendCollection(destination,fragment);replaceProject(destination);}else state.projects.unshift(fragment);closeModal();await persist();await selectProject(destination.id);toast('已收集到灵感空间');}

const actions={
  import:importVideos,'import-combined':()=>finishImport(state.pendingImport,true),'import-separate':()=>finishImport(state.pendingImport,false),
  'import-backup':async()=>{const values=await call('importBackup');if(values){state.projects=values;await selectProject(values[0].id);toast('已导入项目；找不到视频时请重新关联素材。')}},
  rename:()=>modal(withTitle('重命名项目',`<label class="field">项目名称<input id="rename-title" value="${h(p().title)}"></label><p class="help">只修改作品库名称，原视频文件名保持不变。</p>`,button('close-modal','取消','quiet')+button('save-name','保存','primary'))),
  'save-name':()=>{const title=$('#rename-title').value.trim();if(!title)throw new Error('请输入项目名称');p().title=title;touch();closeModal();renderHeader();},
  play:()=>{if(!video)return;if(videoLoad||video.readyState<1)return seek(state.time,true);if(video.paused){if(state.time>=duration()-0.03)seek(0,true);else video.play().catch(e=>toast(e.message,true));}else video.pause();},
  'previous-frame':()=>seek(Math.max(0,state.time-1/locateTime(p(),Math.max(0,state.time-0.000001)).clip.frameRate),false),'next-frame':()=>seek(Math.min(duration(),state.time+1/locateTime(p(),state.time).clip.frameRate),false),
  'previous-shot':()=>{const all=shots(p()),index=currentShot()?.index||0;seek(all[Math.max(0,index-1)].start,false)},'next-shot':()=>{const all=shots(p()),index=currentShot()?.index||0;seek(all[Math.min(all.length-1,index+1)].start,false)},
  loop:()=>{state.loop=!state.loop;state.loopShot=currentShot();$('[data-action="loop"]').classList.toggle('active',state.loop)},mute:()=>{state.muted=!state.muted;if(video)video.muted=state.muted;$('[data-action="mute"]').textContent=state.muted?'静音':'声音'},
  'reader-script':()=>{state.reader=state.reader==='script'?'none':'script';renderHeader();renderReader()},'reader-subtitles':()=>{state.reader=state.reader==='subtitles'?'none':'subtitles';renderHeader();renderReader()},'close-reader':()=>{state.reader='none';renderHeader();renderReader()},'reader-full':()=>{state.readerMode='full';renderReader()},'reader-dialogue':()=>{state.readerMode='dialogue';renderReader()},
  notes:()=>{state.notes=!state.notes;renderHeader();renderNotes()},'back-notes':()=>{state.noteId=null;renderNotes()},
  'note-review':async()=>{const n=p().notes.find(x=>x.id===state.noteId);if(n){await seek(n.start,true);state.reviewEnd=n.end}},'note-collect':()=>collectDialog(p().notes.find(x=>x.id===state.noteId)),
  'delete-note':()=>{checkpoint();p().notes=p().notes.filter(x=>x.id!==state.noteId);state.noteId=null;touch();renderNotes();renderTimeline()},
  split:async()=>{checkpoint();replaceProject(addCut(p(),state.time));touch();await refreshCutThumbnails();toast('已拆分镜头')},merge:async()=>{checkpoint();replaceProject(removeCut(p(),currentShot()?.start||0));touch();await refreshCutThumbnails()},
  undo:async()=>{const last=state.undo.pop();if(!last)return;const current=state.projects.find(x=>x.id===last.id);if(!current)return;const cutsChanged=JSON.stringify(current.cuts)!==JSON.stringify(last.project.cuts);replaceProject({...current,cuts:structuredClone(last.project.cuts),notes:structuredClone(last.project.notes),updatedAt:new Date().toISOString()});editingNote=null;scheduleSave();renderLibrary();if(last.id===state.id){state.noteId=null;renderNotes();if(cutsChanged)await refreshCutThumbnails();else renderTimeline();}},
  detect:async()=>{await persist();const projectId=state.id,found=await call('detectCuts',{projectId});const selected=state.projects.find(x=>x.id===projectId);if(!selected)return;state.undo.push({id:projectId,project:structuredClone(selected)});selected.cuts=found;touch();if(state.id===projectId)await refreshCutThumbnails(projectId);toast(`识别完成：${shots(selected).length} 个镜头`)},
  'range-in':()=>{state.rangeIn=state.time;renderTimeline();toast('已设入点 '+displayTime(state.time))},'range-out':()=>{state.rangeOut=state.time;renderTimeline();toast('已设出点 '+displayTime(state.time))},'clear-range':()=>{state.rangeIn=null;state.rangeOut=null;renderTimeline()},
  collect:()=>collectDialog(),'run-collect':collect,
  settings:openSettings,'save-settings':async()=>{await saveSettings();closeModal();toast('设置已保存')},'test-model':async()=>{await saveSettings();const values=await call('models');toast(`连接成功，服务提供 ${values.length} 个模型`);},
  'choose-model':async()=>{const file=await call('chooseModel');if(file){state.pendingModelPath=file;$('#model-path').textContent=file;toast('模型校验通过，点击保存设置后生效')}},'download-model':()=>call('openGuide',{target:'model'}),
  'generate-script':scriptDialog,'run-script':()=>runScript({start:Number($('#script-start').value),end:Number($('#script-end').value),mode:$('#script-mode').value,focus:$('#script-focus').value}),
  'generate-subtitles':generateSubtitles,'translate-subtitles':async()=>{await persist();const result=await call('subtitles',{projectId:state.id,reuse:true});replaceProject(result.project);renderReader();renderTimeline();toast(result.warning||'字幕已更新',!!result.warning)},
  export:()=>modal(withTitle('导出与素材管理',`<p>项目备份保留笔记、脚本和字幕，不包含视频文件或模型 Key。</p><div class="stack">${button('export-backup','导出项目备份')}${button('export-srt','导出字幕 SRT')}${button('relink','重新关联当前素材')}</div><p class="help">视频成片导出与音乐剪辑暂未进入此 Windows 测试版。</p>`,button('close-modal','关闭','quiet'))),
  'export-backup':async()=>{await persist();if(await call('exportBackup',{projectId:state.id}))toast('项目备份已导出');closeModal()},
  'export-srt':()=>modal(withTitle('导出字幕',`<label class="field">字幕内容<select id="export-mode"><option value="bilingual">原文与中文双语</option><option value="original">只导出原文</option><option value="chinese">只导出中文</option></select></label>`,button('close-modal','取消','quiet')+button('save-srt','导出 SRT','primary'))),
  'save-srt':async()=>{if(await call('exportSRT',{projectId:state.id,mode:$('#export-mode').value}))toast('字幕已导出');closeModal()},
  relink:async()=>{const loc=locateTime(p(),state.time),updated=await call('relink',{projectId:state.id,clipId:loc.clip.id});if(updated){replaceProject(updated);closeModal();await selectProject(updated.id);}},
  cancel:()=>call('cancel'),'close-modal':closeModal,
  help:()=>modal(withTitle('从看懂一镜开始',`<p>导入视频 → 逐帧回看 → 标记观察 → 对照脚本和字幕 → 收进灵感空间。</p><div class="notice">空格：播放 / 暂停<br>← / →：前后逐帧　Shift + ← / →：切换镜头<br>B：拆分镜头　L：循环当前镜头<br>C：镜头笔记　S：声音笔记　M：叙事笔记<br>I / O：区间入点 / 出点　Ctrl + Z：撤销镜头与笔记操作<br>Ctrl + J：脚本侧栏　Esc：退出输入<br>触控板捏合 / Ctrl + 滚轮：缩放时间轴</div><p>第一版支持多素材播放、镜头标记、脚本、六语字幕和灵感收集。音乐编辑、精确关键帧图片导出和混剪成片导出将在后续版本加入。</p><p class="help">字幕：本地 Whisper small 识别人声；Seed 负责中文翻译和视频脚本。模型输出需要人工校对。</p>`,button('open-guide','查看项目说明')+button('close-modal','知道了','primary'))),
  'open-guide':()=>call('openGuide',{target:'guide'})
};

// These actions can cross an IPC boundary and later replace local project state.
for(const name of ['import','import-combined','import-separate','import-backup','detect','run-collect','translate-subtitles','relink','save-settings','test-model','choose-model','export-backup','save-srt','split','merge','undo']) {
  const action=actions[name];actions[name]=()=>runLocalMutation(action);
}

const readOnlyActions=new Set(['play','previous-frame','next-frame','previous-shot','next-shot','loop','mute','reader-script','reader-subtitles','close-reader','reader-full','reader-dialogue','notes','back-notes','cancel','close-modal','help','open-guide']);
document.addEventListener('click',async event=>{try{
  if(state.busy && (event.target.closest('[data-project],[data-new-note]') || (event.target.closest('[data-action]') && !readOnlyActions.has(event.target.closest('[data-action]').dataset.action)))) {toast('任务进行中，可继续播放和阅读；请完成或取消后再编辑。');return;}
  const project=event.target.closest('[data-project]');if(project){await runLocalMutation(()=>selectProject(project.dataset.project));return;}
  const note=event.target.closest('[data-note]');if(note){state.noteId=note.dataset.note;state.notes=true;renderNotes();renderHeader();return;}
  const create=event.target.closest('[data-new-note]');if(create){newNote(create.dataset.newNote);return;}
  const cue=event.target.closest('[data-dialogue-seek]');if(cue){if(state.follow){state.loop=false;await seek(Number(cue.dataset.dialogueSeek));}return;}
  const seekNode=event.target.closest('[data-seek]');if(seekNode){state.loop=false;await seek(Number(seekNode.dataset.seek),false);return;}
  const action=event.target.closest('[data-action]');if(action){await actions[action.dataset.action]?.();return;}
  const timeline=event.target.closest('#timeline-inner');if(timeline){const box=timeline.getBoundingClientRect();state.loop=false;await seek((event.clientX-box.left)/box.width*duration(),false);}
}catch(e){toast(e.message,true);}});
document.addEventListener('input',event=>{const id=event.target.id;if(id==='search'){state.filter=event.target.value;renderLibrary();return;}if(id==='zoom'){state.zoom=Number(event.target.value);sizeTimeline();return;}if(id.startsWith('note-')){if(state.busy){renderNotes();return;}const note=p()?.notes.find(x=>x.id===state.noteId);if(!note)return;if(editingNote!==note.id){checkpoint();editingNote=note.id;}const field=id.slice(5);if(['title','body','takeaway'].includes(field)){note[field]=event.target.value;touch();renderTimeline();}}});
document.addEventListener('change',event=>{try{const id=event.target.id;if(state.busy&&id.startsWith('note-')){renderNotes();return;}if(id==='speed'){state.rate=Number(event.target.value);video.playbackRate=state.rate;}if(id==='layout'){state.layout=event.target.value;$('.workspace').className='workspace '+(state.layout==='balanced'?'balanced':state.layout==='vertical'?'vertical':'');}if(id==='follow'){state.follow=event.target.checked;currentCueId=null;updateTime();}if(id==='script-range'){let start=0,end=Math.min(duration(),300);if(event.target.value==='shot'){start=state.dialogShot.start;end=state.dialogShot.end}else if(event.target.value==='custom'){start=state.rangeIn??state.time;end=state.rangeOut??Math.min(duration(),start+30)}$('#script-start').value=String(start);$('#script-end').value=String(end)}if(['note-start','note-end','note-track'].includes(id)){const note=p().notes.find(x=>x.id===state.noteId);if(editingNote!==note.id){checkpoint();editingNote=note.id;}const start=Number($('#note-start').value),end=Number($('#note-end').value);if(start<0||end<=start||end>duration()){renderNotes();throw new Error('笔记区间应在视频内，且终点晚于起点。')}note.start=start;note.end=end;note.track=$('#note-track').value;touch();renderTimeline();}}catch(e){toast(e.message,true);}});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'){document.activeElement?.blur();if($('#modal').open)closeModal();return;}
  if(event.target.matches('input,textarea,select')||event.target.isContentEditable||$('#modal').open)return;
  if(event.target.matches('.cue')&&['Enter',' '].includes(event.key)){event.preventDefault();event.target.click();return;}
  if(!p())return;let action;
  if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='z')action='undo';
  else if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='j')action='reader-script';
  else if(event.ctrlKey||event.metaKey||event.altKey)return;
  else action={' ':'play',ArrowLeft:event.shiftKey?'previous-shot':'previous-frame',ArrowRight:event.shiftKey?'next-shot':'next-frame',b:'split',l:'loop',i:'range-in',o:'range-out'}[event.key.length===1?event.key.toLowerCase():event.key];
  if(!state.busy && ['c','s','m'].includes(event.key.toLowerCase())){event.preventDefault();newNote({c:'camera',s:'sound',m:'story'}[event.key.toLowerCase()]);return;}
  if(action){event.preventDefault();if(state.busy&&!readOnlyActions.has(action))return;Promise.resolve(actions[action]()).catch(e=>toast(e.message,true));}
});
let closeRequest=null;
api.onBeforeClose(()=>{
  if(closeRequest)return closeRequest;
  closingRequested=true;syncBusy();
  closeRequest=(async()=>{while(pendingMutations.size)await Promise.all([...pendingMutations]);if(p())await persist();else await saveChain;})()
    .catch(error=>{closingRequested=false;closeRequest=null;syncBusy();throw error;});
  return closeRequest;
});
api.onProgress(data=>{if(typeof data.busy==='boolean')remoteBusy=data.busy;const labels={probe:'读取素材',playback:'准备播放缓存',thumbnail:'提取镜头预览',waveform:'分析原声波形',detectCuts:'识别切镜',transcribe:'本地识别人声',translate:'翻译中文字幕',script:'生成完整脚本',models:'测试连接',extractAudio:'准备音频',prepareAnalysis:'准备分析视频',import:'导入素材'};state.status=data.busy===false?(localMutationPending?'正在整理任务结果…':'本地工作区 · 内容自动保存'):data.message||`${labels[data.operation]||'正在处理'}${Number.isFinite(data.progress)?' · '+Math.round(data.progress*100)+'%':''}`;syncBusy();});
try{const loaded=await call('load');state.projects=loaded.projects;state.settings=loaded.settings;state.version=loaded.version;state.platform=loaded.platform;renderShell();if(loaded.loadError)toast(loaded.loadError,true);else if(state.projects.length)await selectProject(state.projects[0].id);document.documentElement.dataset.ready='true';}catch(e){$('#app').innerHTML=`<div class="empty"><h1>镜读未能读取本地项目</h1><p>${h(e.message)}</p></div>`;}
