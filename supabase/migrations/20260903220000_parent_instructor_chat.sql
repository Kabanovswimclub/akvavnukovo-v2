create table public.chat_conversations(
 id uuid primary key default gen_random_uuid(),guardian_id uuid not null references public.guardians(id),client_id uuid not null references public.clients(id),instructor_id uuid not null references public.instructors(id),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(guardian_id,client_id,instructor_id)
);
create table public.chat_messages(
 id uuid primary key default gen_random_uuid(),conversation_id uuid not null references public.chat_conversations(id) on delete cascade,sender_user_id uuid not null references auth.users(id),body text not null check(length(body) between 1 and 2000),created_at timestamptz not null default now()
);
create index chat_messages_conversation_idx on public.chat_messages(conversation_id,created_at desc);
create table public.chat_reads(conversation_id uuid not null references public.chat_conversations(id) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,last_read_at timestamptz not null default now(),primary key(conversation_id,user_id));
alter table public.chat_conversations enable row level security;alter table public.chat_messages enable row level security;alter table public.chat_reads enable row level security;
revoke all on public.chat_conversations,public.chat_messages,public.chat_reads from public,anon,authenticated;

create function private.can_access_chat(p_conversation uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.chat_conversations c where c.id=p_conversation and(c.guardian_id=private.current_guardian_id() or c.instructor_id=private.current_instructor_id() or private.is_manager()))
$$;
revoke all on function private.can_access_chat(uuid) from public,anon,authenticated;

