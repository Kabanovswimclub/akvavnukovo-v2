-- Central tariff catalog, instructor rate templates and immutable finance snapshots.
-- Internal pool rates are available only through manager-only RPC functions.

create table public.tariff_items (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  category text not null check (category in ('lesson','service','product')),
  public_group text not null,
  name text not null,
  lesson_format text,
  duration_minutes integer,
  credit_quantity numeric not null default 0 check (credit_quantity >= 0),
  sort_order integer not null default 0,
  active boolean not null default true,
  client_visible boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((category = 'lesson' and lesson_format is not null and duration_minutes in (30,45,60) and credit_quantity > 0)
    or (category <> 'lesson' and lesson_format is null and duration_minutes is null and credit_quantity = 0))
);

create table public.tariff_price_versions (
  id uuid primary key default gen_random_uuid(),
  tariff_item_id uuid not null references public.tariff_items(id),
  client_price numeric not null check (client_price >= 0),
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (tariff_item_id,effective_from)
);
create index tariff_price_versions_current_idx on public.tariff_price_versions(tariff_item_id,effective_from desc);

create table public.tariff_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create unique index tariff_templates_one_default_idx on public.tariff_templates(is_default) where is_default;

create table public.tariff_template_rate_versions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.tariff_templates(id),
  tariff_item_id uuid not null references public.tariff_items(id),
  pool_amount numeric not null check (pool_amount >= 0),
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (template_id,tariff_item_id,effective_from)
);
create index tariff_template_rates_current_idx on public.tariff_template_rate_versions(template_id,tariff_item_id,effective_from desc);

create table public.instructor_tariff_assignments (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null references public.instructors(id),
  template_id uuid not null references public.tariff_templates(id),
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (instructor_id,effective_from)
);
create index instructor_tariff_assignments_current_idx on public.instructor_tariff_assignments(instructor_id,effective_from desc);

create table public.instructor_tariff_override_versions (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null references public.instructors(id),
  tariff_item_id uuid not null references public.tariff_items(id),
  pool_amount numeric not null check (pool_amount >= 0),
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (instructor_id,tariff_item_id,effective_from)
);
create index instructor_tariff_overrides_current_idx on public.instructor_tariff_override_versions(instructor_id,tariff_item_id,effective_from desc);

create table public.payment_tariff_snapshots (
  payment_id uuid primary key references public.payments(id),
  tariff_item_id uuid not null references public.tariff_items(id),
  instructor_id uuid not null references public.instructors(id),
  template_id uuid references public.tariff_templates(id),
  standard_client_price numeric not null check (standard_client_price >= 0),
  charged_amount numeric not null check (charged_amount >= 0),
  pool_amount numeric not null check (pool_amount >= 0),
  instructor_income numeric generated always as (charged_amount-pool_amount) stored,
  override_reason text,
  captured_at timestamptz not null default now()
);

