create or replace function public.get_client_payment_history(p_client_id uuid)
returns table(
  payment_id uuid,
  paid_at timestamptz,
  format text,
  duration_minutes integer,
  quantity numeric,
  amount numeric,
  comment text,
  instructor_name text,
  payment_method text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
  v_instructor_id uuid;
begin
  select u.role, u.instructor_id
    into v_role, v_instructor_id
  from public.app_users u
  where u.id = auth.uid();

  if v_role not in ('manager', 'system_admin') and not (
    v_role = 'instructor'
    and v_instructor_id is not null
    and exists (
      select 1
      from public.client_instructors ci
      where ci.client_id = p_client_id
        and ci.instructor_id = v_instructor_id
    )
  ) then
    raise exception 'Нет доступа к оплатам клиента';
  end if;

  return query
  with owned_subscriptions as (
    select s.id, s.format, s.duration_minutes
    from public.subscriptions s
    where s.client_id = p_client_id
       or exists (
         select 1
         from public.subscription_group_members gm
         where gm.group_id = s.group_id
           and gm.client_id = p_client_id
       )
  )
  select
    p.id,
    p.paid_at,
    s.format,
    s.duration_minutes,
    p.quantity,
    p.amount,
    p.comment,
    coalesce(i.name, 'Инструктор не указан'),
    p.payment_method
  from public.payments p
  join owned_subscriptions s on s.id = p.subscription_id
  left join public.instructors i on i.id = p.instructor_id
  order by p.paid_at desc;
end;
$$;

revoke all on function public.get_client_payment_history(uuid) from public, anon;
grant execute on function public.get_client_payment_history(uuid) to authenticated;

