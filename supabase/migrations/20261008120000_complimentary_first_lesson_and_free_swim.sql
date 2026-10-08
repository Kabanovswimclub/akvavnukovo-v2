begin;

-- A completed first lesson can be waived by the manager after a same-day 10+1 purchase.
-- Keep the lesson and its own subscription; do not touch the purchased package.
alter table public.lessons
  add column first_visit_complimentary boolean not null default false;

create or replace function public.make_first_lesson_complimentary(p_lesson_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_lesson public.lessons;
  v_part public.lesson_participants;
  v_trial_subscription uuid;
  v_charge numeric;
  v_refund numeric;
begin
  if not private.is_manager() then raise exception 'Решение о бесплатном первом занятии принимает управляющая'; end if;
  select * into v_lesson from public.lessons where id = p_lesson_id for update;
  if not found or v_lesson.format not in ('первое','индивидуальное','сплит') or v_lesson.status <> 'scheduled' then
    raise exception 'Выберите проведённое первое занятие';
  end if;
  if v_lesson.first_visit_complimentary then raise exception 'Первое занятие уже отмечено бесплатным'; end if;
  if v_lesson.ends_at > now() then raise exception 'Первое занятие ещё не завершилось'; end if;
  if v_lesson.ends_at - v_lesson.starts_at <> interval '30 minutes' then
    raise exception 'Первое занятие может длиться только 30 минут';
  end if;
  select * into v_part from public.lesson_participants where lesson_id = p_lesson_id;
  if not found or (select count(*) from public.lesson_participants where lesson_id = p_lesson_id) <> 1
    or v_part.subscription_id is null then
    raise exception 'Нужно одно первое занятие с отдельным абонементом клиента';
  end if;
  if not exists (
    select 1 from public.payments p
    join public.payment_tariff_snapshots s on s.payment_id = p.id
    join public.tariff_items i on i.id = s.tariff_item_id
    join public.subscriptions sub on sub.id = p.subscription_id
    where sub.client_id = v_part.client_id
      and p.instructor_id = v_lesson.instructor_id
      and p.amount > 0 and p.quantity = 11
      and i.code in ('individual-30-11','individual-45-11','individual-60-11',
                     'split-30-11','split-45-11','split-60-11')
      and (p.paid_at at time zone 'Europe/Moscow')::date =
          (v_lesson.starts_at at time zone 'Europe/Moscow')::date
  ) then raise exception 'Не найдена оплата абонемента 10+1 в день первого занятия'; end if;
  v_trial_subscription := private.get_or_create_subscription_impl(
    v_part.client_id,'первое',30,v_lesson.instructor_id);
  if exists (select 1 from public.payments p where p.subscription_id = v_trial_subscription and p.amount > 0)
     or exists (select 1 from public.payment_requests r
       where r.subscription_id = v_trial_subscription and r.status in ('issued','reported','paid')) then
    raise exception 'По первому занятию есть отдельная оплата или счёт; сначала разберитесь с ним';
  end if;
  select coalesce(sum(quantity),0) into v_charge from public.subscription_operations
    where lesson_id = p_lesson_id and subscription_id = v_part.subscription_id and operation = 'lesson_charge';
  select coalesce(sum(quantity),0) into v_refund from public.subscription_operations
    where lesson_id = p_lesson_id and subscription_id = v_part.subscription_id and operation = 'lesson_refund';
  if v_part.subscription_id <> v_trial_subscription then
    if v_charge > v_refund then
      insert into public.subscription_operations(subscription_id,operation,quantity,lesson_id,author_user_id,comment)
        values(v_part.subscription_id,'lesson_refund',v_charge-v_refund,p_lesson_id,auth.uid(),
               'Возврат занятия в абонемент: первое занятие бесплатно');
    end if;
    update public.lesson_participants set subscription_id = v_trial_subscription, package_payment_id = null
      where lesson_id = p_lesson_id and client_id = v_part.client_id;
    update public.lessons set format = 'первое' where id = p_lesson_id;
    v_part.subscription_id := v_trial_subscription;
    v_charge := 0;
    v_refund := 0;
  end if;
  if v_charge = 0 then
    insert into public.subscription_operations(subscription_id,operation,quantity,lesson_id,author_user_id,comment)
      values(v_part.subscription_id,'lesson_charge',1,p_lesson_id,auth.uid(),'Проведено первое занятие');
    v_charge := 1;
  end if;
  if v_refund > v_charge then raise exception 'Некорректные списания первого занятия'; end if;
  if v_charge > v_refund then
    insert into public.subscription_operations(subscription_id,operation,quantity,lesson_id,author_user_id,comment)
      values(v_part.subscription_id,'lesson_refund',v_charge-v_refund,p_lesson_id,auth.uid(),
             'Бесплатно при покупке абонемента 10+1 в тот же день');
  end if;
  update public.lessons set first_visit_complimentary = true where id = p_lesson_id;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data)
    values(auth.uid(),'make_first_lesson_complimentary','lesson',p_lesson_id,
      jsonb_build_object('client_id',v_part.client_id,'client_amount',0,'pool_amount',0,
                         'subscription_id',v_part.subscription_id));