create table public.catalog_sales (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  instructor_id uuid not null references public.instructors(id),
  tariff_item_id uuid not null references public.tariff_items(id),
  template_id uuid references public.tariff_templates(id),
  standard_client_price numeric not null check (standard_client_price >= 0),
  charged_amount numeric not null check (charged_amount >= 0),
  pool_amount numeric not null check (pool_amount >= 0),
  instructor_income numeric generated always as (charged_amount-pool_amount) stored,
  payment_method text not null check (payment_method in ('cash','self_transfer')),
  override_reason text,
  comment text,
  sold_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create index catalog_sales_period_idx on public.catalog_sales(sold_at desc,instructor_id);

alter table public.payment_requests add column tariff_item_id uuid references public.tariff_items(id);
alter table public.payment_requests add column standard_client_price numeric;
alter table public.payment_requests add column pool_amount numeric;
alter table public.payment_requests add column tariff_template_id uuid references public.tariff_templates(id);

do $$ declare t uuid; begin
  insert into public.tariff_templates(name,is_default) values ('Основной тариф',true) returning id into t;

  insert into public.tariff_items(code,category,public_group,name,lesson_format,duration_minutes,credit_quantity,sort_order) values
  ('individual-30-1','lesson','Индивидуальные','Разовое · 30 минут','индивидуальное',30,1,10),
  ('individual-30-5','lesson','Индивидуальные','5 занятий · 30 минут','индивидуальное',30,5,11),
  ('individual-30-11','lesson','Индивидуальные','10+1 · 30 минут','индивидуальное',30,11,12),
  ('individual-45-1','lesson','Индивидуальные','Разовое · 45 минут','индивидуальное',45,1,20),
  ('individual-45-5','lesson','Индивидуальные','5 занятий · 45 минут','индивидуальное',45,5,21),
  ('individual-45-11','lesson','Индивидуальные','10+1 · 45 минут','индивидуальное',45,11,22),
  ('individual-60-1','lesson','Индивидуальные','Разовое · 60 минут','индивидуальное',60,1,30),
  ('individual-60-5','lesson','Индивидуальные','5 занятий · 60 минут','индивидуальное',60,5,31),
  ('individual-60-11','lesson','Индивидуальные','10+1 · 60 минут','индивидуальное',60,11,32),
  ('split-30-1','lesson','Сплит','Разовое · 30 минут','сплит',30,1,40),
  ('split-30-5','lesson','Сплит','5 занятий · 30 минут','сплит',30,5,41),
  ('split-30-11','lesson','Сплит','10+1 · 30 минут','сплит',30,11,42),
  ('split-45-1','lesson','Сплит','Разовое · 45 минут','сплит',45,1,50),
  ('split-45-5','lesson','Сплит','5 занятий · 45 минут','сплит',45,5,51),
  ('split-45-11','lesson','Сплит','10+1 · 45 минут','сплит',45,11,52),
  ('split-60-1','lesson','Сплит','Разовое · 60 минут','сплит',60,1,60),
  ('split-60-5','lesson','Сплит','5 занятий · 60 минут','сплит',60,5,61),
  ('split-60-11','lesson','Сплит','10+1 · 60 минут','сплит',60,11,62),
  ('group-45-10','lesson','Мини-группы','10 занятий · 45 минут','группа',45,10,70),
  ('trial-30','lesson','Первое занятие','Первое занятие · 30 минут','первое',30,1,80),
  ('trial-45','lesson','Первое занятие','Первое занятие · 45 минут','первое',45,1,81),
  ('trial-60','lesson','Первое занятие','Первое занятие · 60 минут','первое',60,1,82),
  ('free-swim','service','Услуги и товары','Свободное плавание',null,null,0,100),
  ('hydro-15','service','Услуги и товары','Гидромассаж · 15 минут',null,null,0,101),
  ('hydro-30','service','Услуги и товары','Гидромассаж · 30 минут',null,null,0,102),
  ('cap','product','Услуги и товары','Шапка',null,null,0,110),
  ('goggles','product','Услуги и товары','Очки',null,null,0,111),
  ('briefs','product','Услуги и товары','Трусики',null,null,0,112),
  ('swimsuit','product','Услуги и товары','Купальник',null,null,0,113);

  insert into public.tariff_price_versions(tariff_item_id,client_price)
  select id,case code
    when 'individual-30-1' then 2600 when 'individual-30-5' then 12400 when 'individual-30-11' then 26000
    when 'individual-45-1' then 3300 when 'individual-45-5' then 16300 when 'individual-45-11' then 33000
    when 'individual-60-1' then 3600 when 'individual-60-5' then 18200 when 'individual-60-11' then 36000
    when 'split-30-1' then 3600 when 'split-30-5' then 17000 when 'split-30-11' then 36000
    when 'split-45-1' then 4300 when 'split-45-5' then 20500 when 'split-45-11' then 43000
    when 'split-60-1' then 4800 when 'split-60-5' then 23000 when 'split-60-11' then 48000
    when 'group-45-10' then 15000 when 'trial-30' then 1500 when 'trial-45' then 1500 when 'trial-60' then 1500
    when 'free-swim' then 800 when 'hydro-15' then 350 when 'hydro-30' then 700
    when 'cap' then 1000 when 'goggles' then 1500 when 'briefs' then 1500 when 'swimsuit' then 2000 end
  from public.tariff_items;

  insert into public.tariff_template_rate_versions(template_id,tariff_item_id,pool_amount)
  select t,id,case code
    when 'individual-30-1' then 1420 when 'individual-30-5' then 6700 when 'individual-30-11' then 14200
    when 'individual-45-1' then 1770 when 'individual-45-5' then 8850 when 'individual-45-11' then 17700
    when 'individual-60-1' then 1920 when 'individual-60-5' then 9850 when 'individual-60-11' then 19200
    when 'split-30-1' then 1860 when 'split-30-5' then 8800 when 'split-30-11' then 18600
    when 'split-45-1' then 2210 when 'split-45-5' then 10800 when 'split-45-11' then 22100
    when 'split-60-1' then 2460 when 'split-60-5' then 11800 when 'split-60-11' then 24600
    when 'group-45-10' then 8100 when 'trial-30' then 750 when 'trial-45' then 750 when 'trial-60' then 750
    when 'free-swim' then 700 when 'hydro-15' then 300 when 'hydro-30' then 600
    when 'cap' then 900 when 'goggles' then 1400 when 'briefs' then 1400 when 'swimsuit' then 1800 end
  from public.tariff_items;

  insert into public.instructor_tariff_assignments(instructor_id,template_id)
  select id,t from public.instructors where status='active';
end $$;

alter table public.tariff_items enable row level security;
alter table public.tariff_price_versions enable row level security;
alter table public.tariff_templates enable row level security;
alter table public.tariff_template_rate_versions enable row level security;
alter table public.instructor_tariff_assignments enable row level security;
alter table public.instructor_tariff_override_versions enable row level security;
alter table public.payment_tariff_snapshots enable row level security;
alter table public.catalog_sales enable row level security;
revoke all on public.tariff_items,public.tariff_price_versions,public.tariff_templates,public.tariff_template_rate_versions,public.instructor_tariff_assignments,public.instructor_tariff_override_versions,public.payment_tariff_snapshots,public.catalog_sales from public,anon,authenticated;

create or replace function private.resolve_tariff_rate(p_tariff_item_id uuid,p_instructor_id uuid,p_at timestamptz default now())
returns table(client_price numeric,pool_amount numeric,template_id uuid) language sql stable security definer set search_path='' as $$
 with assignment as(select coalesce((select a.template_id from public.instructor_tariff_assignments a where a.instructor_id=p_instructor_id and a.effective_from<=p_at order by a.effective_from desc limit 1),(select t.id from public.tariff_templates t where t.is_default and t.active limit 1)) template_id)
 select
  (select p.client_price from public.tariff_price_versions p where p.tariff_item_id=p_tariff_item_id and p.effective_from<=p_at order by p.effective_from desc limit 1),
  coalesce((select o.pool_amount from public.instructor_tariff_override_versions o where o.instructor_id=p_instructor_id and o.tariff_item_id=p_tariff_item_id and o.effective_from<=p_at order by o.effective_from desc limit 1),(select r.pool_amount from public.tariff_template_rate_versions r where r.template_id=(select template_id from assignment) and r.tariff_item_id=p_tariff_item_id and r.effective_from<=p_at order by r.effective_from desc limit 1)),
  (select template_id from assignment)
$$;
revoke all on function private.resolve_tariff_rate(uuid,uuid,timestamptz) from public,anon,authenticated;

create or replace function public.get_public_tariff_catalog()
returns table(id uuid,code text,category text,public_group text,name text,lesson_format text,duration_minutes integer,credit_quantity numeric,client_price numeric,sort_order integer) language sql stable security definer set search_path='' as $$
 select i.id,i.code,i.category,i.public_group,i.name,i.lesson_format,i.duration_minutes,i.credit_quantity,(select p.client_price from public.tariff_price_versions p where p.tariff_item_id=i.id and p.effective_from<=now() order by p.effective_from desc limit 1),i.sort_order from public.tariff_items i where i.active and i.client_visible order by i.sort_order
$$;
revoke all on function public.get_public_tariff_catalog() from public,anon;
grant execute on function public.get_public_tariff_catalog() to authenticated;

create or replace function public.get_manager_tariff_catalog(p_instructor_id uuid default null)
returns table(id uuid,code text,category text,public_group text,name text,lesson_format text,duration_minutes integer,credit_quantity numeric,client_price numeric,pool_amount numeric,instructor_income numeric,template_id uuid,rate_source text,sort_order integer) language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_manager() then raise exception 'Недостаточно прав'; end if;
 return query select i.id,i.code,i.category,i.public_group,i.name,i.lesson_format,i.duration_minutes,i.credit_quantity,r.client_price,r.pool_amount,r.client_price-r.pool_amount,r.template_id,
 case when p_instructor_id is not null and exists(select 1 from public.instructor_tariff_override_versions o where o.instructor_id=p_instructor_id and o.tariff_item_id=i.id and o.effective_from<=now()) then 'Индивидуальная ставка' else 'Шаблон' end,i.sort_order
 from public.tariff_items i cross join lateral private.resolve_tariff_rate(i.id,coalesce(p_instructor_id,(select a.instructor_id from public.instructor_tariff_assignments a order by a.effective_from limit 1)),now()) r where i.active order by i.sort_order;
end $$;
revoke all on function public.get_manager_tariff_catalog(uuid) from public,anon;
grant execute on function public.get_manager_tariff_catalog(uuid) to authenticated;

create or replace function public.get_tariff_templates()
returns table(id uuid,name text,is_default boolean,active boolean) language plpgsql stable security definer set search_path='' as $$ begin if not private.is_manager() then raise exception 'Недостаточно прав';end if;return query select t.id,t.name,t.is_default,t.active from public.tariff_templates t order by t.is_default desc,t.name;end $$;
revoke all on function public.get_tariff_templates() from public,anon;grant execute on function public.get_tariff_templates() to authenticated;

create or replace function public.save_tariff_rate(p_tariff_item_id uuid,p_client_price numeric,p_template_id uuid,p_pool_amount numeric)
returns void language plpgsql security definer set search_path='' as $$ begin
 if not private.is_manager() then raise exception 'Недостаточно прав';end if;
 if p_client_price<0 or p_pool_amount<0 then raise exception 'Суммы не могут быть отрицательными';end if;
 insert into public.tariff_price_versions(tariff_item_id,client_price,created_by) values(p_tariff_item_id,p_client_price,auth.uid());
 insert into public.tariff_template_rate_versions(template_id,tariff_item_id,pool_amount,created_by) values(p_template_id,p_tariff_item_id,p_pool_amount,auth.uid());
 insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data) values(auth.uid(),'save_tariff_rate','tariff_item',p_tariff_item_id,jsonb_build_object('client_price',p_client_price,'template_id',p_template_id,'pool_amount',p_pool_amount));
