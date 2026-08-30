alter table public.system_feature_settings
  add column if not exists lesson_created_notifications_enabled boolean not null default false,
  add column if not exists lesson_tomorrow_notifications_enabled boolean not null default true,
  add column if not exists lesson_tomorrow_notification_time time not null default '10:30',
  add column if not exists lesson_notification_channel_mode text not null default 'preferred';

alter table public.system_feature_settings drop constraint if exists system_feature_settings_lesson_notification_channel_mode_check;
alter table public.system_feature_settings add constraint system_feature_settings_lesson_notification_channel_mode_check
  check (lesson_notification_channel_mode in ('preferred','push','telegram','both'));

drop function if exists public.get_confirmation_settings();
create function public.get_confirmation_settings()
returns table(
  parent_confirmations_enabled boolean,
  instructor_confirmations_enabled boolean,
  parent_reschedule_enabled boolean,
  parent_cancellation_enabled boolean,
  lesson_created_notifications_enabled boolean,
  lesson_tomorrow_notifications_enabled boolean,
  lesson_tomorrow_notification_time time,
  lesson_notification_channel_mode text
)
language sql stable security definer set search_path='' as $$
  select s.parent_confirmations_enabled,s.instructor_confirmations_enabled,
         s.parent_reschedule_enabled,s.parent_cancellation_enabled,
         s.lesson_created_notifications_enabled,s.lesson_tomorrow_notifications_enabled,
         s.lesson_tomorrow_notification_time,s.lesson_notification_channel_mode
  from public.system_feature_settings s where s.singleton=true;
$$;
revoke all on function public.get_confirmation_settings() from public,anon;
grant execute on function public.get_confirmation_settings() to authenticated,service_role;

drop function if exists public.save_confirmation_settings(boolean,boolean,boolean,boolean);
create function public.save_confirmation_settings(
  p_parent_enabled boolean,
  p_instructor_enabled boolean,
  p_reschedule_enabled boolean,
  p_cancellation_enabled boolean,
  p_lesson_created_notifications_enabled boolean,
  p_lesson_tomorrow_notifications_enabled boolean,
  p_lesson_tomorrow_notification_time time,
  p_lesson_notification_channel_mode text
)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  if p_lesson_notification_channel_mode not in ('preferred','push','telegram','both') then
    raise exception 'Неизвестный режим доставки';
  end if;
  update public.system_feature_settings set
    parent_confirmations_enabled=coalesce(p_parent_enabled,false),
    instructor_confirmations_enabled=coalesce(p_instructor_enabled,false),
    parent_reschedule_enabled=coalesce(p_reschedule_enabled,false),
    parent_cancellation_enabled=coalesce(p_cancellation_enabled,false),
    lesson_created_notifications_enabled=coalesce(p_lesson_created_notifications_enabled,false),
    lesson_tomorrow_notifications_enabled=coalesce(p_lesson_tomorrow_notifications_enabled,false),
    lesson_tomorrow_notification_time=coalesce(p_lesson_tomorrow_notification_time,'10:30'::time),
    lesson_notification_channel_mode=p_lesson_notification_channel_mode,
    updated_at=now(),updated_by=auth.uid()
  where singleton=true;
  if not coalesce(p_parent_enabled,false) then
    update public.notifications set status='cancelled',updated_at=now()
    where event_type='lesson_reminder_repeat' and status in('pending','failed','processing');
  end if;
  if not coalesce(p_lesson_tomorrow_notifications_enabled,false) then
    update public.notifications set status='cancelled',updated_at=now()
    where event_type in('lesson_reminder_primary','lesson_reminder_repeat') and status in('pending','failed','processing');
  end if;
  if not coalesce(p_lesson_created_notifications_enabled,false) then
    update public.notifications set status='cancelled',updated_at=now()
    where event_type='lesson_created_notice' and status in('pending','failed','processing');
  end if;
end;$$;
revoke all on function public.save_confirmation_settings(boolean,boolean,boolean,boolean,boolean,boolean,time,text) from public,anon;
grant execute on function public.save_confirmation_settings(boolean,boolean,boolean,boolean,boolean,boolean,time,text) to authenticated;

