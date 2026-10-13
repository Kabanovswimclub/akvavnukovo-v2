begin;

create table public.lesson_change_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('move','cancel','create')),
  lesson_id uuid references public.lessons(id),
  instructor_id uuid not null references public.instructors(id),
  client_id uuid not null references public.clients(id),
  subscription_id uuid references public.subscriptions(id),
  proposed_start timestamptz,
  duration_minutes integer,
  lesson_format text,
  cancellation_reason text,
  charged_on_cancel boolean,
  reason text not null check (length(trim(reason)) > 0),
  original_snapshot jsonb,
  applied_snapshot jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_comment text,
  applied_lesson_id uuid references public.lessons(id),
  constraint lesson_change_request_shape check (
    (kind = 'create' and lesson_id is null and proposed_start is not null
      and duration_minutes in (30,45,60) and lesson_format is not null)
    or (kind = 'move' and lesson_id is not null and proposed_start is not null)
    or (kind = 'cancel' and lesson_id is not null and cancellation_reason is not null
      and charged_on_cancel is not null)
  )
);
create unique index lesson_change_one_pending_per_lesson
  on public.lesson_change_requests(lesson_id) where status = 'pending' and lesson_id is not null;
create unique index lesson_change_one_pending_creation
  on public.lesson_change_requests(instructor_id,client_id,proposed_start)
  where status = 'pending' and kind = 'create';
create index lesson_change_status_created_idx on public.lesson_change_requests(status,created_at desc);
create index lesson_change_instructor_created_idx on public.lesson_change_requests(instructor_id,created_at desc);
alter table public.lesson_change_requests enable row level security;
revoke all on public.lesson_change_requests from public,anon,authenticated;

-- The table cannot be written directly. An instructor may still confirm a
-- completed lesson; only schedule/charge-affecting edits require approval.
create or replace function private.protect_historical_lesson()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if private.is_manager() then return new; end if;
  if tg_op = 'INSERT' then
    if new.starts_at < now() then
      raise exception 'Занятие в прошлом можно добавить только через согласование';
    end if;
  elsif (old.starts_at < now() or new.starts_at < now())
    and (new.starts_at,new.ends_at,new.status,new.cancellation_reason,new.charged_on_cancel)
       is distinct from
        (old.starts_at,old.ends_at,old.status,old.cancellation_reason,old.charged_on_cancel) then
    raise exception 'Изменение прошедшего занятия требует согласования';
  end if;
  return new;
end $$;
revoke all on function private.protect_historical_lesson() from public,anon,authenticated;
create trigger protect_historical_lesson before insert or update on public.lessons
for each row execute function private.protect_historical_lesson();

create or replace function private.lesson_approval_snapshot(p_lesson_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'starts_at',l.starts_at,'ends_at',l.ends_at,'status',l.status,
    'charged_on_cancel',l.charged_on_cancel,'format',l.format,
    'first_visit_complimentary',l.first_visit_complimentary,
    'participants',coalesce((select jsonb_agg(jsonb_build_object(
      'client_id',lp.client_id,'subscription_id',lp.subscription_id)
      order by lp.client_id) from public.lesson_participants lp where lp.lesson_id=l.id),'[]'::jsonb)
  ) from public.lessons l where l.id=p_lesson_id;
$$;
revoke all on function private.lesson_approval_snapshot(uuid) from public,anon,authenticated;

