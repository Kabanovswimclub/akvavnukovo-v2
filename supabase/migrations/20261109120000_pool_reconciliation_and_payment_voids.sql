begin;

alter table public.payments
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references auth.users(id),
  add column if not exists void_reason text;
alter table public.catalog_sales
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references auth.users(id),
  add column if not exists void_reason text;

create table if not exists public.pool_remittances (
  id uuid primary key default gen_random_uuid(),
  source_kind text not null check (source_kind in ('payment','sale')),
  source_id uuid not null,
  instructor_id uuid not null references public.instructors(id),
  amount numeric not null check (amount > 0),
  status text not null default 'reported' check (status in ('reported','confirmed','rejected')),
  transfer_note text,
  reported_at timestamptz not null default now(),
  reported_by uuid references auth.users(id),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  review_note text,
  unique (source_kind,source_id)
);
create index if not exists pool_remittances_instructor_idx on public.pool_remittances(instructor_id,status,reported_at desc);
alter table public.pool_remittances enable row level security;
revoke all on public.pool_remittances from public,anon,authenticated;

create or replace view private.pool_obligations as
  select 'payment'::text source_kind,p.id source_id,p.paid_at occurred_at,
         p.instructor_id,coalesce(c.name,'Клиент') client_name,
         coalesce(t.name,concat('Вручную · ',s.format,' · ',p.quantity,' занятий')) item_name,
         p.amount client_amount,coalesce(ts.pool_amount,ms.pool_amount) pool_amount,
         p.payment_method
  from public.payments p
  join public.subscriptions s on s.id=p.subscription_id
  left join public.clients c on c.id=s.client_id
  left join public.payment_tariff_snapshots ts on ts.payment_id=p.id
  left join public.tariff_items t on t.id=ts.tariff_item_id
  left join public.manual_payment_snapshots ms on ms.payment_id=p.id
  where p.voided_at is null and (ts.payment_id is not null or ms.payment_id is not null)
  union all
  select 'sale',s.id,s.sold_at,s.instructor_id,c.name,t.name,
         s.charged_amount,s.pool_amount,s.payment_method
  from public.catalog_sales s
  join public.clients c on c.id=s.client_id
  join public.tariff_items t on t.id=s.tariff_item_id
  where s.voided_at is null;
revoke all on private.pool_obligations from public,anon,authenticated;

create or replace function public.get_pool_reconciliation(p_from timestamptz,p_to timestamptz,p_instructor_id uuid default null)
returns table(source_kind text,source_id uuid,occurred_at timestamptz,client_name text,
  instructor_id uuid,instructor_name text,item_name text,client_amount numeric,pool_amount numeric,
  payment_method text,remittance_id uuid,remittance_status text,reported_at timestamptz,
  transfer_note text,reviewed_at timestamptz,review_note text)
language plpgsql stable security definer set search_path='' as $$
declare v_instructor uuid:=private.current_instructor_id();
begin
  if not private.is_manager() and v_instructor is null then raise exception 'Нет доступа'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Выберите корректный период'; end if;
  return query
  select o.source_kind,o.source_id,o.occurred_at,o.client_name,o.instructor_id,i.name,
         o.item_name,o.client_amount,o.pool_amount,o.payment_method,r.id,r.status,
         r.reported_at,r.transfer_note,r.reviewed_at,r.review_note
  from private.pool_obligations o
  join public.instructors i on i.id=o.instructor_id
  left join public.pool_remittances r on r.source_kind=o.source_kind and r.source_id=o.source_id
  where o.occurred_at between p_from and p_to
    and (case when private.is_manager() then p_instructor_id is null or o.instructor_id=p_instructor_id
              else o.instructor_id=v_instructor end)
  order by o.occurred_at desc,o.source_id;
end $$;
revoke all on function public.get_pool_reconciliation(timestamptz,timestamptz,uuid) from public,anon;
grant execute on function public.get_pool_reconciliation(timestamptz,timestamptz,uuid) to authenticated;

create or replace function public.get_pool_overdue_count()
returns integer language plpgsql stable security definer set search_path='' as $$
declare v_count integer;
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  select count(*)::integer into v_count
  from private.pool_obligations o
  left join public.pool_remittances r on r.source_kind=o.source_kind and r.source_id=o.source_id
  where o.occurred_at >= '2026-11-09 00:00:00+03'::timestamptz
    and o.occurred_at < ((now() at time zone 'Europe/Moscow')::date at time zone 'Europe/Moscow')
    and o.pool_amount>0 and coalesce(r.status,'')<>'confirmed';
  return v_count;