end $$;
revoke all on function public.save_tariff_rate(uuid,numeric,uuid,numeric) from public,anon;grant execute on function public.save_tariff_rate(uuid,numeric,uuid,numeric) to authenticated;

create or replace function public.create_tariff_template(p_name text,p_copy_from uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$ declare v uuid;begin
 if not private.is_manager() then raise exception 'Недостаточно прав';end if;
 if nullif(trim(p_name),'') is null then raise exception 'Укажите название шаблона';end if;
 insert into public.tariff_templates(name,created_by) values(trim(p_name),auth.uid()) returning id into v;
 insert into public.tariff_template_rate_versions(template_id,tariff_item_id,pool_amount,created_by) select v,r.tariff_item_id,r.pool_amount,auth.uid() from public.tariff_items i cross join lateral(select x.tariff_item_id,x.pool_amount from public.tariff_template_rate_versions x where x.template_id=coalesce(p_copy_from,(select id from public.tariff_templates where is_default)) and x.tariff_item_id=i.id and x.effective_from<=now() order by x.effective_from desc limit 1)r;
 return v;
end $$;
revoke all on function public.create_tariff_template(text,uuid) from public,anon;grant execute on function public.create_tariff_template(text,uuid) to authenticated;

create or replace function public.assign_tariff_template(p_instructor_id uuid,p_template_id uuid)
returns void language plpgsql security definer set search_path='' as $$ begin if not private.is_manager() then raise exception 'Недостаточно прав';end if;insert into public.instructor_tariff_assignments(instructor_id,template_id,created_by) values(p_instructor_id,p_template_id,auth.uid());insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data) values(auth.uid(),'assign_tariff_template','instructor',p_instructor_id,jsonb_build_object('template_id',p_template_id));end $$;
revoke all on function public.assign_tariff_template(uuid,uuid) from public,anon;grant execute on function public.assign_tariff_template(uuid,uuid) to authenticated;

