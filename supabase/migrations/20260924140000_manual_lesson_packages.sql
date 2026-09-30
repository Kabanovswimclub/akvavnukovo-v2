-- Manager-approved custom lesson packages. Keep the entered quantity and pool share
-- as immutable payment-time snapshots; never infer either from a catalog tariff.
create table public.manual_payment_snapshots (
  payment_id uuid primary key references public.payments(id),
  instructor_id uuid not null references public.instructors(id),
  quantity integer not null check (quantity between 1 and 1000),
  charged_amount numeric not null check (charged_amount > 0),
  pool_amount numeric not null check (pool_amount >= 0),
  instructor_income numeric generated always as (charged_amount - pool_amount) stored,
  captured_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
alter table public.manual_payment_snapshots enable row level security;
revoke all on public.manual_payment_snapshots from public, anon, authenticated;

alter table public.payment_requests add column manual_pool_amount numeric check (manual_pool_amount >= 0);

create function private.check_manual_package(p_client_id uuid, p_instructor_id uuid, p_format text,
  p_duration integer, p_quantity integer, p_amount numeric, p_pool_amount numeric, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$ begin
  if not private.is_manager() then raise exception 'Ручной ввод доступен только управляющей'; end if;
  if p_client_id is null or p_instructor_id is null then raise exception 'Выберите клиента и инструктора'; end if;
  if lower(trim(coalesce(p_format, ''))) not in ('индивидуальное', 'сплит', 'группа') then raise exception 'Укажите формат занятия'; end if;
  if p_duration is null or p_duration not in (30,45,60) then raise exception 'Укажите длительность 30, 45 или 60 минут'; end if;
  if p_quantity is null or p_quantity not between 1 and 1000 then raise exception 'Укажите количество занятий от 1 до 1000'; end if;
  if p_amount is null or p_amount <= 0 or p_pool_amount is null or p_pool_amount < 0 then raise exception 'Укажите сумму клиенту и сумму бассейну'; end if;
  if nullif(trim(coalesce(p_comment, '')), '') is null then raise exception 'Укажите причину ручного ввода'; end if;
end $$;
revoke all on function private.check_manual_package(uuid,uuid,text,integer,integer,numeric,numeric,text) from public,anon,authenticated;

create function public.record_manual_payment(p_client_id uuid, p_instructor_id uuid, p_format text,
  p_duration integer, p_quantity integer, p_amount numeric, p_pool_amount numeric,
  p_payment_method text, p_comment text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_subscription uuid; v_payment public.payments;
begin
  perform private.check_manual_package(p_client_id,p_instructor_id,p_format,p_duration,p_quantity,p_amount,p_pool_amount,p_comment);
  if p_payment_method not in ('cash','self_transfer') then raise exception 'Выберите наличные или полученный перевод'; end if;
  v_subscription := private.get_or_create_subscription_impl(p_client_id,p_format,p_duration,p_instructor_id);
  v_payment := private.add_payment_impl(v_subscription,p_instructor_id,p_quantity,p_amount,p_comment);
  update public.payments set payment_method=p_payment_method where id=v_payment.id;
  insert into public.manual_payment_snapshots(payment_id,instructor_id,quantity,charged_amount,pool_amount,created_by)
    values(v_payment.id,p_instructor_id,p_quantity,p_amount,p_pool_amount,auth.uid());
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
    values(auth.uid(),'record_manual_payment','payment',v_payment.id,
      jsonb_build_object('client_id',p_client_id,'instructor_id',p_instructor_id,'format',p_format,
        'duration',p_duration,'quantity',p_quantity,'amount',p_amount,'pool_amount',p_pool_amount,'reason',p_comment));
  return v_payment.id;
end $$;
revoke all on function public.record_manual_payment(uuid,uuid,text,integer,integer,numeric,numeric,text,text) from public,anon;
grant execute on function public.record_manual_payment(uuid,uuid,text,integer,integer,numeric,numeric,text,text) to authenticated;

create function public.issue_manual_payment_request(p_client_id uuid, p_instructor_id uuid, p_format text,
  p_duration integer, p_quantity integer, p_amount numeric, p_pool_amount numeric,
  p_due_at timestamptz, p_comment text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_subscription uuid; v_id uuid;
begin
  perform private.check_manual_package(p_client_id,p_instructor_id,p_format,p_duration,p_quantity,p_amount,p_pool_amount,p_comment);
  if not exists(select 1 from public.client_instructors where client_id=p_client_id and instructor_id=p_instructor_id) then
    raise exception 'Клиент не прикреплён к инструктору'; end if;
  if not exists(select 1 from public.instructors where id=p_instructor_id and payment_bank_name is not null
    and payment_sbp_phone is not null and payment_recipient_name is not null) then
    raise exception 'Сначала заполните реквизиты инструктора'; end if;
  v_subscription := private.get_or_create_subscription_impl(p_client_id,p_format,p_duration,p_instructor_id);
  insert into public.payment_requests(client_id,instructor_id,subscription_id,quantity,amount,format,
    duration_minutes,due_at,comment,manual_pool_amount)
  values(p_client_id,p_instructor_id,v_subscription,p_quantity,p_amount,lower(trim(p_format)),p_duration,
    p_due_at,trim(p_comment),p_pool_amount) returning id into v_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
    values(auth.uid(),'issue_manual_payment_request','payment_request',v_id,
      jsonb_build_object('client_id',p_client_id,'instructor_id',p_instructor_id,'format',p_format,
        'duration',p_duration,'quantity',p_quantity,'amount',p_amount,'pool_amount',p_pool_amount,'reason',p_comment));
  return v_id;
end $$;
revoke all on function public.issue_manual_payment_request(uuid,uuid,text,integer,integer,numeric,numeric,timestamptz,text) from public,anon;
grant execute on function public.issue_manual_payment_request(uuid,uuid,text,integer,integer,numeric,numeric,timestamptz,text) to authenticated;

create or replace function public.confirm_payment_request(p_request_id uuid,p_received boolean)
returns void language plpgsql security definer set search_path='' as $$
declare r public.payment_requests; p public.payments;
begin
  select * into r from public.payment_requests where id=p_request_id for update;
  if not found or not (private.is_manager() or r.instructor_id=private.current_instructor_id()) or r.status<>'reported' then
    raise exception 'Запрос не найден или не ожидает проверки'; end if;
  if p_received then
    p:=private.add_payment_impl(r.subscription_id,r.instructor_id,r.quantity,r.amount,'Оплата по запросу '||r.id);
    update public.payments set payment_method='invoice' where id=p.id;
    if r.tariff_item_id is not null then
      insert into public.payment_tariff_snapshots(payment_id,tariff_item_id,instructor_id,template_id,
        standard_client_price,charged_amount,pool_amount)
      values(p.id,r.tariff_item_id,r.instructor_id,r.tariff_template_id,r.standard_client_price,r.amount,r.pool_amount);
    elsif r.manual_pool_amount is not null then
      insert into public.manual_payment_snapshots(payment_id,instructor_id,quantity,charged_amount,pool_amount,created_by)
        values(p.id,r.instructor_id,r.quantity::integer,r.amount,r.manual_pool_amount,auth.uid());
    end if;
    update public.payment_requests set status='paid',payment_id=p.id,confirmed_at=now(),confirmed_by=auth.uid(),updated_at=now() where id=r.id;
  else
    update public.payment_requests set status='disputed',confirmed_at=now(),confirmed_by=auth.uid(),updated_at=now() where id=r.id;
  end if;
end $$;

create or replace function public.get_manager_tariff_finance(p_from timestamptz,p_to timestamptz,p_instructor_id uuid default null)
returns table(entry_id uuid,occurred_at timestamptz,client_name text,instructor_id uuid,instructor_name text,
  item_name text,charged_amount numeric,pool_amount numeric,instructor_income numeric,payment_method text,entry_type text)
language plpgsql stable security definer set search_path='' as $$ begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  return query
    select p.id,p.paid_at,coalesce(c.name,'Клиент'),p.instructor_id,i.name,t.name,
      s.charged_amount,s.pool_amount,s.instructor_income,p.payment_method,'Оплата занятий'
    from public.payment_tariff_snapshots s join public.payments p on p.id=s.payment_id
      join public.subscriptions sub on sub.id=p.subscription_id left join public.clients c on c.id=sub.client_id
      join public.instructors i on i.id=p.instructor_id join public.tariff_items t on t.id=s.tariff_item_id
    where p.paid_at between p_from and p_to and (p_instructor_id is null or p.instructor_id=p_instructor_id)
  union all
    select s.id,s.sold_at,c.name,s.instructor_id,i.name,t.name,
      s.charged_amount,s.pool_amount,s.instructor_income,s.payment_method,
      case when t.category='product' then 'Товар' else 'Услуга' end
    from public.catalog_sales s join public.clients c on c.id=s.client_id
      join public.instructors i on i.id=s.instructor_id join public.tariff_items t on t.id=s.tariff_item_id
    where s.sold_at between p_from and p_to and (p_instructor_id is null or s.instructor_id=p_instructor_id)
  union all
    select p.id,p.paid_at,coalesce(c.name,'Клиент'),p.instructor_id,i.name,
      'Вручную · '||sub.format||' · '||sub.duration_minutes||' мин · '||s.quantity||' занятий',
      s.charged_amount,s.pool_amount,s.instructor_income,p.payment_method,'Ручной абонемент'
    from public.manual_payment_snapshots s join public.payments p on p.id=s.payment_id
      join public.subscriptions sub on sub.id=p.subscription_id left join public.clients c on c.id=sub.client_id
      join public.instructors i on i.id=p.instructor_id
    where p.paid_at between p_from and p_to and (p_instructor_id is null or p.instructor_id=p_instructor_id)
  order by 2 desc;
end $$;
select pg_notify('pgrst','reload schema');