end $$;
revoke all on function public.get_pool_overdue_count() from public,anon;
grant execute on function public.get_pool_overdue_count() to authenticated;

create or replace function public.report_pool_remittance(p_source_kind text,p_source_id uuid,p_transfer_note text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_source record;v_existing public.pool_remittances;v_id uuid;
begin
  select * into v_source from private.pool_obligations
  where source_kind=p_source_kind and source_id=p_source_id;
  if not found then raise exception 'Оплата не найдена или отменена'; end if;
  if v_source.pool_amount<=0 then raise exception 'Для этой оплаты нет суммы бассейну'; end if;
  if not private.is_manager() and v_source.instructor_id is distinct from private.current_instructor_id() then
    raise exception 'Нет доступа к оплате'; end if;
  select * into v_existing from public.pool_remittances
    where source_kind=p_source_kind and source_id=p_source_id for update;
  if found then
    if v_existing.status<>'rejected' then raise exception 'Перевод уже отмечен'; end if;
    update public.pool_remittances set status='reported',amount=v_source.pool_amount,
      transfer_note=nullif(trim(p_transfer_note),''),reported_at=now(),reported_by=auth.uid(),
      reviewed_at=null,reviewed_by=null,review_note=null
    where id=v_existing.id returning id into v_id;
  else
    insert into public.pool_remittances(source_kind,source_id,instructor_id,amount,transfer_note,reported_by)
    values(p_source_kind,p_source_id,v_source.instructor_id,v_source.pool_amount,
           nullif(trim(p_transfer_note),''),auth.uid()) returning id into v_id;
  end if;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
  values(auth.uid(),'report_pool_remittance','pool_remittance',v_id,
         jsonb_build_object('source_kind',p_source_kind,'source_id',p_source_id,
                            'amount',v_source.pool_amount,'note',p_transfer_note));
  return v_id;
end $$;
revoke all on function public.report_pool_remittance(text,uuid,text) from public,anon;
grant execute on function public.report_pool_remittance(text,uuid,text) to authenticated;

create or replace function public.review_pool_remittance(p_remittance_id uuid,p_confirm boolean,p_note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_row public.pool_remittances;v_source record;
begin
  if not private.is_manager() then raise exception 'Подтверждать поступление может только управляющая'; end if;
  select * into v_row from public.pool_remittances where id=p_remittance_id for update;
  if not found or v_row.status<>'reported' then raise exception 'Перевод уже рассмотрен или не найден'; end if;
  select * into v_source from private.pool_obligations
    where source_kind=v_row.source_kind and source_id=v_row.source_id;
  if not found or v_source.pool_amount is distinct from v_row.amount then
    raise exception 'Оплата изменилась; проверьте перевод'; end if;
  if not p_confirm and nullif(trim(coalesce(p_note,'')),'') is null then
    raise exception 'Укажите причину отклонения'; end if;
  update public.pool_remittances set status=case when p_confirm then 'confirmed' else 'rejected' end,
    reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(trim(p_note),'')
  where id=p_remittance_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
  values(auth.uid(),'review_pool_remittance','pool_remittance',p_remittance_id,
         jsonb_build_object('confirmed',p_confirm,'note',p_note,'amount',v_row.amount));
end $$;
revoke all on function public.review_pool_remittance(uuid,boolean,text) from public,anon;
grant execute on function public.review_pool_remittance(uuid,boolean,text) to authenticated;

create or replace function public.void_finance_entry(p_source_kind text,p_source_id uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare v_payment public.payments;v_sale public.catalog_sales;v_balance numeric;v_reason text:=nullif(trim(p_reason),'');
begin
  if not private.is_manager() then raise exception 'Отменять оплату может только управляющая'; end if;
  if v_reason is null then raise exception 'Укажите причину отмены'; end if;
  if p_source_kind not in ('payment','sale') then raise exception 'Неизвестный тип оплаты'; end if;
  if exists(select 1 from public.pool_remittances r where r.source_kind=p_source_kind
            and r.source_id=p_source_id and r.status in ('reported','confirmed')) then
    raise exception 'Сначала разберите отмеченный перевод бассейну'; end if;
  if p_source_kind='payment' then
    select * into v_payment from public.payments where id=p_source_id for update;
    if not found or v_payment.voided_at is not null or v_payment.amount is null then
      raise exception 'Денежная оплата не найдена или уже отменена'; end if;
    if not exists(select 1 from public.payment_tariff_snapshots where payment_id=p_source_id)
       and not exists(select 1 from public.manual_payment_snapshots where payment_id=p_source_id) then
      raise exception 'Старую оплату без снимка тарифа нужно разобрать отдельно'; end if;
    select balance into v_balance from public.subscription_balances
      where subscription_id=v_payment.subscription_id;
    if v_balance<v_payment.quantity then
      raise exception 'Занятия уже использованы. Сначала внесите правильный абонемент'; end if;
    update public.payments set voided_at=now(),voided_by=auth.uid(),void_reason=v_reason where id=p_source_id;
    insert into public.subscription_operations(subscription_id,instructor_id,operation,quantity,author_user_id,comment)
    values(v_payment.subscription_id,v_payment.instructor_id,'correction',-v_payment.quantity,
           auth.uid(),'[ОТМЕНА ОПЛАТЫ '||p_source_id||'] '||v_reason);
    update public.payment_requests set status='cancelled',updated_at=now()
      where payment_id=p_source_id and status='paid';
  else
    select * into v_sale from public.catalog_sales where id=p_source_id for update;
    if not found or v_sale.voided_at is not null then raise exception 'Продажа не найдена или уже отменена'; end if;
    update public.catalog_sales set voided_at=now(),voided_by=auth.uid(),void_reason=v_reason where id=p_source_id;
  end if;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
  values(auth.uid(),'void_finance_entry',p_source_kind,p_source_id,
         jsonb_build_object('reason',v_reason));
end $$;
revoke all on function public.void_finance_entry(text,uuid,text) from public,anon;
grant execute on function public.void_finance_entry(text,uuid,text) to authenticated;

-- Existing reports keep their signatures. Voided entries stay visible in the
-- history but contribute no revenue, pool share or refundable liability.
create or replace function public.get_manager_tariff_finance(p_from timestamptz,p_to timestamptz,p_instructor_id uuid default null)
returns table(entry_id uuid,occurred_at timestamptz,client_name text,instructor_id uuid,instructor_name text,
  item_name text,charged_amount numeric,pool_amount numeric,instructor_income numeric,payment_method text,entry_type text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  return query
  select o.source_id,o.occurred_at,o.client_name,o.instructor_id,i.name,o.item_name,
         o.client_amount,o.pool_amount,o.client_amount-o.pool_amount,o.payment_method,
         case when o.source_kind='sale' then 'Услуга или товар' else 'Оплата занятий' end
  from private.pool_obligations o join public.instructors i on i.id=o.instructor_id
  where o.occurred_at between p_from and p_to
    and (p_instructor_id is null or o.instructor_id=p_instructor_id)
  order by o.occurred_at desc;
end $$;

create or replace function public.get_my_tariff_finance(p_from timestamptz,p_to timestamptz)
returns table(entry_id uuid,occurred_at timestamptz,client_name text,item_name text,
  charged_amount numeric,pool_amount numeric,instructor_income numeric,payment_method text,entry_type text)
language plpgsql stable security definer set search_path='' as $$
declare v_instructor uuid:=private.current_instructor_id();
begin
  if v_instructor is null then raise exception 'Профиль инструктора не найден'; end if;
  return query
  select o.source_id,o.occurred_at,o.client_name,o.item_name,o.client_amount,
         o.pool_amount,o.client_amount-o.pool_amount,o.payment_method,
         case when o.source_kind='sale' then 'Услуга или товар' else 'Оплата занятий' end
  from private.pool_obligations o
  where o.instructor_id=v_instructor and o.occurred_at between p_from and p_to
  order by o.occurred_at desc;
end $$;

create or replace function public.get_payment_journal(p_instructor_id uuid default null)
returns table(payment_id uuid,paid_at timestamptz,client_ids uuid[],client_names text,
  instructor_id uuid,instructor_name text,format text,duration_minutes integer,
  quantity numeric,amount numeric,comment text,operation_kind text,payment_method text)
language plpgsql stable security definer set search_path='' as $$
declare v_role public.app_role;v_own uuid;v_filter uuid;
begin
  select u.role,u.instructor_id into v_role,v_own from public.app_users u where u.id=auth.uid();
  if v_role is null then raise exception 'Нет доступа'; end if;
  v_filter:=case when v_role='instructor' then v_own else p_instructor_id end;
  return query
  select p.id,p.paid_at,o.client_ids,o.client_names,p.instructor_id,
         coalesce(i.name,'Инструктор не указан'),s.format,s.duration_minutes,
         p.quantity,case when p.voided_at is null then p.amount else null::numeric end,
         case when p.voided_at is null then p.comment
              else concat('Отменено: ',p.void_reason,' · исходная сумма ',p.amount,' ₽') end,
         case when p.voided_at is not null then 'voided'
              when p.amount is not null then 'payment'
              when coalesce(p.comment,'') ilike '%начальн%' then 'initial' else 'correction' end,
         p.payment_method
  from public.payments p join public.subscriptions s on s.id=p.subscription_id
  left join public.instructors i on i.id=p.instructor_id
  cross join lateral(select array_agg(c.id order by c.name) client_ids,
    string_agg(c.name,', ' order by c.name) client_names from public.clients c
    where c.id=s.client_id or exists(select 1 from public.subscription_group_members gm
      where gm.group_id=s.group_id and gm.client_id=c.id)) o
  where v_filter is null or p.instructor_id=v_filter
  union all
  select x.id,x.sold_at,array[x.client_id],c.name,x.instructor_id,i.name,t.name,
         null::integer,0::numeric,
         case when x.voided_at is null then x.charged_amount else null::numeric end,
         case when x.voided_at is null then x.comment
              else concat('Отменено: ',x.void_reason,' · исходная сумма ',x.charged_amount,' ₽') end,
         case when x.voided_at is null then 'sale' else 'voided' end,x.payment_method
  from public.catalog_sales x join public.clients c on c.id=x.client_id
  join public.instructors i on i.id=x.instructor_id
  join public.tariff_items t on t.id=x.tariff_item_id
  where v_filter is null or x.instructor_id=v_filter
  order by 2 desc;
end $$;

create or replace function public.get_client_payment_history(p_client_id uuid)
returns table(payment_id uuid,paid_at timestamptz,format text,duration_minutes integer,
  quantity numeric,amount numeric,comment text,instructor_name text,payment_method text)
language plpgsql stable security definer set search_path='' as $$
declare v_role public.app_role;v_instructor uuid;
begin
  select u.role,u.instructor_id into v_role,v_instructor from public.app_users u where u.id=auth.uid();
  if v_role not in ('manager','system_admin') and not
     (v_role='instructor' and exists(select 1 from public.client_instructors ci
       where ci.client_id=p_client_id and ci.instructor_id=v_instructor)) then
    raise exception 'Нет доступа к оплатам клиента'; end if;
  return query
  select p.id,p.paid_at,s.format,s.duration_minutes,p.quantity,p.amount,
         case when p.voided_at is null then p.comment
              else concat('ОТМЕНЕНО: ',p.void_reason,' · исходная сумма ',p.amount,' ₽') end,
         coalesce(i.name,'Инструктор не указан'),p.payment_method
  from public.payments p join public.subscriptions s on s.id=p.subscription_id
  left join public.instructors i on i.id=p.instructor_id
  where s.client_id=p_client_id or exists(select 1 from public.subscription_group_members gm
    where gm.group_id=s.group_id and gm.client_id=p_client_id)
  order by p.paid_at desc;
end $$;

create or replace function public.get_my_child_payments(p_client_id uuid)
returns table(entry_id uuid,occurred_at timestamptz,format text,duration_minutes integer,
  quantity numeric,amount numeric,comment text,instructor_name text,operation_kind text,payment_method text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.guardian_can_access_client(p_client_id) then raise exception 'Нет доступа к клиенту'; end if;
  if not exists(select 1 from public.client_guardians cg
    where cg.guardian_id=private.current_guardian_id() and cg.client_id=p_client_id and cg.can_view_finances) then
    raise exception 'Просмотр оплат отключён'; end if;
  return query with owned as (
    select s.id,s.format,s.duration_minutes from public.subscriptions s
    where s.client_id=p_client_id or exists(select 1 from public.subscription_group_members gm
      where gm.group_id=s.group_id and gm.client_id=p_client_id)
  ), entries as (
    select p.id entry_id,p.paid_at occurred_at,o.format,o.duration_minutes,p.quantity,
           case when p.voided_at is null then p.amount else null::numeric end amount,
           case when p.voided_at is null then p.comment
                else concat('Отменено: ',p.void_reason,' · исходная сумма ',p.amount,' ₽') end comment,
           coalesce(i.name,'Инструктор не указан') instructor_name,
           case when p.voided_at is not null then 'voided'
                when p.amount is not null then 'payment'
                when coalesce(p.comment,'') ilike '%начальн%' then 'initial' else 'correction' end operation_kind,
           p.payment_method
    from public.payments p join owned o on o.id=p.subscription_id
    left join public.instructors i on i.id=p.instructor_id
    union all
    select x.id,x.occurred_at,o.format,o.duration_minutes,x.quantity,null::numeric,x.comment,
           coalesce(i.name,'Инструктор не указан'),'correction','unspecified'
    from public.subscription_operations x join owned o on o.id=x.subscription_id
    left join public.instructors i on i.id=x.instructor_id
    where x.operation='correction' and not exists(select 1 from public.payments p
      where p.subscription_id=x.subscription_id and p.paid_at=x.occurred_at and p.quantity=x.quantity)
    union all
    select s.id,s.sold_at,t.name,null::integer,0::numeric,
           case when s.voided_at is null then s.charged_amount else null::numeric end,
           case when s.voided_at is null then s.comment
                else concat('Отменено: ',s.void_reason,' · исходная сумма ',s.charged_amount,' ₽') end,
           i.name,case when s.voided_at is null then 'sale' else 'voided' end,s.payment_method
    from public.catalog_sales s join public.tariff_items t on t.id=s.tariff_item_id
    join public.instructors i on i.id=s.instructor_id where s.client_id=p_client_id
  )
  select e.entry_id,e.occurred_at,e.format,e.duration_minutes,e.quantity,e.amount,e.comment,
         e.instructor_name,e.operation_kind,e.payment_method
  from entries e order by e.occurred_at desc;
end $$;

create or replace function public.get_refund_liability(p_instructor_id uuid default null)
returns table(subscription_id uuid,client_ids uuid[],client_names text,format text,duration_minutes integer,
  balance numeric,paid_quantity numeric,refundable_quantity numeric,paid_amount numeric,
  liability_amount numeric,instructor_id uuid,instructor_name text)
language plpgsql stable security definer set search_path='' as $$
declare v_role public.app_role;v_own uuid;v_filter uuid;
begin
  select u.role,u.instructor_id into v_role,v_own from public.app_users u where u.id=auth.uid();
  if v_role is null then raise exception 'Нет доступа'; end if;
  v_filter:=case when v_role='instructor' then v_own else p_instructor_id end;
  return query with monetary as (
    select p.subscription_id,p.instructor_id,sum(p.quantity) paid_qty,sum(p.amount) paid_sum
    from public.payments p where p.voided_at is null and p.amount>0 and p.quantity>0
    group by p.subscription_id,p.instructor_id
  ), totals as (select m.subscription_id,sum(m.paid_qty) total_qty from monetary m group by m.subscription_id),
  base as (
    select b.subscription_id,b.client_id,b.group_id,b.format,b.duration_minutes,b.balance,t.total_qty,
           least(greatest(b.balance,0),t.total_qty) refundable_qty
    from public.subscription_balances b join totals t on t.subscription_id=b.subscription_id
    where b.balance>0 and t.total_qty>0
  )
  select x.subscription_id,o.client_ids,o.client_names,x.format,x.duration_minutes,x.balance,
         m.paid_qty,x.refundable_qty,m.paid_sum,round(m.paid_sum*(x.refundable_qty/x.total_qty),2),
         m.instructor_id,coalesce(i.name,'Инструктор не указан')
  from base x join monetary m on m.subscription_id=x.subscription_id
  left join public.instructors i on i.id=m.instructor_id
  cross join lateral(select array_agg(c.id order by c.name) client_ids,
    string_agg(c.name,', ' order by c.name) client_names from public.clients c
    where c.id=x.client_id or exists(select 1 from public.subscription_group_members gm
      where gm.group_id=x.group_id and gm.client_id=c.id)) o
  where v_filter is null or m.instructor_id=v_filter
  order by o.client_names,x.format,x.duration_minutes;
end $$;

create or replace function public.get_client_lesson_package_progress(p_client_id uuid)
returns table(lesson_id uuid, lesson_number integer, total integer)
language sql stable security invoker set search_path = '' as $$
  with target_subscriptions as (
    select distinct lp.subscription_id
    from public.lesson_participants lp
    where lp.client_id = p_client_id and lp.subscription_id is not null
  ),
  payment_steps as (
    select p.id, p.subscription_id, p.quantity, p.amount,
           sum(p.quantity) over (
             partition by p.subscription_id order by p.paid_at, p.id
             rows unbounded preceding
           ) as credit_end,
           sum(case when p.quantity > 0 then 1 else 0 end) over (
             partition by p.subscription_id order by p.paid_at, p.id
             rows unbounded preceding
           ) as package_block
    from public.payments p
    join target_subscriptions t on t.subscription_id = p.subscription_id where p.voided_at is null
  ),
  payment_totals as (
    select subscription_id, sum(quantity) as quantity,
           bool_and(quantity = trunc(quantity)) as whole_visits,
           min(credit_end) >= 0 as nonnegative_credits
    from payment_steps
    group by subscription_id
  ),
  operation_totals as (
    select o.subscription_id, sum(o.quantity) as quantity
    from public.subscription_operations o
    join target_subscriptions t on t.subscription_id = o.subscription_id
    where o.operation in ('payment', 'correction')
    group by o.subscription_id
  ),
  safe_subscriptions as (
    select p.subscription_id
    from payment_totals p
    join operation_totals o on o.subscription_id = p.subscription_id
    where p.quantity = o.quantity and p.whole_visits and p.nonnegative_credits
  ),
  package_intervals as (
    select subscription_id,
           (array_agg(id) filter (where quantity > 0))[1] as payment_id,
           max(amount) filter (where quantity > 0) as amount,
           max(quantity) filter (where quantity > 0) as nominal_quantity,
           max(credit_end - quantity) filter (where quantity > 0) as start_slot,
           min(credit_end) as end_slot
    from payment_steps
    group by subscription_id, package_block
  ),
  chronological_lessons as (
    select lp.lesson_id, lp.client_id, lp.subscription_id,
           row_number() over (
             partition by lp.subscription_id
             order by l.starts_at, l.id, lp.client_id
           ) as visit_number
    from public.lesson_participants lp
    join target_subscriptions t on t.subscription_id = lp.subscription_id
    join public.lessons l on l.id = lp.lesson_id
    where (l.status <> 'cancelled' or l.charged_on_cancel)
      and not coalesce(l.first_visit_complimentary, false)
  ),
  assigned_lessons as (
    select lp.lesson_id, lp.client_id, p.amount,
           row_number() over (
             partition by p.id order by l.starts_at, l.id, lp.client_id
           )::integer as lesson_number,
           p.quantity::integer as total
    from public.lesson_participants lp
    join target_subscriptions t on t.subscription_id = lp.subscription_id
    join public.payments p on p.id = lp.package_payment_id
      and p.subscription_id = lp.subscription_id and p.voided_at is null
    join public.lessons l on l.id = lp.lesson_id
    where l.status <> 'cancelled' or l.charged_on_cancel
  )
  select c.lesson_id,
         case when s.subscription_id is null then a.lesson_number
              when i.payment_id is not null then (c.visit_number - i.start_slot)::integer
              when a.amount is null then a.lesson_number
              else null end as lesson_number,
         case when s.subscription_id is null then a.total
              when i.payment_id is not null then i.nominal_quantity::integer
              when a.amount is null then a.total
              else null end as total
  from chronological_lessons c
  left join safe_subscriptions s on s.subscription_id = c.subscription_id
  left join package_intervals i on i.subscription_id = s.subscription_id
    and i.amount is not null and i.nominal_quantity > 0
    and c.visit_number > i.start_slot and c.visit_number <= i.end_slot
  left join assigned_lessons a on a.lesson_id = c.lesson_id and a.client_id = c.client_id
  where c.client_id = p_client_id and public.has_access()
    and (s.subscription_id is null and a.lesson_number is not null
         or i.payment_id is not null
         or s.subscription_id is not null and a.amount is null and a.lesson_number is not null);
$$;


select pg_notify('pgrst','reload schema');
commit;
