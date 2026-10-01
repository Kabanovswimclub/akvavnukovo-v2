begin;

-- A conservative FIFO reconstruction for historic packages. Only clean, fully
-- monetary purchases are considered; excess bookings remain unnumbered.
with clean_subscriptions as (
  select p.subscription_id
  from public.payments p
  where p.quantity > 0
  group by p.subscription_id
  having bool_and(p.amount > 0 and p.quantity = trunc(p.quantity))
     and not exists (
       select 1 from public.subscription_operations o
       where o.subscription_id = p.subscription_id
         and o.operation = 'correction' and o.quantity <> 0
     )
), ordered_payments as (
  select p.id as payment_id, p.subscription_id, p.paid_at,
         sum(p.quantity) over (
           partition by p.subscription_id order by p.paid_at, p.id
         ) as last_slot,
         p.quantity
  from public.payments p
  join clean_subscriptions cs on cs.subscription_id = p.subscription_id
  where p.quantity > 0
), ordered_lessons as (
  select lp.lesson_id, lp.client_id, lp.subscription_id, l.starts_at,
         row_number() over (
           partition by lp.subscription_id order by l.starts_at, l.id, lp.client_id
         ) as slot
  from public.lesson_participants lp
  join public.lessons l on l.id = lp.lesson_id
  join clean_subscriptions cs on cs.subscription_id = lp.subscription_id
  where l.status <> 'cancelled' or l.charged_on_cancel
), matched as (
  select ol.lesson_id, ol.client_id, ol.subscription_id, ol.starts_at,
         op.payment_id, op.paid_at
  from ordered_lessons ol
  join ordered_payments op on op.subscription_id = ol.subscription_id
    and ol.slot > op.last_slot - op.quantity and ol.slot <= op.last_slot
), safe_subscriptions as (
  select m.subscription_id
  from matched m
  group by m.subscription_id
  having bool_and(m.starts_at >= m.paid_at - interval '1 day')
     and not exists (
       select 1
       from matched other
       join public.lesson_participants lp
         on lp.lesson_id = other.lesson_id and lp.client_id = other.client_id
       where other.subscription_id = m.subscription_id
         and lp.package_payment_id is not null
         and lp.package_payment_id <> other.payment_id
     )
)
update public.lesson_participants lp
set package_payment_id = m.payment_id
from matched m
join safe_subscriptions ss on ss.subscription_id = m.subscription_id
where lp.lesson_id = m.lesson_id and lp.client_id = m.client_id
  and lp.package_payment_id is null;

commit;
