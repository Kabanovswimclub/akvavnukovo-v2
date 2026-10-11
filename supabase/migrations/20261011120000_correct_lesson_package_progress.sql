begin;

-- Package labels follow the visit credits, including negative corrections and
-- a lesson that took place before its package was paid for. Financial entries,
-- balances and historical package_payment_id assignments are not modified.
-- Keep the original assignment-based labels for subscriptions whose payment
-- rows do not fully describe their credit operations.
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
    join target_subscriptions t on t.subscription_id = p.subscription_id
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
      and p.subscription_id = lp.subscription_id
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

revoke all on function public.get_client_lesson_package_progress(uuid) from public, anon;
grant execute on function public.get_client_lesson_package_progress(uuid) to authenticated;
select pg_notify('pgrst', 'reload schema');

commit;
