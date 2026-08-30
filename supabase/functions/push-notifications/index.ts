import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import{createClient}from"@supabase/supabase-js";
import webpush from"web-push";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,content-type,apikey,x-client-info"};
const json=(b:unknown,s=200)=>new Response(JSON.stringify(b),{status:s,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(request:Request)=>{
 if(request.method==="OPTIONS")return new Response("ok",{headers:cors});
 const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const publicKey=Deno.env.get("WEB_PUSH_PUBLIC_KEY")||"",privateKey=Deno.env.get("WEB_PUSH_PRIVATE_KEY")||"";
 if(!publicKey||!privateKey)return json({error:"Web Push ещё не настроен"},500);
 const caller=createClient(url,anon,{global:{headers:{Authorization:request.headers.get("Authorization")||""}}});
 const user=await caller.auth.getUser();if(user.error||!user.data.user)return json({error:"Нужно войти"},401);
 let body:{action?:string}={};try{body=await request.json()}catch{/* empty */}
 if(body.action==="config")return json({public_key:publicKey});
 if(body.action!=="test")return json({error:"Неизвестное действие"},400);
 const service=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false}});
 const owner=await service.from("app_users").select("guardian_id,instructor_id,role").eq("id",user.data.user.id).maybeSingle();
 if(owner.error||!owner.data)return json({error:"Профиль не найден"},400);
 let query=service.from("web_push_subscriptions").select("id,endpoint,p256dh,auth_secret").eq("active",true);
 if(owner.data.guardian_id)query=query.eq("guardian_id",owner.data.guardian_id);
 else if(owner.data.instructor_id)query=query.eq("instructor_id",owner.data.instructor_id);
 else if(["manager","system_admin"].includes(owner.data.role))query=query.eq("staff_user_id",user.data.user.id);
 else return json({error:"Push для профиля недоступен"},400);
 const subscriptions=await query;if(subscriptions.error)return json({error:subscriptions.error.message},400);
 if(!subscriptions.data?.length)return json({error:"Нет подключённых устройств"},400);
 webpush.setVapidDetails("mailto:aquavnukovo@gmail.com",publicKey,privateKey);let sent=0;
 for(const item of subscriptions.data){try{await webpush.sendNotification({endpoint:item.endpoint,keys:{p256dh:item.p256dh,auth:item.auth_secret}},JSON.stringify({title:"АкваВнуково",body:"✅ Тестовое Push-уведомление. Устройство успешно подключено.",url:"/?push_test=1",tag:"akva-test"}));await service.from("web_push_subscriptions").update({last_success_at:new Date().toISOString(),last_error:null}).eq("id",item.id);sent++}catch(error){const message=error instanceof Error?error.message:String(error);await service.from("web_push_subscriptions").update({last_error:message,active:!(message.includes("410")||message.includes("404"))}).eq("id",item.id)}}
 return json({ok:true,sent});
});
