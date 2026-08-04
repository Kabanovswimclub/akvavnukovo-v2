import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.50.0';

const DEFAULT_URL = 'https://xzaekznycyingdiiecxm.supabase.co';
const state = { client:null, instructors:[], selectedInstructor:'', clients:[], lessons:[] };
const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, x => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x]));
const dateOnly = d => new Date(d).toISOString().slice(0,10);
const formatDate = d => new Intl.DateTimeFormat('ru-RU',{dateStyle:'medium',timeStyle:'short'}).format(new Date(d));

function show(id){ ['setup','auth','workspace'].forEach(x => $(x).classList.toggle('hidden', x !== id)); }
function config(){ return { url:localStorage.getItem('akv_url') || DEFAULT_URL, key:localStorage.getItem('akv_key') || '' }; }

async function start(){
  const c=config();
  if(!c.key){ $('supabase-url').value=c.url; show('setup'); return; }
  state.client=createClient(c.url,c.key);
  const {data:{session}}=await state.client.auth.getSession();
  if(session) await openWorkspace(session); else show('auth');
}

async function openWorkspace(session){
  $('user-email').textContent=session.user.email ? ' · '+session.user.email : '';
  show('workspace'); $('schedule-date').value=dateOnly(new Date());
  await loadReferenceData(); await loadSchedule();
}

async function loadReferenceData(){
  const [i,c] = await Promise.all([
    state.client.from('instructors').select('id,name,status').eq('status','active').order('name'),
    state.client.from('clients').select('id,name,birth_date,phone,archived').eq('archived',false).order('name')
  ]);
  if(i.error) throw i.error; if(c.error) throw c.error;
  state.instructors=i.data||[]; state.clients=c.data||[];
  $('instructor-select').innerHTML=state.instructors.map(x=>`<option value="${x.id}">${esc(x.name)}</option>`).join('');
  state.selectedInstructor=state.instructors[0]?.id||'';
  $('instructor-select').value=state.selectedInstructor; renderClients();
}

async function loadSchedule(){
  $('data-error').textContent='';
  const day=$('schedule-date').value, from=new Date(day+'T00:00:00'), to=new Date(from); to.setDate(to.getDate()+1);
  const {data,error}=await state.client.from('lessons').select('id,starts_at,ends_at,format,status,cancellation_reason,lesson_participants(client_id,clients(name))').eq('instructor_id',state.selectedInstructor).gte('starts_at',from.toISOString()).lt('starts_at',to.toISOString()).order('starts_at');
  if(error){$('data-error').textContent=error.message;return;} state.lessons=data||[]; renderSchedule();
}

function renderSchedule(){
  const el=$('schedule-list'); if(!state.lessons.length){el.innerHTML='<div class="empty">На этот день занятий нет</div>';return;}
  el.innerHTML=state.lessons.map(x=>{const names=(x.lesson_participants||[]).map(p=>p.clients?.name).filter(Boolean).join(', ')||'Клиент не указан';return `<article class="card ${x.status==='cancelled'?'cancelled':''}"><strong>${esc(formatDate(x.starts_at))} — ${esc(formatDate(x.ends_at).split(', ')[1]||'')}</strong><div>${esc(names)}</div><span class="badge">${esc(x.format)}</span>${x.status==='cancelled'?`<div class="muted">Отмена: ${esc(x.cancellation_reason||'без причины')}</div>`:''}</article>`}).join('');
}

function renderClients(){
  const q=($('client-search').value||'').trim().toLowerCase(); const rows=state.clients.filter(x=>!q||x.name.toLowerCase().includes(q)||(x.phone||'').includes(q));
  $('clients-list').innerHTML=rows.map(x=>`<article class="card"><strong>${esc(x.name)}</strong><span class="muted">${esc(x.phone||'Телефон не указан')}</span></article>`).join('')||'<div class="empty">Клиенты не найдены</div>';
}

$('save-config').onclick=()=>{localStorage.setItem('akv_url',$('supabase-url').value.trim());localStorage.setItem('akv_key',$('supabase-key').value.trim());location.reload()};
$('login-form').onsubmit=async e=>{e.preventDefault();$('auth-error').textContent='';const {data,error}=await state.client.auth.signInWithPassword({email:$('email').value,password:$('password').value});if(error){$('auth-error').textContent=error.message;return}await openWorkspace(data.session)};
$('logout').onclick=async()=>{await state.client.auth.signOut();location.reload()};
$('schedule-date').onchange=loadSchedule; $('instructor-select').onchange=e=>{state.selectedInstructor=e.target.value;loadSchedule()}; $('client-search').oninput=renderClients;
document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===b));['schedule','clients'].forEach(x=>$(x).classList.toggle('hidden',x!==b.dataset.screen))});
start().catch(e=>{$('auth-error').textContent=e.message;show('auth')});
