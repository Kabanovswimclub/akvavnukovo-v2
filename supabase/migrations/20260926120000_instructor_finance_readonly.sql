-- Read-only, self-scoped financial views for an instructor. Manager reports and
-- payment-writing functions remain unchanged.
create function public.get_my_tariff_catalog()
returns table(id uuid,category text,public_group text,name text,lesson_format text,
  duration_minutes integer,credit_quantity numeric,client_price numeric,pool_amount numeric,
  instructor_income numeric,template_name text,rate_source text,sort_order integer)
language plpgsql stable security definer set search_path='' as $$
declare v_instructor uuid := private.current_instructor_id();
begin
  if v_instructor is null then raise exception 'Профиль инструктора не найден'; end if;
  return query
    select i.id,i.category,i.public_group,i.name,i.lesson_format,i.duration_minutes,
      i.credit_quantity,r.client_price,r.pool_amount,r.client_price-r.pool_amount,
      t.name,case when exists(select 1 from public.instructor_tariff_override_versions o
        where o.instructor_id=v_instructor and o.tariff_item_id=i.id and o.effective_from<=now())
        then 'Индивидуальная ставка' else 'Шаблон' end,i.sort_order
    from public.tariff_items i
      cross join lateral private.resolve_tariff_rate(i.id,v_instructor,now()) r
      left join public.tariff_templates t on t.id=r.template_id
    where i.active and r.client_price is not null and r.pool_amount is not null
    order by i.sort_order;
end $$;
revoke all on function public.get_my_tariff_catalog() from public,anon;
grant execute on function public.get_my_tariff_catalog() to authenticated;

create function public.get_my_tariff_finance(p_from timestamptz,p_to timestamptz)
returns table(entry_id uuid,occurred_at timestamptz,client_name text,item_name text,
  charged_amount numeric,pool_amount numeric,instructor_income numeric,payment_method text,entry_type text)
language plpgsql stable security definer set search_path='' as $$
declare v_instructor uuid := private.current_instructor_id();
begin
  if v_instructor is null then raise exception 'Профиль инструктора не найден'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Выберите корректный период'; end if;
  return query
    select p.id,p.paid_at,coalesce(c.name,'Клиент'),t.name,
      s.charged_amount,s.pool_amount,s.instructor_income,p.payment_method,'Оплата занятий'
    from public.payment_tariff_snapshots s join public.payments p on p.id=s.payment_id
      join public.subscriptions sub on sub.id=p.subscription_id
      left join public.clients c on c.id=sub.client_id
      join public.tariff_items t on t.id=s.tariff_item_id
    where p.instructor_id=v_instructor and p.paid_at between p_from and p_to
  union all
    select s.id,s.sold_at,c.name,t.name,s.charged_amount,s.pool_amount,
      s.instructor_income,s.payment_method,case when t.category='product' then 'Товар' else 'Услуга' end
    from public.catalog_sales s join public.clients c on c.id=s.client_id
      join public.tariff_items t on t.id=s.tariff_item_id
    where s.instructor_id=v_instructor and s.sold_at between p_from and p_to
  order by 2 desc;
  -- The manual-package feature may be deployed later. Include its payments
  -- when present without making this read-only feature depend on that release.
  if to_regclass('public.manual_payment_snapshots') is not null then
    return query execute $sql$
      select p.id,p.paid_at,coalesce(c.name,'Клиент'),
        'Вручную · '||sub.format||' · '||sub.duration_minutes||' мин · '||s.quantity||' занятий',
        s.charged_amount,s.pool_amount,s.instructor_income,p.payment_method,'Ручной абонемент'
      from public.manual_payment_snapshots s join public.payments p on p.id=s.payment_id
        join public.subscriptions sub on sub.id=p.subscription_id
        left join public.clients c on c.id=sub.client_id
      where p.instructor_id=$1 and p.paid_at between $2 and $3
    $sql$ using v_instructor,p_from,p_to;
  end if;
end $$;
revoke all on function public.get_my_tariff_finance(timestamptz,timestamptz) from public,anon;
grant execute on function public.get_my_tariff_finance(timestamptz,timestamptz) to authenticated;

create function public.get_my_pending_payment_summary(p_from timestamptz,p_to timestamptz)
returns table(request_count bigint,request_amount numeric)
language plpgsql stable security definer set search_path='' as $$
declare v_instructor uuid := private.current_instructor_id();
begin
  if v_instructor is null then raise exception 'Профиль инструктора не найден'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Выберите корректный период'; end if;
  return query
    select count(*),coalesce(sum(r.amount),0)
    from public.payment_requests r
    where r.instructor_id=v_instructor and r.created_at between p_from and p_to
      and r.status in ('issued','reported');
end $$;
revoke all on function public.get_my_pending_payment_summary(timestamptz,timestamptz) from public,anon;
grant execute on function public.get_my_pending_payment_summary(timestamptz,timestamptz) to authenticated;

-- Keep the earlier manual-payment UI hidden until its server migration exists.
create function public.manual_payment_available() returns boolean
language sql stable security definer set search_path='' as $$
  select private.is_manager()
    and to_regclass('public.manual_payment_snapshots') is not null
    and to_regprocedure('public.record_manual_payment(uuid,uuid,text,integer,integer,numeric,numeric,text,text)') is not null;
$$;
revoke all on function public.manual_payment_available() from public,anon;
grant execute on function public.manual_payment_available() to authenticated;

select pg_notify('pgrst','reload schema');