create or replace function private.guardian_lesson_notice_channels(p_guardian_id uuid,p_mode text)
returns table(channel text) language sql stable security definer set search_path='' as $$
  with settings as(
    select coalesce(s.primary_channel,'push') primary_channel
    from public.guardians g left join public.guardian_notification_settings s on s.guardian_id=g.id
    where g.id=p_guardian_id
  )
  select private.available_guardian_channel(p_guardian_id,settings.primary_channel)
  from settings where p_mode='preferred' and private.available_guardian_channel(p_guardian_id,settings.primary_channel) is not null
  union all
  select 'push' from settings where p_mode in('push','both') and exists(
    select 1 from public.web_push_subscriptions w where w.guardian_id=p_guardian_id and w.active
  )
  union all
  select 'telegram' from settings where p_mode in('telegram','both') and exists(
    select 1 from public.guardians g where g.id=p_guardian_id and g.telegram_chat_id is not null
  );
$$;
revoke all on function private.guardian_lesson_notice_channels(uuid,text) from public,anon,authenticated;

create or replace function private.queue_lesson_created_notice()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_enabled boolean;v_mode text;
begin
  select s.lesson_created_notifications_enabled,s.lesson_notification_channel_mode
    into v_enabled,v_mode from public.system_feature_settings s where s.singleton;
  if not coalesce(v_enabled,false) then return new;end if;
  insert into public.notifications(client_id,guardian_id,channel,event_type,payload,status,attempts,scheduled_for,idempotency_key,created_at,updated_at)
  select new.client_id,cg.guardian_id,ch.channel,'lesson_created_notice',
    jsonb_build_object('lesson_id',l.id,'chat_id',g.telegram_chat_id,'child_name',c.name,
      'instructor_name',i.name,'starts_at',l.starts_at,'ends_at',l.ends_at,'format',l.format,'stage','created'),
    'pending',0,now(),'lesson-created:'||cg.guardian_id||':'||l.id||':'||new.client_id||':'||ch.channel,now(),now()
  from public.lessons l join public.clients c on c.id=new.client_id join public.instructors i on i.id=l.instructor_id
    join public.client_guardians cg on cg.client_id=new.client_id and cg.notifications_enabled and cg.is_primary
    join public.guardians g on g.id=cg.guardian_id and g.status='active'
    cross join lateral private.guardian_lesson_notice_channels(g.id,coalesce(v_mode,'preferred')) ch
  where l.id=new.lesson_id and l.status='scheduled'
  on conflict(idempotency_key) where idempotency_key is not null do nothing;
  return new;
end;$$;
drop trigger if exists queue_lesson_created_notice on public.lesson_participants;
create trigger queue_lesson_created_notice after insert on public.lesson_participants
for each row execute function private.queue_lesson_created_notice();

create or replace function public.queue_tomorrow_telegram_reminders()
returns integer language plpgsql security definer set search_path='' as $$
declare
  v_date date:=(now() at time zone 'Europe/Moscow')::date+1;
  v_day date:=(now() at time zone 'Europe/Moscow')::date;
  v_time time;v_mode text;v_enabled boolean;v_confirmations boolean;
  v_primary_for timestamptz;v_repeat_for timestamptz:=((v_day::text||' 18:00:00')::timestamp at time zone 'Europe/Moscow');
  v_count integer:=0;v_added integer;
