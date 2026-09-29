-- Manager-only quantity/price overrides for an existing lesson tariff.
-- Existing catalog RPCs and all standard tariff flows remain unchanged.
create function public.record_custom_tariff_payment(
  p_client_id uuid, p_instructor_id uuid, p_tariff_item_id uuid,
  p_payment_method text, p_quantity integer, p_charged_amount numeric,
  p_override_reason text, p_comment text default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare i public.tariff_items; r record; v_subscription uuid; v_payment public.payments;
  v_pool numeric;
begin
  if not private.is_manager() then raise exception 'Изменить количество занятий может только управляющая'; end if;
  if p_payment_method not in ('cash','self_transfer') then raise exception 'Выберите способ оплаты'; end if;
  if p_quantity is null or p_quantity not between 1 and 1000 then raise exception 'Укажите количество занятий от 1 до 1000'; end if;
  if p_charged_amount is null or p_charged_amount < 0 then raise exception 'Укажите корректную сумму'; end if;
  if nullif(trim(coalesce(p_override_reason,'')),'') is null then raise exception 'Укажите причину изменения тарифа'; end if;
  select * into i from public.tariff_items where id=p_tariff_item_id and active and category='lesson';
  if not found then raise exception 'Для изменения количества выберите тариф занятий'; end if;
  select * into r from private.resolve_tariff_rate(i.id,p_instructor_id,now());
  if r.client_price is null or r.pool_amount is null then raise exception 'Для инструктора не настроена ставка'; end if;
  v_pool := round(r.pool_amount * p_quantity / i.credit_quantity, 2);
  v_subscription := private.get_or_create_subscription_impl(p_client_id,i.lesson_format,i.duration_minutes,p_instructor_id);
  v_payment := private.add_payment_impl(v_subscription,p_instructor_id,p_quantity,p_charged_amount,p_comment);
  update public.payments set payment_method=p_payment_method where id=v_payment.id;
  insert into public.payment_tariff_snapshots(payment_id,tariff_item_id,instructor_id,template_id,
    standard_client_price,charged_amount,pool_amount,override_reason)
  values(v_payment.id,i.id,p_instructor_id,r.template_id,r.client_price,p_charged_amount,v_pool,trim(p_override_reason));
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
  values(auth.uid(),'custom_tariff_payment','payment',v_payment.id,
    jsonb_build_object('tariff_item_id',i.id,'standard_quantity',i.credit_quantity,
      'quantity',p_quantity,'amount',p_charged_amount,'pool_amount',v_pool,'reason',p_override_reason));
  return v_payment.id;
end $$;
revoke all on function public.record_custom_tariff_payment(uuid,uuid,uuid,text,integer,numeric,text,text) from public,anon;
grant execute on function public.record_custom_tariff_payment(uuid,uuid,uuid,text,integer,numeric,text,text) to authenticated;

create function public.issue_custom_tariff_payment_request(
  p_client_id uuid, p_instructor_id uuid, p_tariff_item_id uuid,
  p_quantity integer, p_amount numeric, p_override_reason text,
  p_due_at timestamptz default null, p_comment text default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare i public.tariff_items; r record; v_subscription uuid; v_request uuid; v_pool numeric;
begin
  if not private.is_manager() then raise exception 'Изменить счёт по тарифу может только управляющая'; end if;
  if p_quantity is null or p_quantity not between 1 and 1000 then raise exception 'Укажите количество занятий от 1 до 1000'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Сумма счёта должна быть больше нуля'; end if;
  if nullif(trim(coalesce(p_override_reason,'')),'') is null then raise exception 'Укажите причину изменения тарифа'; end if;
  select * into i from public.tariff_items where id=p_tariff_item_id and active and category='lesson';
  if not found then raise exception 'Для счёта выберите тариф занятий'; end if;
  if not exists(select 1 from public.client_instructors where client_id=p_client_id and instructor_id=p_instructor_id) then
    raise exception 'Клиент не прикреплён к инструктору'; end if;
  if not exists(select 1 from public.instructors where id=p_instructor_id and payment_bank_name is not null
    and payment_sbp_phone is not null and payment_recipient_name is not null) then
    raise exception 'Сначала заполните реквизиты получения оплаты'; end if;
  select * into r from private.resolve_tariff_rate(i.id,p_instructor_id,now());
  if r.client_price is null or r.pool_amount is null then raise exception 'Для инструктора не настроена ставка'; end if;
  v_pool := round(r.pool_amount * p_quantity / i.credit_quantity, 2);
  v_subscription := private.get_or_create_subscription_impl(p_client_id,i.lesson_format,i.duration_minutes,p_instructor_id);
  insert into public.payment_requests(client_id,instructor_id,subscription_id,quantity,amount,
    format,duration_minutes,due_at,comment,tariff_item_id,standard_client_price,pool_amount,tariff_template_id)
  values(p_client_id,p_instructor_id,v_subscription,p_quantity,p_amount,i.lesson_format,i.duration_minutes,
    p_due_at,nullif(trim(coalesce(p_comment,'')),''),i.id,r.client_price,v_pool,r.template_id)
  returning id into v_request;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
  values(auth.uid(),'custom_tariff_invoice','payment_request',v_request,
    jsonb_build_object('tariff_item_id',i.id,'standard_quantity',i.credit_quantity,
      'quantity',p_quantity,'amount',p_amount,'pool_amount',v_pool,'reason',p_override_reason));
  return v_request;
end $$;
revoke all on function public.issue_custom_tariff_payment_request(uuid,uuid,uuid,integer,numeric,text,timestamptz,text) from public,anon;
grant execute on function public.issue_custom_tariff_payment_request(uuid,uuid,uuid,integer,numeric,text,timestamptz,text) to authenticated;

select pg_notify('pgrst','reload schema');
