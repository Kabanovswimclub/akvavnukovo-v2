-- Let managers issue an unmodified catalog invoice for a selected instructor.
-- The instructor-only issue_tariff_payment_request RPC remains unchanged.
create function public.issue_manager_tariff_payment_request(
  p_client_id uuid, p_instructor_id uuid, p_tariff_item_id uuid,
  p_due_at timestamptz default null, p_comment text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_item public.tariff_items;
  v_rate record;
  v_subscription uuid;
  v_request uuid;
begin
  if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
  select * into v_item from public.tariff_items
    where id = p_tariff_item_id and active and category = 'lesson';
  if not found then raise exception 'Для счёта выберите занятие или абонемент'; end if;
  if not exists (
    select 1 from public.client_instructors
    where client_id = p_client_id and instructor_id = p_instructor_id
  ) then raise exception 'Клиент не прикреплён к инструктору'; end if;
  if not exists (
    select 1 from public.instructors
    where id = p_instructor_id and payment_bank_name is not null
      and payment_sbp_phone is not null and payment_recipient_name is not null
  ) then raise exception 'Сначала заполните реквизиты получения оплаты'; end if;
  select * into v_rate from private.resolve_tariff_rate(v_item.id, p_instructor_id, now());
  if v_rate.client_price is null or v_rate.client_price <= 0 or v_rate.pool_amount is null then
    raise exception 'Для инструктора не настроена ставка';
  end if;
  v_subscription := private.get_or_create_subscription_impl(
    p_client_id, v_item.lesson_format, v_item.duration_minutes, p_instructor_id
  );
  insert into public.payment_requests(
    client_id, instructor_id, subscription_id, quantity, amount, format,
    duration_minutes, due_at, comment, tariff_item_id, standard_client_price,
    pool_amount, tariff_template_id
  ) values (
    p_client_id, p_instructor_id, v_subscription, v_item.credit_quantity,
    v_rate.client_price, v_item.lesson_format, v_item.duration_minutes,
    p_due_at, nullif(trim(coalesce(p_comment, '')), ''), v_item.id,
    v_rate.client_price, v_rate.pool_amount, v_rate.template_id
  ) returning id into v_request;
  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, after_data)
  values (auth.uid(), 'manager_tariff_invoice', 'payment_request', v_request,
    jsonb_build_object('client_id', p_client_id, 'instructor_id', p_instructor_id,
      'tariff_item_id', v_item.id, 'quantity', v_item.credit_quantity,
      'amount', v_rate.client_price));
  return v_request;
end $$;
revoke all on function public.issue_manager_tariff_payment_request(uuid, uuid, uuid, timestamptz, text)
  from public, anon;
grant execute on function public.issue_manager_tariff_payment_request(uuid, uuid, uuid, timestamptz, text)
  to authenticated;
select pg_notify('pgrst', 'reload schema');
