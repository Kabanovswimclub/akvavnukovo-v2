-- Public profile data is separate from staff contacts, rates and internal comments.
create table public.coach_public_cards(
 instructor_id uuid primary key references public.instructors(id),
 published jsonb not null default '{"bio":"","photo_url":"","week":["График уточняется","График уточняется","График уточняется","График уточняется","График уточняется","График уточняется","График уточняется"]}',
 proposed jsonb,
 revision integer not null default 1,
 updated_by uuid references auth.users(id),updated_at timestamptz not null default now(),
 proposed_by uuid references auth.users(id),proposed_at timestamptz
);
alter table public.coach_public_cards enable row level security;
revoke all on public.coach_public_cards from public,anon,authenticated;

create function private.validate_coach_card(p_card jsonb) returns void language plpgsql set search_path='' as $$
begin
 if p_card is null or jsonb_typeof(p_card)<>'object' or not(p_card ?& array['bio','photo_url','week']) then raise exception 'Некорректная карточка';end if;
 if jsonb_typeof(p_card->'bio')<>'string' or jsonb_typeof(p_card->'photo_url')<>'string' then raise exception 'Некорректное описание';end if;
 if length(p_card->>'bio')>4000 or length(p_card->>'photo_url')>1000 then raise exception 'Слишком длинное описание или ссылка';end if;
 if p_card->>'photo_url'<>'' and p_card->>'photo_url' !~ '^https://[^[:space:]]+$' then raise exception 'Для фотографии нужна HTTPS-ссылка';end if;
 if jsonb_typeof(p_card->'week')<>'array' then raise exception 'Нужен недельный график';end if;
 if jsonb_array_length(p_card->'week')<>7 then raise exception 'Укажите семь дней';end if;
 if exists(select 1 from jsonb_array_elements(p_card->'week') d where jsonb_typeof(d)<>'string' or length(d#>>'{}')>200) then raise exception 'Некорректный день графика';end if;
end$$;
revoke all on function private.validate_coach_card(jsonb) from public,anon,authenticated;

create function public.get_parent_coach_catalog(p_client_id uuid default null)
returns table(instructor_id uuid,name text,card jsonb,is_mine boolean)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or private.current_guardian_id() is null then raise exception 'Нужен вход родителя';end if;
 if p_client_id is not null and not coalesce(private.guardian_can_access_client(p_client_id),false) then raise exception 'Нет доступа к ребёнку';end if;
 return query select i.id,i.name,c.published,exists(select 1 from public.client_instructors ci where ci.instructor_id=i.id and ci.client_id=p_client_id)
 from public.instructors i join public.coach_public_cards c on c.instructor_id=i.id where i.status='active' order by i.name;
end$$;
revoke all on function public.get_parent_coach_catalog(uuid) from public,anon;grant execute on function public.get_parent_coach_catalog(uuid) to authenticated;

create function public.get_coach_card_editor(p_instructor_id uuid default null)
returns table(instructor_id uuid,name text,published jsonb,proposed jsonb,revision integer,can_publish boolean)
language plpgsql security definer set search_path='' as $$
declare v_id uuid:=coalesce(p_instructor_id,private.current_instructor_id());v_manager boolean:=coalesce(private.is_manager(),false);
begin
 if auth.uid() is null or v_id is null or not(v_manager or v_id=coalesce(private.current_instructor_id(),'00000000-0000-0000-0000-000000000000'::uuid)) then raise exception 'Нет доступа';end if;
 insert into public.coach_public_cards(instructor_id) select i.id from public.instructors i where i.id=v_id on conflict do nothing;
 return query select i.id,i.name,c.published,c.proposed,c.revision,v_manager from public.instructors i join public.coach_public_cards c on c.instructor_id=i.id where i.id=v_id;
end$$;
revoke all on function public.get_coach_card_editor(uuid) from public,anon;grant execute on function public.get_coach_card_editor(uuid) to authenticated;

create function public.save_coach_public_card(p_instructor_id uuid,p_card jsonb,p_revision integer)
returns void language plpgsql security definer set search_path='' as $$
declare v_manager boolean:=coalesce(private.is_manager(),false);v_old public.coach_public_cards;v_clean jsonb;
begin
 if auth.uid() is null or not(v_manager or p_instructor_id=coalesce(private.current_instructor_id(),'00000000-0000-0000-0000-000000000000'::uuid)) then raise exception 'Нет доступа';end if;
 perform private.validate_coach_card(p_card);
 select * into v_old from public.coach_public_cards c where c.instructor_id=p_instructor_id for update;
 if not found or v_old.revision is distinct from p_revision then raise exception 'Карточка уже изменилась. Обновите страницу перед сохранением';end if;
 v_clean:=jsonb_build_object('bio',p_card->>'bio','photo_url',p_card->>'photo_url','week',p_card->'week');
 if v_manager then
 update public.coach_public_cards set published=v_clean,proposed=null,proposed_by=null,proposed_at=null,revision=revision+1,updated_by=auth.uid(),updated_at=now() where instructor_id=p_instructor_id;
 else
 update public.coach_public_cards set proposed=v_clean,proposed_by=auth.uid(),proposed_at=now(),revision=revision+1 where instructor_id=p_instructor_id;
 end if;
 insert into public.audit_log(actor_user_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),case when v_manager then 'publish_coach_card' else 'propose_coach_card' end,'coach_public_cards',p_instructor_id,to_jsonb(v_old),v_clean);
end$$;
revoke all on function public.save_coach_public_card(uuid,jsonb,integer) from public,anon;grant execute on function public.save_coach_public_card(uuid,jsonb,integer) to authenticated;

-- No duplicate staff records are created. Existing instructors receive empty public cards.
insert into public.coach_public_cards(instructor_id) select id from public.instructors on conflict do nothing;
-- Elena's wording, no inferred clock times. Unspecified days remain unspecified.
with seed(surname,week) as(values
 ('крайникова','["График уточняется","Первая и вторая половина дня","График уточняется","Первая и вторая половина дня","График уточняется","Первая половина дня","График уточняется"]'::jsonb),
 ('шевцов','["Вторая половина дня","Первая и вторая половина дня","Первая и вторая половина дня","Первая и вторая половина дня","График уточняется","Первая и вторая половина дня","Первая половина дня (до 17)"]'::jsonb),
 ('андриенко','["Первая и вторая половина дня","График уточняется","Первая и вторая половина дня","Вторая половина дня","Первая и вторая половина дня","График уточняется","График уточняется"]'::jsonb),
 ('толкачева','["Первая и вторая половина дня","График уточняется","Первая и вторая половина дня","График уточняется","График уточняется","Первая половина дня","Первая половина дня"]'::jsonb)
) update public.coach_public_cards c set published=jsonb_set(c.published,'{week}',seed.week) from public.instructors i,seed where i.id=c.instructor_id and replace(lower(i.name),'ё','е') like '%'||seed.surname||'%';
-- Website materials are drafts. Manager reviews them before exposing them to parents.
with seed(surname,bio,photo) as(values
 ('шевцов','Раннее и грудничковое плавание. Обучение технике, помощь при страхе воды, развитие координации.','https://static.tildacdn.com/tild6334-6463-4534-a437-373737313866/photo_53415444616263.jpg'),
 ('андриенко','Грудничковое плавание и гидрореабилитация. Работа с детьми от рождения до семи лет.','https://static.tildacdn.com/tild3261-6633-4630-b337-323033633439/photo_53998947620283.jpg'),
 ('сухорукова','Мастер спорта по плаванию. Обучение детей и взрослых, работа со страхом воды и постановкой техники.','https://static.tildacdn.com/tild3066-3162-4766-a238-323262303264/photo_53998947620283.jpg'),
 ('толкачева','Раннее и грудничковое плавание. Занятия для развития дыхания, двигательных навыков и ощущения собственного тела.','https://static.tildacdn.com/tild3639-3461-4633-b461-386636623936/483039fa-6f31-4938-8.jpg'),
 ('ширганов','Кандидат в мастера спорта по плаванию. Раннее плавание, обучение разным стилям и помощь в преодолении страха воды.','https://static.tildacdn.com/tild3461-6337-4162-b137-646335333133/photo_53685755555632.jpg'),
 ('крайникова','Основатель и тренер АкваВнуково. Подбирает программы занятий и контролирует качество работы бассейна.','https://static.tildacdn.com/tild3439-6531-4564-a165-626238333165/image.png')
) update public.coach_public_cards c set proposed=jsonb_build_object('bio',seed.bio,'photo_url',seed.photo,'week',c.published->'week'),proposed_at=now() from public.instructors i,seed where i.id=c.instructor_id and replace(lower(i.name),'ё','е') like '%'||seed.surname||'%';
select pg_notify('pgrst','reload schema');