end $$;
revoke all on function public.make_first_lesson_complimentary(uuid) from public,anon;
grant execute on function public.make_first_lesson_complimentary(uuid) to authenticated;

-- Allow manager-entered custom packages for free swimming too.
-- Free swimming is counted in visits, without inventing a visit duration.
do $$ declare v_constraint text; begin
  select c.conname into v_constraint from pg_constraint c
  where c.conrelid = 'public.tariff_items'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%category%'
    and pg_get_constraintdef(c.oid) ilike '%duration_minutes%';
  if v_constraint is null then raise exception 'Tariff category constraint not found'; end if;
  execute format('alter table public.tariff_items drop constraint %I', v_constraint);
end $$;
alter table public.tariff_items add constraint tariff_items_category_duration_check check (
  (category = 'lesson' and lesson_format is not null and credit_quantity > 0
    and ((lesson_format = 'свободное' and duration_minutes is null)
      or (lesson_format <> 'свободное' and duration_minutes in (30,45,60))))
  or (category <> 'lesson' and lesson_format is null and duration_minutes is null and credit_quantity = 0)
);
alter table public.payment_requests alter column duration_minutes drop not null;

create or replace function private.get_or_create_subscription_impl(
  p_client_id uuid, p_format text, p_duration integer, p_instructor_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_format text := lower(trim(p_format)); v_duration integer := p_duration; v_id uuid;
begin
  if not private.can_manage_instructor(p_instructor_id) then raise exception 'Недостаточно прав'; end if;
  if not exists(select 1 from public.clients where id = p_client_id and archived = false) then raise exception 'Клиент не найден'; end if;
  if nullif(v_format,'') is null then raise exception 'Укажите формат'; end if;
  if v_format = 'свободное' then
    v_duration := null;
  elsif v_duration is null or v_duration not in (30,45,60) then
    raise exception 'Укажите длительность 30, 45 или 60 минут';
  end if;
  select s.id into v_id from public.subscriptions s
  where s.client_id = p_client_id and s.format = v_format
    and s.duration_minutes is not distinct from v_duration
  order by s.created_at limit 1;
  if v_id is null then
    insert into public.subscriptions(client_id,format,duration_minutes)
      values(p_client_id,v_format,v_duration) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function private.check_manual_package(p_client_id uuid, p_instructor_id uuid, p_format text,
  p_duration integer, p_quantity integer, p_amount numeric, p_pool_amount numeric, p_comment text)
returns void language plpgsql security definer set search_path = '' as $$ begin
  if not private.is_manager() then raise exception 'Ручной ввод доступен только управляющей'; end if;
  if p_client_id is null or p_instructor_id is null then raise exception 'Выберите клиента и инструктора'; end if;
  if lower(trim(coalesce(p_format, ''))) not in ('индивидуальное', 'сплит', 'группа', 'свободное') then raise exception 'Укажите формат занятия'; end if;
  if lower(trim(p_format)) = 'свободное' then
    if p_duration is not null then raise exception 'Для свободного плавания длительность не указывается'; end if;
  elsif p_duration is null or p_duration not in (30,45,60) then
    raise exception 'Укажите длительность 30, 45 или 60 минут';
  end if;
  if p_quantity is null or p_quantity not between 1 and 1000 then raise exception 'Укажите количество занятий от 1 до 1000'; end if;
  if p_amount is null or p_amount <= 0 or p_pool_amount is null or p_pool_amount < 0 then raise exception 'Укажите сумму клиенту и сумму бассейну'; end if;
  if nullif(trim(coalesce(p_comment, '')), '') is null then raise exception 'Укажите причину ручного ввода'; end if;
end $$;
revoke all on function private.check_manual_package(uuid,uuid,text,integer,integer,numeric,numeric,text) from public,anon,authenticated;

insert into public.tariff_items(code,category,public_group,name,lesson_format,duration_minutes,credit_quantity,sort_order)
values('free-swim-11','lesson','Свободное плавание','10+1 посещений','свободное',null,11,90)
on conflict (code) do nothing;
insert into public.tariff_price_versions(tariff_item_id,client_price)
select i.id,8000 from public.tariff_items i where i.code = 'free-swim-11'
  and not exists(select 1 from public.tariff_price_versions p where p.tariff_item_id = i.id);
insert into public.tariff_template_rate_versions(template_id,tariff_item_id,pool_amount)
select t.id,i.id,7000 from public.tariff_templates t cross join public.tariff_items i
where i.code = 'free-swim-11'
  and not exists(select 1 from public.tariff_template_rate_versions r
    where r.template_id = t.id and r.tariff_item_id = i.id);

select pg_notify('pgrst','reload schema');
commit;
