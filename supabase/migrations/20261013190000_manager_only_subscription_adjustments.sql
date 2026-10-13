begin;

-- Existing initial balances and corrections remain unchanged. Only managers and
-- system administrators may create new balance-only operations.
create or replace function private.add_initial_balance_impl(
  p_subscription_id uuid, p_instructor_id uuid, p_quantity numeric, p_comment text
)
returns public.subscription_operations
language plpgsql security definer set search_path = '' as $$
declare v public.subscription_operations;
begin
  if not private.is_manager() then
    raise exception 'Изменять остаток может только управляющая или системный администратор';
  end if;
  if not private.can_manage_instructor(p_instructor_id) then raise exception 'Недостаточно прав'; end if;
  if p_quantity = 0 then raise exception 'Количество занятий не может быть нулём'; end if;
  if not exists (select 1 from public.subscriptions where id = p_subscription_id) then
    raise exception 'Абонемент не найден';
  end if;
  insert into public.subscription_operations
    (subscription_id, instructor_id, operation, quantity, author_user_id, comment, occurred_at)
  values
    (p_subscription_id, p_instructor_id, 'correction'::public.operation_type,
     p_quantity, auth.uid(), '[НАЧАЛЬНЫЙ ОСТАТОК] ' || nullif(trim(p_comment), ''), now())
  returning * into v;
  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, after_data)
  values (auth.uid(), 'add_initial_balance', 'subscription', p_subscription_id,
          jsonb_build_object('operation_id', v.id, 'instructor_id', p_instructor_id,
                             'quantity', p_quantity, 'comment', p_comment));
  return v;
end $$;
revoke all on function private.add_initial_balance_impl(uuid,uuid,numeric,text) from public, anon;
grant execute on function private.add_initial_balance_impl(uuid,uuid,numeric,text) to authenticated;

create or replace function public.add_initial_balance(
  p_subscription_id uuid, p_instructor_id uuid, p_quantity numeric, p_comment text
)
returns public.subscription_operations
language sql security invoker set search_path = '' as $$
  select private.add_initial_balance_impl(p_subscription_id, p_instructor_id, p_quantity, p_comment);
$$;
revoke all on function public.add_initial_balance(uuid,uuid,numeric,text) from public, anon;
grant execute on function public.add_initial_balance(uuid,uuid,numeric,text) to authenticated;

-- add_payment_impl is also used by the normal tariff and invoice workflows.
-- Keep paid, positive-quantity sales intact while blocking balance-only and
-- zero-price/negative-quantity entries from instructor sessions.
create or replace function private.add_payment_impl(
  p_subscription_id uuid, p_instructor_id uuid, p_quantity numeric, p_amount numeric, p_comment text
)
returns public.payments
language plpgsql security definer set search_path = '' as $$
declare v_payment public.payments;
begin
  if not private.can_manage_instructor(p_instructor_id) then raise exception 'Недостаточно прав'; end if;
  if (p_amount is null or p_amount <= 0 or p_quantity < 0) and not private.is_manager() then
    raise exception 'Изменять остаток может только управляющая или системный администратор';
  end if;
  if not exists (select 1 from public.subscriptions where id = p_subscription_id) then
    raise exception 'Абонемент не найден';
  end if;
  if p_quantity = 0 then raise exception 'Количество занятий не может быть нулём'; end if;
  insert into public.payments(subscription_id, instructor_id, quantity, amount, comment)
  values (p_subscription_id, p_instructor_id, p_quantity, p_amount, nullif(trim(p_comment), ''))
  returning * into v_payment;
  insert into public.subscription_operations
    (subscription_id, operation, quantity, author_user_id, comment, occurred_at)
  values (p_subscription_id,
          case when p_amount is null then 'correction'::public.operation_type
               else 'payment'::public.operation_type end,
          p_quantity, auth.uid(), nullif(trim(p_comment), ''), v_payment.paid_at);
  insert into public.audit_log(actor_user_id, action, entity_type, entity_id, after_data)
  values (auth.uid(), 'add_payment', 'payment', v_payment.id, to_jsonb(v_payment));
  return v_payment;
end $$;
revoke all on function private.add_payment_impl(uuid,uuid,numeric,numeric,text) from public, anon;
grant execute on function private.add_payment_impl(uuid,uuid,numeric,numeric,text) to authenticated;

-- The legacy direct payment RPC is used by the client-card correction form.
-- Instructors continue using the separate tariff and invoice RPCs.
create or replace function public.add_payment(
  p_subscription_id uuid, p_instructor_id uuid, p_quantity numeric, p_amount numeric, p_comment text
)
returns public.payments
language plpgsql security invoker set search_path = '' as $$
begin
  if not private.is_manager() then
    raise exception 'Изменять остаток может только управляющая или системный администратор';
  end if;
  return private.add_payment_impl(p_subscription_id, p_instructor_id, p_quantity, p_amount, p_comment);
end $$;
revoke all on function public.add_payment(uuid,uuid,numeric,numeric,text) from public, anon;
grant execute on function public.add_payment(uuid,uuid,numeric,numeric,text) to authenticated;

select pg_notify('pgrst', 'reload schema');
commit;
