const CACHE='akvavnukovo-shell-v1';
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('fetch',event=>{if(event.request.method==='GET'&&event.request.mode==='navigate')event.respondWith(fetch(event.request).catch(()=>caches.match('/')))});
self.addEventListener('push',event=>{let data={};try{data=event.data?.json()||{}}catch{data={body:event.data?.text()||'Новое уведомление'}}const payload=data;event.waitUntil(self.registration.showNotification(payload.title||'АкваВнуково',{body:payload.body||'Откройте личный кабинет',icon:'/akva-icon.svg',badge:'/akva-icon.svg',tag:payload.tag||'akvavnukovo',data:{url:payload.url||'/'},actions:payload.actions||[]}))});
self.addEventListener('notificationclick',event=>{event.notification.close();const target=new URL(event.notification.data?.url||'/',self.location.origin).href;event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(windows=>{for(const client of windows){if('focus'in client){client.navigate(target);return client.focus()}}return clients.openWindow(target)}))});