create or replace function public.save_instructor_tariff_override(p_instructor_id uuid,p_tariff_item_id uuid,p_pool_amount numeric)
returns void language plpgsql security definer set search_path='' as $$ begin if not private.is_manager() then raise exception 'Недостаточно прав';end if;insert into public.instructor_tariff_override_versions(instructor_id,tariff_item_id,pool_amount,created_by) values(p_instructor_id,p_tariff_item_id,p_pool_amount,auth.uid());end $$;
revoke all on function public.save_instructor_tariff_override(uuid,uuid,numeric) from public,anon;grant execute on function public.save_instructor_tariff_override(uuid,uuid,numeric) to authenticated;

create or replace function public.copy_instructor_tariffs(p_source_instructor_id uuid,p_target_instructor_id uuid)
returns void language plpgsql security definer set search_path='' as $$ declare v_template uuid;begin
 if not private.is_manager() then raise exception 'Недостаточно прав';end if;
 select template_id into v_template from public.instructor_tariff_assignments where instructor_id=p_source_instructor_id and effective_from<=now() order by effective_from desc limit 1;
 if v_template is null then raise exception 'У выбранного инструктора нет тарифа';end if;
 insert into public.instructor_tariff_assignments(instructor_id,template_id,created_by) values(p_target_instructor_id,v_template,auth.uid());
 insert into public.instructor_tariff_override_versions(instructor_id,tariff_item_id,pool_amount,created_by) select p_target_instructor_id,i.id,r.pool_amount,auth.uid() from public.tariff_items i cross join lateral private.resolve_tariff_rate(i.id,p_source_instructor_id,now()) r where r.pool_amount is not null;
