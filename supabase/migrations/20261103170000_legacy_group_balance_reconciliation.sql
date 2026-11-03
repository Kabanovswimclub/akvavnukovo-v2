begin;

-- One-time, balance-only reconciliation requested by the system administrator.
-- Do not alter lesson history or register a payment that was not received.
do $$
declare
  v_item record;
  v_balance numeric;
  v_operation_id uuid;
  v_marker text := '[СВЕРКА 03.11.2026]';
begin
  for v_item in
    select * from (values
      ('c326f113-5034-4bcc-f0cb-8a786e89930f'::uuid,
       'fc80f8c4-4e0b-7935-3ddc-114dc5d291cc'::uuid,
       'Столяровы: старый общий абонемент; согласованная корректировка +1'),
      ('b3ad1e2c-9645-aaa5-d2f5-161623dc9780'::uuid,
       'bcc63be0-a682-9454-a52b-02db28731c1e'::uuid,
       'Акмаевы: старый общий абонемент; согласованная корректировка +1')
    ) as x(subscription_id, client_id, explanation)
  loop
    if not exists (
      select 1 from public.subscriptions s
      join public.subscription_group_members gm on gm.group_id = s.group_id
      where s.id = v_item.subscription_id and gm.client_id = v_item.client_id
    ) then
      raise exception 'Subscription % does not belong to expected client %',
        v_item.subscription_id, v_item.client_id;
    end if;

    select b.balance into v_balance
    from public.subscription_balances b
    where b.subscription_id = v_item.subscription_id;

    if v_balance = 0 and exists (
      select 1 from public.subscription_operations o
      where o.subscription_id = v_item.subscription_id
        and o.comment like v_marker || '%'
    ) then
      continue;
    end if;
    if v_balance is distinct from -1 then
      raise exception 'Unexpected balance % on subscription %', v_balance, v_item.subscription_id;
    end if;

    insert into public.subscription_operations
      (subscription_id, operation, quantity, comment, occurred_at)
    values
      (v_item.subscription_id, 'correction'::public.operation_type, 1,
       v_marker || ' ' || v_item.explanation, now())
    returning id into v_operation_id;

    insert into public.audit_log(action, entity_type, entity_id, after_data)
    values ('reconcile_legacy_group_balance', 'subscription', v_item.subscription_id,
            jsonb_build_object('operation_id', v_operation_id,
                               'client_id', v_item.client_id,
                               'quantity', 1,
                               'reason', v_item.explanation));
  end loop;
end $$;

commit;