create or replace function public.submit_lesson_change_request(
  p_kind text, p_lesson_id uuid default null, p_instructor_id uuid default null,
  p_client_id uuid default null, p_subscription_id uuid default null,
  p_date date default null, p_time time default null, p_duration integer default null,
  p_format text default null, p_reason text default null,
  p_cancellation_reason text default null, p_charged_on_cancel boolean default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_lesson public.lessons; v_id uuid; v_start timestamptz; v_instructor uuid;
  v_client uuid; v_subscription uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception 'Требуется вход в приложение'; end if;
  if p_kind not in ('move','cancel','create') then raise exception 'Неизвестное действие'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Укажите причину исправления'; end if;
  if p_kind = 'create' then
    if p_instructor_id is null or p_client_id is null or p_date is null or p_time is null then
      raise exception 'Укажите инструктора, клиента, дату и время';
    end if;
    if not private.can_manage_instructor(p_instructor_id) then raise exception 'Недостаточно прав'; end if;
    if p_duration not in (30,45,60) or nullif(trim(coalesce(p_format,'')),'') is null then
      raise exception 'Укажите формат и длительность занятия';
    end if;
    v_start := (p_date::text || ' ' || p_time::text)::timestamp at time zone 'Europe/Moscow';
    if v_start >= now() then raise exception 'Для будущего занятия используйте обычную запись'; end if;
    if exists (select 1 from public.lessons l join public.lesson_participants lp on lp.lesson_id=l.id
      where l.instructor_id=p_instructor_id and lp.client_id=p_client_id
        and l.starts_at=v_start and l.status<>'cancelled') then
      raise exception 'Такое занятие уже есть в расписании';
    end if;
    v_instructor:=p_instructor_id; v_client:=p_client_id; v_subscription:=p_subscription_id;
  else
    if p_lesson_id is null then raise exception 'Выберите занятие'; end if;
    select * into v_lesson from public.lessons where id=p_lesson_id;
    if not found then raise exception 'Занятие не найдено'; end if;
    if not private.can_manage_instructor(v_lesson.instructor_id) then raise exception 'Недостаточно прав'; end if;
    if v_lesson.status='cancelled' then raise exception 'Занятие уже отменено'; end if;
    v_instructor:=v_lesson.instructor_id;
    select lp.client_id,lp.subscription_id into v_client,v_subscription
      from public.lesson_participants lp where lp.lesson_id=p_lesson_id order by lp.client_id limit 1;
    if v_client is null then raise exception 'У занятия нет клиента'; end if;
    if p_kind='move' then
      if p_date is null or p_time is null then raise exception 'Укажите новую дату и время'; end if;
      v_start:=(p_date::text || ' ' || p_time::text)::timestamp at time zone 'Europe/Moscow';
      if v_lesson.starts_at >= now() and v_start >= now() then
        raise exception 'Будущее занятие можно перенести без заявки';
      end if;
      if v_start=v_lesson.starts_at then raise exception 'Время занятия не изменилось'; end if;
    elsif v_lesson.starts_at >= now() then
      raise exception 'Будущее занятие можно отменить без заявки';
    elsif nullif(trim(coalesce(p_cancellation_reason,'')),'') is null or p_charged_on_cancel is null then
      raise exception 'Укажите причину отмены и решение о списании';
    end if;
    v_snapshot:=private.lesson_approval_snapshot(p_lesson_id);
  end if;
  insert into public.lesson_change_requests
    (kind,lesson_id,instructor_id,client_id,subscription_id,proposed_start,
     duration_minutes,lesson_format,cancellation_reason,charged_on_cancel,
     reason,original_snapshot,created_by)
  values (p_kind,p_lesson_id,v_instructor,v_client,v_subscription,v_start,
          case when p_kind='create' then p_duration else null end,
          case when p_kind='create' then lower(trim(p_format)) else null end,
          case when p_kind='cancel' then trim(p_cancellation_reason) else null end,
          case when p_kind='cancel' then p_charged_on_cancel else null end,
          trim(p_reason),v_snapshot,auth.uid()) returning id into v_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
    values(auth.uid(),'submit_lesson_change','lesson_change_request',v_id,
           jsonb_build_object('kind',p_kind,'lesson_id',p_lesson_id,'reason',trim(p_reason)));
  if private.is_manager() then
    perform public.review_lesson_change_request(v_id,true,'Внесено управляющей');
  end if;
  return v_id;
end $$;
revoke all on function public.submit_lesson_change_request(text,uuid,uuid,uuid,uuid,date,time,integer,text,text,text,boolean) from public,anon;
grant execute on function public.submit_lesson_change_request(text,uuid,uuid,uuid,uuid,date,time,integer,text,text,text,boolean) to authenticated;

create or replace function public.review_lesson_change_request(
  p_request_id uuid, p_approve boolean, p_comment text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.lesson_change_requests; v_lesson public.lessons; v_part record;
  v_result uuid; v_start_local timestamp; v_current jsonb;
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  select * into r from public.lesson_change_requests where id=p_request_id for update;
  if not found or r.status<>'pending' then raise exception 'Заявка уже обработана или не найдена'; end if;
  if p_approve then
    if r.kind <> 'create' then
      select * into v_lesson from public.lessons where id=r.lesson_id for update;
      if not found then raise exception 'Занятие удалено; отклоните заявку'; end if;
      v_current:=private.lesson_approval_snapshot(r.lesson_id);
      if v_current is distinct from r.original_snapshot then
        raise exception 'Занятие изменилось после подачи заявки. Проверьте его и отклоните устаревшую заявку';
      end if;
      if r.kind='move' then
        v_start_local:=r.proposed_start at time zone 'Europe/Moscow';
        perform private.move_lesson_impl(r.lesson_id,v_start_local::date,v_start_local::time);
      else
        perform private.cancel_lesson_impl(r.lesson_id,r.cancellation_reason,r.reason,r.charged_on_cancel);
      end if;
      v_result:=r.lesson_id;
    else
      if exists (select 1 from public.lessons l join public.lesson_participants lp on lp.lesson_id=l.id
        where l.instructor_id=r.instructor_id and lp.client_id=r.client_id
          and l.starts_at=r.proposed_start and l.status<>'cancelled') then
        raise exception 'Такое занятие уже добавлено. Отклоните дублирующую заявку';
      end if;
      v_start_local:=r.proposed_start at time zone 'Europe/Moscow';
      v_lesson:=private.create_lesson_impl(r.instructor_id,r.client_id,r.subscription_id,
        v_start_local::date,v_start_local::time,r.duration_minutes,r.lesson_format);
      v_result:=v_lesson.id;
      if v_lesson.ends_at <= now() then
        for v_part in select lp.subscription_id from public.lesson_participants lp
          where lp.lesson_id=v_result and lp.subscription_id is not null loop
          insert into public.subscription_operations
            (subscription_id,operation,quantity,lesson_id,author_user_id,comment,occurred_at)
          values(v_part.subscription_id,'lesson_charge',1,v_result,auth.uid(),
                 'Добавлено прошедшее занятие после согласования',now());
        end loop;
      end if;
    end if;
  end if;
  update public.lesson_change_requests
    set status=case when p_approve then 'approved' else 'rejected' end,
        reviewed_by=auth.uid(),reviewed_at=now(),review_comment=nullif(trim(p_comment),''),
        applied_lesson_id=case when p_approve then v_result else null end,
        applied_snapshot=case when p_approve then private.lesson_approval_snapshot(v_result) else null end
  where id=r.id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,before_data,after_data)
  values(auth.uid(),case when p_approve then 'approve_lesson_change' else 'reject_lesson_change' end,
         'lesson_change_request',r.id,r.original_snapshot,
         jsonb_build_object('kind',r.kind,'lesson_id',v_result,'comment',p_comment));
  if not private.is_manager() or r.created_by<>auth.uid() then
    perform private.queue_instructor_event(r.instructor_id,r.client_id,'historical_change_answered',
      case when p_approve then 'Исправление занятия одобрено' else 'Исправление занятия отклонено' end,
      r.reason,'/?staff_lesson='||coalesce(v_result,r.lesson_id)::text,
      'staff:historical-change:'||r.id||':'||case when p_approve then 'approved' else 'rejected' end);
  end if;
  return v_result;
end $$;
revoke all on function public.review_lesson_change_request(uuid,boolean,text) from public,anon;
grant execute on function public.review_lesson_change_request(uuid,boolean,text) to authenticated;

create or replace function public.get_lesson_change_requests(p_history boolean default false)
returns table(id uuid,kind text,lesson_id uuid,instructor_id uuid,instructor_name text,
  client_id uuid,client_name text,subscription_id uuid,proposed_start timestamptz,
  duration_minutes integer,lesson_format text,cancellation_reason text,
  charged_on_cancel boolean,reason text,original_snapshot jsonb,applied_snapshot jsonb,
  status text,created_at timestamptz,reviewed_at timestamptz,review_comment text,
  applied_lesson_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare v_manager boolean:=private.is_manager(); v_instructor uuid:=private.current_instructor_id();
begin
  if not v_manager and v_instructor is null then raise exception 'Недостаточно прав'; end if;
  return query select r.id,r.kind,r.lesson_id,r.instructor_id,i.name,r.client_id,c.name,
    r.subscription_id,r.proposed_start,r.duration_minutes,r.lesson_format,
    r.cancellation_reason,r.charged_on_cancel,r.reason,r.original_snapshot,
    r.applied_snapshot,r.status,r.created_at,r.reviewed_at,r.review_comment,r.applied_lesson_id
  from public.lesson_change_requests r
  join public.instructors i on i.id=r.instructor_id
  join public.clients c on c.id=r.client_id
  where (v_manager and (r.status<>'pending')=p_history)
     or (not v_manager and r.instructor_id=v_instructor)
  order by r.created_at desc limit 200;
end $$;
revoke all on function public.get_lesson_change_requests(boolean) from public,anon;
grant execute on function public.get_lesson_change_requests(boolean) to authenticated;

create or replace function public.get_pending_lesson_change_count()
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  return (select count(*)::integer from public.lesson_change_requests where status='pending');
end $$;
revoke all on function public.get_pending_lesson_change_count() from public,anon;
grant execute on function public.get_pending_lesson_change_count() to authenticated;

create or replace function public.get_instructor_profile_change_history()
returns table(request_id uuid,instructor_name text,proposed_changes jsonb,status text,
  created_at timestamptz,reviewed_at timestamptz,review_comment text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  return query select r.id,i.name,r.proposed_changes,r.status,r.created_at,r.reviewed_at,r.review_comment
    from public.instructor_profile_change_requests r
    join public.instructors i on i.id=r.instructor_id
    where r.status<>'pending' order by r.reviewed_at desc limit 200;
end $$;
revoke all on function public.get_instructor_profile_change_history() from public,anon;
grant execute on function public.get_instructor_profile_change_history() to authenticated;

-- Past lessons entered for bookkeeping must not send a fresh booking notice.
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
  where l.id=new.lesson_id and l.status='scheduled' and l.starts_at>=now()
  on conflict(idempotency_key) where idempotency_key is not null do nothing;
  return new;
end $$;

select pg_notify('pgrst','reload schema');
commit;