begin
  select s.lesson_tomorrow_notification_time,s.lesson_notification_channel_mode,
         s.lesson_tomorrow_notifications_enabled,s.parent_confirmations_enabled
    into v_time,v_mode,v_enabled,v_confirmations from public.system_feature_settings s where s.singleton;
  if not coalesce(v_enabled,false) then return 0;end if;
  v_primary_for:=((v_day::text||' '||coalesce(v_time,'10:30'::time)::text)::timestamp at time zone 'Europe/Moscow');
  insert into public.notifications(client_id,guardian_id,channel,event_type,payload,status,attempts,scheduled_for,idempotency_key,created_at,updated_at)
  select lp.client_id,cg.guardian_id,ch.channel,'lesson_reminder_primary',
    jsonb_build_object('lesson_id',l.id,'chat_id',g.telegram_chat_id,'child_name',c.name,'instructor_name',i.name,
      'starts_at',l.starts_at,'ends_at',l.ends_at,'format',l.format,'stage','primary'),
    'pending',0,v_primary_for,'lesson-reminder:primary:'||cg.guardian_id||':'||l.id||':'||ch.channel,now(),now()
  from public.lessons l join public.lesson_participants lp on lp.lesson_id=l.id join public.clients c on c.id=lp.client_id
    join public.instructors i on i.id=l.instructor_id
    join public.client_guardians cg on cg.client_id=lp.client_id and cg.notifications_enabled and cg.is_primary
    join public.guardians g on g.id=cg.guardian_id and g.status='active'
    cross join lateral private.guardian_lesson_notice_channels(g.id,coalesce(v_mode,'preferred')) ch
  where l.status='scheduled' and (l.starts_at at time zone 'Europe/Moscow')::date=v_date
  on conflict(idempotency_key) where idempotency_key is not null do update
    set scheduled_for=excluded.scheduled_for,updated_at=now(),
        status='pending'
    where public.notifications.sent_at is null;
  get diagnostics v_added=row_count;v_count:=v_count+v_added;

  if coalesce(v_confirmations,false) then
    insert into public.notifications(client_id,guardian_id,channel,event_type,payload,status,attempts,scheduled_for,idempotency_key,created_at,updated_at)
    select lp.client_id,cg.guardian_id,ch.channel,'lesson_reminder_repeat',
      jsonb_build_object('lesson_id',l.id,'chat_id',g.telegram_chat_id,'child_name',c.name,'instructor_name',i.name,
        'starts_at',l.starts_at,'ends_at',l.ends_at,'format',l.format,'stage','repeat'),
      'pending',0,v_repeat_for,'lesson-reminder:repeat:'||cg.guardian_id||':'||l.id||':'||ch.channel,now(),now()
    from public.lessons l join public.lesson_participants lp on lp.lesson_id=l.id and lp.parent_confirmed_at is null
      join public.clients c on c.id=lp.client_id join public.instructors i on i.id=l.instructor_id
      join public.client_guardians cg on cg.client_id=lp.client_id and cg.notifications_enabled and cg.is_primary
      join public.guardians g on g.id=cg.guardian_id and g.status='active'
      join public.guardian_notification_settings s on s.guardian_id=g.id and s.repeat_if_unconfirmed
      cross join lateral private.guardian_lesson_notice_channels(g.id,coalesce(v_mode,'preferred')) ch
    where l.status='scheduled' and (l.starts_at at time zone 'Europe/Moscow')::date=v_date
    on conflict(idempotency_key) where idempotency_key is not null do update
      set scheduled_for=excluded.scheduled_for,updated_at=now(),
          status='pending'
      where public.notifications.sent_at is null;
    get diagnostics v_added=row_count;v_count:=v_count+v_added;
  end if;
  return v_count;
end;$$;
revoke all on function public.queue_tomorrow_telegram_reminders() from public,anon,authenticated;
grant execute on function public.queue_tomorrow_telegram_reminders() to service_role;

drop function if exists public.claim_telegram_lesson_reminders(integer);
create function public.claim_telegram_lesson_reminders(p_limit integer default 100)
returns table(notification_id uuid,recipient_type text,lesson_id uuid,chat_id bigint,child_name text,instructor_name text,starts_at timestamptz,ends_at timestamptz,lesson_format text,reminder_stage text,confirmation_enabled boolean)
language plpgsql security definer set search_path='' as $$
declare p_enabled boolean:=coalesce((select parent_confirmations_enabled from public.system_feature_settings where singleton),false);
        i_enabled boolean:=coalesce((select instructor_confirmations_enabled from public.system_feature_settings where singleton),false);