end $$;
revoke all on function public.copy_instructor_tariffs(uuid,uuid) from public,anon;grant execute on function public.copy_instructor_tariffs(uuid,uuid) to authenticated;

create or replace function public.record_tariff_payment(p_client_id uuid,p_instructor_id uuid,p_tariff_item_id uuid,p_payment_method text,p_charged_amount numeric default null,p_override_reason text default null,p_comment text default null)
returns uuid language plpgsql security definer set search_path='' as $$ declare i public.tariff_items;r record;v_amount numeric;v_subscription uuid;v_payment public.payments;v_sale uuid;begin
 if not private.can_manage_instructor(p_instructor_id) then raise exception 'Недостаточно прав';end if;
 if p_payment_method not in('cash','self_transfer') then raise exception 'Выберите способ оплаты';end if;
 select * into i from public.tariff_items where id=p_tariff_item_id and active; if not found then raise exception 'Тариф не найден';end if;
 select * into r from private.resolve_tariff_rate(i.id,p_instructor_id,now()); if r.client_price is null or r.pool_amount is null then raise exception 'Для инструктора не настроена ставка';end if;
 v_amount:=coalesce(p_charged_amount,r.client_price);
 if v_amount<>r.client_price and not private.is_manager() then raise exception 'Изменить сумму может только управляющая';end if;
 if v_amount<>r.client_price and nullif(trim(p_override_reason),'') is null then raise exception 'Укажите причину изменения суммы';end if;
 if i.category='lesson' then
  v_subscription:=private.get_or_create_subscription_impl(p_client_id,i.lesson_format,i.duration_minutes,p_instructor_id);
  v_payment:=private.add_payment_impl(v_subscription,p_instructor_id,i.credit_quantity,v_amount,p_comment);
  update public.payments set payment_method=p_payment_method where id=v_payment.id;
  insert into public.payment_tariff_snapshots(payment_id,tariff_item_id,instructor_id,template_id,standard_client_price,charged_amount,pool_amount,override_reason) values(v_payment.id,i.id,p_instructor_id,r.template_id,r.client_price,v_amount,r.pool_amount,nullif(trim(p_override_reason),''));
  return v_payment.id;
 else
  insert into public.catalog_sales(client_id,instructor_id,tariff_item_id,template_id,standard_client_price,charged_amount,pool_amount,payment_method,override_reason,comment,created_by) values(p_client_id,p_instructor_id,i.id,r.template_id,r.client_price,v_amount,r.pool_amount,p_payment_method,nullif(trim(p_override_reason),''),nullif(trim(p_comment),''),auth.uid()) returning id into v_sale;
  insert into public.audit_log(actor_user_id,action,entity_type,entity_id,after_data) values(auth.uid(),'catalog_sale','catalog_sale',v_sale,jsonb_build_object('tariff_item_id',i.id,'amount',v_amount));
  return v_sale;
 end if;
