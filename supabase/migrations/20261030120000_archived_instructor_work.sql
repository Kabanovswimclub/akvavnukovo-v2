begin;

create or replace function public.resolve_archived_instructor_lesson(p_lesson_id uuid,p_action text,p_target_instructor_id uuid default null,p_reason text default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_lesson public.lessons;v_before jsonb;v_client uuid;
begin
  if not private.is_manager() then raise exception 'Недостаточно прав';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Укажите причину решения';end if;
  select * into v_lesson from public.lessons where id=p_lesson_id for update;
  if not found or v_lesson.status<>'scheduled' or v_lesson.starts_at<=now() then raise exception 'Будущее активное занятие не найдено';end if;
  if not exists(select 1 from public.instructors where id=v_lesson.instructor_id and status='archived') then raise exception 'Инструктор занятия не в архиве';end if;
  select client_id into v_client from public.lesson_participants where lesson_id=p_lesson_id order by client_id limit 1;
  if p_action='cancel' then
    perform private.cancel_lesson_impl(p_lesson_id,'Инструктор переведён в архив',p_reason,false);
  elsif p_action='transfer' then
    if p_target_instructor_id is null or not exists(select 1 from public.instructors where id=p_target_instructor_id and status='active') then raise exception 'Выберите активного инструктора';end if;
    if exists(select 1 from public.lessons other join public.lesson_participants lp on lp.lesson_id=other.id
      where other.id<>p_lesson_id and other.status='scheduled' and lp.client_id=v_client
        and other.starts_at<v_lesson.ends_at and other.ends_at>v_lesson.starts_at) then
      raise exception 'У клиента уже есть занятие в это время. Сначала проверьте расписание';
    end if;
    v_before:=to_jsonb(v_lesson);
    update public.lessons set instructor_id=p_target_instructor_id where id=p_lesson_id;
    insert into public.client_instructors(client_id,instructor_id,first_visit_at,last_visit_at)
      select lp.client_id,p_target_instructor_id,v_lesson.starts_at,v_lesson.starts_at from public.lesson_participants lp where lp.lesson_id=p_lesson_id
      on conflict(client_id,instructor_id) do update set last_visit_at=greatest(coalesce(public.client_instructors.last_visit_at,excluded.last_visit_at),excluded.last_visit_at);
    insert into public.audit_log(actor_user_id,action,entity_type,entity_id,before_data,after_data)
      values(auth.uid(),'transfer_archived_instructor_lesson','lesson',p_lesson_id,v_before,
        (select to_jsonb(l) from public.lessons l where l.id=p_lesson_id)||jsonb_build_object('reason',p_reason));
  else raise exception 'Неизвестное действие';end if;
end $$;
revoke all on function public.resolve_archived_instructor_lesson(uuid,text,uuid,text) from public,anon;
grant execute on function public.resolve_archived_instructor_lesson(uuid,text,uuid,text) to authenticated;

create or replace function private.require_active_instructor_for_new_lesson()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.instructors where id=new.instructor_id and status='active') then
    raise exception 'Нельзя записать занятие к архивному инструктору';
  end if;
  return new;
end $$;
revoke all on function private.require_active_instructor_for_new_lesson() from public,anon,authenticated;
create trigger require_active_instructor_for_new_lesson before insert on public.lessons
for each row execute function private.require_active_instructor_for_new_lesson();

commit;