begin
  perform public.queue_tomorrow_telegram_reminders();perform public.queue_tomorrow_instructor_telegram_reminders();
  return query with candidates as(
    select n.id from public.notifications n where n.channel='telegram'
      and n.event_type in('lesson_created_notice','lesson_reminder_primary','lesson_reminder_repeat','instructor_lesson_reminder_24h')
      and n.status in('pending','failed') and coalesce(n.next_attempt_at,n.scheduled_for)<=now() and n.attempts<3
      and (n.event_type<>'lesson_reminder_repeat' or (p_enabled and not exists(
        select 1 from public.lesson_participants lp where lp.lesson_id=(n.payload->>'lesson_id')::uuid
          and lp.client_id=n.client_id and lp.parent_confirmed_at is not null)))
      order by n.scheduled_for,n.created_at for update skip locked limit greatest(1,least(p_limit,500))
  ),claimed as(
    update public.notifications n set status='processing',attempts=n.attempts+1,updated_at=now(),last_error=null
    from candidates c where n.id=c.id returning n.id,n.event_type,n.payload
  )
  select c.id,case when c.event_type='instructor_lesson_reminder_24h' then 'instructor' else 'parent' end,
    (c.payload->>'lesson_id')::uuid,(c.payload->>'chat_id')::bigint,c.payload->>'child_name',c.payload->>'instructor_name',
    (c.payload->>'starts_at')::timestamptz,(c.payload->>'ends_at')::timestamptz,c.payload->>'format',
    coalesce(c.payload->>'stage','primary'),
    case when c.event_type='instructor_lesson_reminder_24h' then i_enabled
         when c.event_type='lesson_created_notice' then false else p_enabled end
  from claimed c;
end;$$;
revoke all on function public.claim_telegram_lesson_reminders(integer) from public,anon,authenticated;
grant execute on function public.claim_telegram_lesson_reminders(integer) to service_role;

drop function if exists public.claim_push_lesson_reminders(integer);
create function public.claim_push_lesson_reminders(p_limit integer default 100)
returns table(notification_id uuid,lesson_id uuid,endpoint text,p256dh text,auth_secret text,child_name text,instructor_name text,starts_at timestamptz,ends_at timestamptz,detailed boolean,reminder_stage text)
language plpgsql security definer set search_path='' as $$
declare p_enabled boolean:=coalesce((select parent_confirmations_enabled from public.system_feature_settings where singleton),false);
begin
  perform public.queue_tomorrow_telegram_reminders();
  return query with candidates as(
    select n.id from public.notifications n where n.channel='push'
      and n.event_type in('lesson_created_notice','lesson_reminder_primary','lesson_reminder_repeat')
      and n.status in('pending','failed') and coalesce(n.next_attempt_at,n.scheduled_for)<=now() and n.attempts<3
      and (n.event_type<>'lesson_reminder_repeat' or (p_enabled and not exists(
        select 1 from public.lesson_participants lp where lp.lesson_id=(n.payload->>'lesson_id')::uuid
          and lp.client_id=n.client_id and lp.parent_confirmed_at is not null)))
      order by n.scheduled_for,n.created_at for update skip locked limit greatest(1,least(p_limit,500))
  ),claimed as(
    update public.notifications n set status='processing',attempts=n.attempts+1,updated_at=now(),last_error=null
    from candidates c where n.id=c.id returning n.id,n.guardian_id,n.payload
  )
  select c.id,(c.payload->>'lesson_id')::uuid,w.endpoint,w.p256dh,w.auth_secret,c.payload->>'child_name',c.payload->>'instructor_name',
    (c.payload->>'starts_at')::timestamptz,(c.payload->>'ends_at')::timestamptz,
    coalesce(s.detailed_lock_screen,false),coalesce(c.payload->>'stage','primary')
  from claimed c join public.web_push_subscriptions w on w.guardian_id=c.guardian_id and w.active
    left join public.guardian_notification_settings s on s.guardian_id=c.guardian_id;
end;$$;
revoke all on function public.claim_push_lesson_reminders(integer) from public,anon,authenticated;
grant execute on function public.claim_push_lesson_reminders(integer) to service_role;

select pg_notify('pgrst','reload schema');