create function public.start_parent_instructor_chat(p_client_id uuid,p_instructor_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare v_g uuid:=private.current_guardian_id();v_id uuid;
begin
 if v_g is null or not private.guardian_can_access_client(p_client_id) then raise exception 'Нет доступа к ребёнку';end if;
 if not exists(select 1 from public.client_instructors ci join public.instructors i on i.id=ci.instructor_id join public.coach_public_cards cc on cc.instructor_id=i.id where ci.client_id=p_client_id and ci.instructor_id=p_instructor_id and i.status='active' and not cc.hidden_from_catalog) then raise exception 'Инструктор не назначен ребёнку';end if;
 insert into public.chat_conversations(guardian_id,client_id,instructor_id) values(v_g,p_client_id,p_instructor_id) on conflict(guardian_id,client_id,instructor_id) do update set updated_at=public.chat_conversations.updated_at returning id into v_id;
 return v_id;
end$$;

create function public.get_my_chats() returns table(conversation_id uuid,client_id uuid,client_name text,instructor_id uuid,instructor_name text,other_name text,last_message text,last_message_at timestamptz,unread_count integer) language sql stable security definer set search_path='' as $$
 select c.id,c.client_id,cl.name,c.instructor_id,i.name,case when c.guardian_id=private.current_guardian_id() then i.name else g.full_name end,
  lm.body,lm.created_at,(select count(*)::integer from public.chat_messages m where m.conversation_id=c.id and m.sender_user_id<>auth.uid() and m.created_at>coalesce(r.last_read_at,'epoch'::timestamptz))
 from public.chat_conversations c join public.clients cl on cl.id=c.client_id join public.instructors i on i.id=c.instructor_id join public.guardians g on g.id=c.guardian_id
 left join public.chat_reads r on r.conversation_id=c.id and r.user_id=auth.uid()
 left join lateral(select m.body,m.created_at from public.chat_messages m where m.conversation_id=c.id order by m.created_at desc limit 1)lm on true
 where c.guardian_id=private.current_guardian_id() or c.instructor_id=private.current_instructor_id() or private.is_manager()
 order by lm.created_at desc nulls last,c.created_at desc
$$;

create function public.get_chat_messages(p_conversation_id uuid) returns table(message_id uuid,body text,created_at timestamptz,is_mine boolean) language plpgsql stable security definer set search_path='' as $$begin
 if not private.can_access_chat(p_conversation_id) then raise exception 'Нет доступа к переписке';end if;
 return query select m.id,m.body,m.created_at,m.sender_user_id=auth.uid() from public.chat_messages m where m.conversation_id=p_conversation_id order by m.created_at;
end$$;

create function public.mark_chat_read(p_conversation_id uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if not private.can_access_chat(p_conversation_id) then raise exception 'Нет доступа к переписке';end if;
 insert into public.chat_reads values(p_conversation_id,auth.uid(),now()) on conflict(conversation_id,user_id) do update set last_read_at=now();
end$$;

create function public.send_chat_message(p_conversation_id uuid,p_body text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_text text:=trim(p_body);v_id uuid;v_c public.chat_conversations;v_sender text;v_guardian_user uuid;v_instructor_user uuid;
begin
 if not private.can_access_chat(p_conversation_id) then raise exception 'Нет доступа к переписке';end if;
 if v_text='' or length(v_text)>2000 then raise exception 'Сообщение должно содержать от 1 до 2000 символов';end if;
 select * into v_c from public.chat_conversations where id=p_conversation_id for update;
 insert into public.chat_messages(conversation_id,sender_user_id,body) values(p_conversation_id,auth.uid(),v_text) returning id into v_id;
 update public.chat_conversations set updated_at=now() where id=p_conversation_id;
 insert into public.chat_reads values(p_conversation_id,auth.uid(),now()) on conflict(conversation_id,user_id) do update set last_read_at=now();
 select u.id into v_guardian_user from public.app_users u where u.guardian_id=v_c.guardian_id and u.role='client' limit 1;
 select u.id into v_instructor_user from public.app_users u where u.instructor_id=v_c.instructor_id and u.role='instructor' limit 1;
 select case when auth.uid()=v_guardian_user then g.full_name else i.name end into v_sender from public.guardians g,public.instructors i where g.id=v_c.guardian_id and i.id=v_c.instructor_id;
 if auth.uid()=v_guardian_user and v_instructor_user is not null then
  insert into public.notifications(instructor_id,channel,event_type,payload,status,scheduled_for,idempotency_key) values(v_c.instructor_id,'push','chat_message',jsonb_build_object('message_id',v_id,'conversation_id',v_c.id,'title','Новое сообщение · АкваВнуково','body',v_sender||' · '||(select name from public.clients where id=v_c.client_id),'url','/?staff_tab=messages&chat='||v_c.id),'pending',now(),'chat:'||v_id);
 elsif auth.uid()=v_instructor_user and v_guardian_user is not null then
  insert into public.notifications(guardian_id,channel,event_type,payload,status,scheduled_for,idempotency_key) values(v_c.guardian_id,'push','chat_message',jsonb_build_object('message_id',v_id,'conversation_id',v_c.id,'title','Ответ инструктора · АкваВнуково','body',v_sender||' ответил в переписке','url','/?parent_tab=messages&chat='||v_c.id),'pending',now(),'chat:'||v_id);
 end if;
 return v_id;
end$$;

create function public.claim_chat_push(p_message_id uuid) returns table(notification_id uuid,endpoint text,p256dh text,auth_secret text,title text,body text,target_url text) language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from public.chat_messages m where m.id=p_message_id and m.sender_user_id=auth.uid()) then raise exception 'Нет доступа';end if;
 return query with claimed as(update public.notifications n set status='processing',attempts=n.attempts+1,updated_at=now() where n.event_type='chat_message' and n.payload->>'message_id'=p_message_id::text and n.status in('pending','failed') returning n.*)
 select c.id,w.endpoint,w.p256dh,w.auth_secret,c.payload->>'title',c.payload->>'body',c.payload->>'url' from claimed c left join public.web_push_subscriptions w on w.active and((c.guardian_id is not null and w.guardian_id=c.guardian_id)or(c.instructor_id is not null and w.instructor_id=c.instructor_id));
end$$;

revoke all on function public.start_parent_instructor_chat(uuid,uuid),public.get_my_chats(),public.get_chat_messages(uuid),public.mark_chat_read(uuid),public.send_chat_message(uuid,text),public.claim_chat_push(uuid) from public,anon;
grant execute on function public.start_parent_instructor_chat(uuid,uuid),public.get_my_chats(),public.get_chat_messages(uuid),public.mark_chat_read(uuid),public.send_chat_message(uuid,text),public.claim_chat_push(uuid) to authenticated;
select pg_notify('pgrst','reload schema');