end $$;
revoke all on function public.record_tariff_payment(uuid,uuid,uuid,text,numeric,text,text) from public,anon;grant execute on function public.record_tariff_payment(uuid,uuid,uuid,text,numeric,text,text) to authenticated;

create or replace function public.issue_tariff_payment_request(p_client_id uuid,p_tariff_item_id uuid,p_due_at timestamptz,p_comment text default null)
returns uuid language plpgsql security definer set search_path='' as $$ declare v_i uuid:=private.current_instructor_id();i public.tariff_items;r record;v_s uuid;v_id uuid;begin
 if v_i is null then raise exception 'Только инструктор может выставить оплату';end if;
 select * into i from public.tariff_items where id=p_tariff_item_id and active and category='lesson';if not found then raise exception 'Для счёта выберите занятие или абонемент';end if;
 if not exists(select 1 from public.client_instructors where client_id=p_client_id and instructor_id=v_i) then raise exception 'Клиент не прикреплён к инструктору';end if;
 if not exists(select 1 from public.instructors where id=v_i and payment_bank_name is not null and payment_sbp_phone is not null and payment_recipient_name is not null) then raise exception 'Сначала заполните реквизиты получения оплаты';end if;
 select * into r from private.resolve_tariff_rate(i.id,v_i,now());if r.client_price is null or r.pool_amount is null then raise exception 'Для инструктора не настроена ставка';end if;
 v_s:=private.get_or_create_subscription_impl(p_client_id,i.lesson_format,i.duration_minutes,v_i);
 insert into public.payment_requests(client_id,instructor_id,subscription_id,quantity,amount,format,duration_minutes,due_at,comment,tariff_item_id,standard_client_price,pool_amount,tariff_template_id) values(p_client_id,v_i,v_s,i.credit_quantity,r.client_price,i.lesson_format,i.duration_minutes,p_due_at,nullif(trim(p_comment),''),i.id,r.client_price,r.pool_amount,r.template_id) returning id into v_id;
 return v_id;
end $$;
revoke all on function public.issue_tariff_payment_request(uuid,uuid,timestamptz,text) from public,anon;grant execute on function public.issue_tariff_payment_request(uuid,uuid,timestamptz,text) to authenticated;

