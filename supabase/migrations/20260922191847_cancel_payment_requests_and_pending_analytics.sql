alter table public.payment_requests
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users(id),
  add column cancellation_reason text;

create function public.get_staff_payment_requests()
returns table(request_id uuid, client_name text, instructor_id uuid,
  instructor_name text, amount numeric, quantity numeric, format text,
  duration_minutes integer, status text, due_at timestamptz,
  parent_reported_at timestamptz, created_at timestamptz,
  cancellation_reason text)
language plpgsql stable security definer set search_path = '' as $$
declare v_instructor uuid := private.current_instructor_id();
begin
  if not private.is_manager() and v_instructor is null then
    raise exception 'Нет доступа';
  end if;
  return query
    select r.id, c.name, r.instructor_id, i.name, r.amount, r.quantity,
      r.format, r.duration_minutes, r.status, r.due_at,
      r.parent_reported_at, r.created_at, r.cancellation_reason
    from public.payment_requests r
    join public.clients c on c.id = r.client_id
    join public.instructors i on i.id = r.instructor_id
    where private.is_manager() or r.instructor_id = v_instructor
    order by r.created_at desc;
end $$;
revoke all on function public.get_staff_payment_requests() from public, anon;
grant execute on function public.get_staff_payment_requests() to authenticated;

create function public.cancel_payment_request(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.payment_requests;
begin
  if nullif(trim(p_reason), '') is null or length(trim(p_reason)) < 5 then
    raise exception 'Укажите причину отмены (не менее 5 символов)';
  end if;
  select * into r from public.payment_requests where id = p_request_id for update;
  if not found or not (private.is_manager() or r.instructor_id = private.current_instructor_id()) then
    raise exception 'Счёт не найден или нет доступа';
  end if;
  if r.status not in ('issued', 'disputed') or r.payment_id is not null then
    raise exception 'Счёт уже обрабатывается или оплачен; для проверки перевода обратитесь к управляющей';
  end if;
  update public.payment_requests
     set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
         cancellation_reason = trim(p_reason), updated_at = now()
   where id = r.id;
  insert into public.audit_log(actor_user_id, action, entity_type, entity_id,
    before_data, after_data)
  values (auth.uid(), 'cancel_payment_request', 'payment_request', r.id,
    jsonb_build_object('status', r.status, 'amount', r.amount),
    jsonb_build_object('status', 'cancelled', 'reason', trim(p_reason)));
end $$;
revoke all on function public.cancel_payment_request(uuid, text) from public, anon;
grant execute on function public.cancel_payment_request(uuid, text) to authenticated;

create function public.get_manager_open_payment_requests()
returns table(request_id uuid, client_name text, instructor_id uuid,
  instructor_name text, amount numeric, status text, created_at timestamptz,
  due_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  return query
    select r.id, c.name, r.instructor_id, i.name, r.amount, r.status,
      r.created_at, r.due_at
    from public.payment_requests r
    join public.clients c on c.id = r.client_id
    join public.instructors i on i.id = r.instructor_id
    where r.status in ('issued', 'reported')
    order by r.created_at desc;
end $$;
revoke all on function public.get_manager_open_payment_requests() from public, anon;
grant execute on function public.get_manager_open_payment_requests() to authenticated;

select pg_notify('pgrst', 'reload schema');