create or replace function public.confirm_payment_request(p_request_id uuid,p_received boolean) returns void language plpgsql security definer set search_path='' as $$ declare r public.payment_requests;p public.payments;begin
 select * into r from public.payment_requests where id=p_request_id for update;if not found or r.instructor_id<>private.current_instructor_id() or r.status<>'reported' then raise exception 'Запрос не найден или не ожидает проверки';end if;
 if p_received then p:=private.add_payment_impl(r.subscription_id,r.instructor_id,r.quantity,r.amount,'Оплата по запросу '||r.id);update public.payments set payment_method='invoice' where id=p.id;
  if r.tariff_item_id is not null then insert into public.payment_tariff_snapshots(payment_id,tariff_item_id,instructor_id,template_id,standard_client_price,charged_amount,pool_amount) values(p.id,r.tariff_item_id,r.instructor_id,r.tariff_template_id,r.standard_client_price,r.amount,r.pool_amount);end if;
  update public.payment_requests set status='paid',payment_id=p.id,confirmed_at=now(),confirmed_by=auth.uid(),updated_at=now() where id=r.id;
 else update public.payment_requests set status='disputed',confirmed_at=now(),confirmed_by=auth.uid(),updated_at=now() where id=r.id;end if;
end $$;
revoke all on function public.confirm_payment_request(uuid,boolean) from public,anon;grant execute on function public.confirm_payment_request(uuid,boolean) to authenticated;

create or replace function public.get_manager_tariff_finance(p_from timestamptz,p_to timestamptz,p_instructor_id uuid default null)
returns table(entry_id uuid,occurred_at timestamptz,client_name text,instructor_id uuid,instructor_name text,item_name text,charged_amount numeric,pool_amount numeric,instructor_income numeric,payment_method text,entry_type text) language plpgsql stable security definer set search_path='' as $$ begin
 if not private.is_manager() then raise exception 'Недостаточно прав';end if;
 return query
 select p.id,p.paid_at,coalesce(c.name,'Клиент'),p.instructor_id,i.name,t.name,s.charged_amount,s.pool_amount,s.instructor_income,p.payment_method,'Оплата занятий' from public.payment_tariff_snapshots s join public.payments p on p.id=s.payment_id join public.subscriptions sub on sub.id=p.subscription_id left join public.clients c on c.id=sub.client_id join public.instructors i on i.id=p.instructor_id join public.tariff_items t on t.id=s.tariff_item_id where p.paid_at between p_from and p_to and (p_instructor_id is null or p.instructor_id=p_instructor_id)
 union all
 select s.id,s.sold_at,c.name,s.instructor_id,i.name,t.name,s.charged_amount,s.pool_amount,s.instructor_income,s.payment_method,case when t.category='product' then 'Товар' else 'Услуга' end from public.catalog_sales s join public.clients c on c.id=s.client_id join public.instructors i on i.id=s.instructor_id join public.tariff_items t on t.id=s.tariff_item_id where s.sold_at between p_from and p_to and (p_instructor_id is null or s.instructor_id=p_instructor_id)
 order by 2 desc;
end $$;
revoke all on function public.get_manager_tariff_finance(timestamptz,timestamptz,uuid) from public,anon;grant execute on function public.get_manager_tariff_finance(timestamptz,timestamptz,uuid) to authenticated;

drop function if exists public.get_payment_journal(uuid);
create function public.get_payment_journal(p_instructor_id uuid default null)
returns table(payment_id uuid,paid_at timestamptz,client_ids uuid[],client_names text,instructor_id uuid,instructor_name text,format text,duration_minutes integer,quantity numeric,amount numeric,comment text,operation_kind text,payment_method text) language plpgsql stable security definer set search_path='' as $$ declare v_role public.app_role;v_own uuid;v_filter uuid;begin
 select role,app_users.instructor_id into v_role,v_own from public.app_users where id=auth.uid();if v_role is null then raise exception 'Нет доступа';end if;v_filter:=case when v_role='instructor' then v_own else p_instructor_id end;
 return query
 select p.id,p.paid_at,o.client_ids,o.client_names,p.instructor_id,coalesce(i.name,'Инструктор не указан'),s.format,s.duration_minutes,p.quantity,p.amount,p.comment,case when p.amount is not null then 'payment' when coalesce(p.comment,'') ilike '%начальн%' then 'initial' else 'correction' end,p.payment_method from public.payments p join public.subscriptions s on s.id=p.subscription_id left join public.instructors i on i.id=p.instructor_id cross join lateral(select array_agg(c.id order by c.name) client_ids,string_agg(c.name,', ' order by c.name) client_names from public.clients c where c.id=s.client_id or exists(select 1 from public.subscription_group_members gm where gm.group_id=s.group_id and gm.client_id=c.id))o where v_filter is null or p.instructor_id=v_filter
 union all
 select x.id,x.sold_at,array[x.client_id],c.name,x.instructor_id,i.name,t.name,null::integer,0::numeric,x.charged_amount,x.comment,'sale',x.payment_method from public.catalog_sales x join public.clients c on c.id=x.client_id join public.instructors i on i.id=x.instructor_id join public.tariff_items t on t.id=x.tariff_item_id where v_filter is null or x.instructor_id=v_filter
 order by 2 desc;
end $$;
revoke all on function public.get_payment_journal(uuid) from public,anon;grant execute on function public.get_payment_journal(uuid) to authenticated;

drop function if exists public.get_my_child_payments(uuid);
create function public.get_my_child_payments(p_client_id uuid)
returns table(entry_id uuid,occurred_at timestamptz,format text,duration_minutes integer,quantity numeric,amount numeric,comment text,instructor_name text,operation_kind text,payment_method text) language plpgsql stable security definer set search_path='' as $$ begin
 if not private.guardian_can_access_client(p_client_id) then raise exception 'Нет доступа к клиенту';end if;if not exists(select 1 from public.client_guardians cg where cg.guardian_id=private.current_guardian_id() and cg.client_id=p_client_id and cg.can_view_finances) then raise exception 'Просмотр оплат отключён';end if;
 return query with owned as(select s.id,s.format,s.duration_minutes from public.subscriptions s where s.client_id=p_client_id or exists(select 1 from public.subscription_group_members gm where gm.group_id=s.group_id and gm.client_id=p_client_id)),entries as(
 select p.id entry_id,p.paid_at occurred_at,o.format,o.duration_minutes,p.quantity,p.amount,p.comment,coalesce(i.name,'Инструктор не указан') instructor_name,case when p.amount is not null then 'payment' when coalesce(p.comment,'') ilike '%начальн%' then 'initial' else 'correction' end operation_kind,p.payment_method from public.payments p join owned o on o.id=p.subscription_id left join public.instructors i on i.id=p.instructor_id
 union all select x.id,x.occurred_at,o.format,o.duration_minutes,x.quantity,null::numeric,x.comment,coalesce(i.name,'Инструктор не указан'),'correction','unspecified' from public.subscription_operations x join owned o on o.id=x.subscription_id left join public.instructors i on i.id=x.instructor_id where x.operation='correction' and not exists(select 1 from public.payments p where p.subscription_id=x.subscription_id and p.paid_at=x.occurred_at and p.quantity=x.quantity)
 union all select s.id,s.sold_at,t.name,null::integer,0::numeric,s.charged_amount,s.comment,i.name,'sale',s.payment_method from public.catalog_sales s join public.tariff_items t on t.id=s.tariff_item_id join public.instructors i on i.id=s.instructor_id where s.client_id=p_client_id)
 select e.entry_id,e.occurred_at,e.format,e.duration_minutes,e.quantity,e.amount,e.comment,e.instructor_name,e.operation_kind,e.payment_method from entries e order by e.occurred_at desc;
end $$;
revoke all on function public.get_my_child_payments(uuid) from public,anon;grant execute on function public.get_my_child_payments(uuid) to authenticated;

-- Harden the legacy function too: body checks are not a replacement for function ACLs.
revoke all on function public.issue_payment_request(uuid,text,integer,numeric,numeric,timestamptz,text) from public,anon;
grant execute on function public.issue_payment_request(uuid,text,integer,numeric,numeric,timestamptz,text) to authenticated;
select pg_notify('pgrst','reload schema');

