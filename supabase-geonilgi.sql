-- 사유지 거닐기(3D 사이트) ↔ 웹앱 연동
-- Supabase → SQL Editor → New query 에 전부 붙여넣고 Run 한 번.
-- 여러 번 실행해도 괜찮아요(이미 있으면 건너뛰거나 새것으로 바꿔요).

-- ① 웹앱 필지 읽기 창구
--    웹앱은 사용자마다 기록 전체를 sayuji_state 한 줄에 저장해요.
--    이 함수는 그중 '다른 사람에게 보여도 되는 부분'만 꺼내 줘요.
--      나가는 것: 묻지 않은 생각(글·날짜·키워드·자리), 웹앱에서 남긴 네모·한 줄 흔적(누가 남겼는지는 빼고)
--      안 나가는 것: 묻은 생각, 이메일·계정, 초안, '나는' 요약, 사진, 작품 정보, 예시 생각(t01… b01…)
--    필지는 user_id 대신 알아볼 수 없는 열쇠(md5)로만 구분해요.
create or replace function public.geonilgi(known text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  stamp text;
  result jsonb;
begin
  -- 바뀐 게 없으면 짧게 답해서 4초마다 물어봐도 가볍게
  select md5(coalesce(string_agg(s.user_id::text || ':' || coalesce(s.updated_at::text, ''), ',' order by s.user_id::text), ''))
    into stamp from public.sayuji_state s;
  if known is not null and known = stamp then
    return jsonb_build_object('stamp', stamp);
  end if;

  with st as (
    select md5(s.user_id::text) as land, u.created_at as joined, s.data
    from public.sayuji_state s
    left join auth.users u on u.id = s.user_id
  ),
  lands as (
    select jsonb_agg(jsonb_build_object(
      'land', st.land,
      'joined', st.joined,
      'thoughts', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', e.v->>'id', 'date', e.v->>'date', 'kw', e.v->'kw',
          'x', e.v->'x', 'y', e.v->'y', 'text', e.v->>'text') order by e.i)
        from jsonb_array_elements(case when jsonb_typeof(st.data->'thoughts') = 'array' then st.data->'thoughts' else '[]'::jsonb end) with ordinality as e(v, i)
        where coalesce(e.v->>'buried', 'false') <> 'true'
          and coalesce(e.v->>'id', '') !~ '^[tb][0-9][0-9]$'
      ), '[]'::jsonb)
    ) order by st.joined nulls last, st.land) as j
    from st
  ),
  sq as (
    select k.key, count(*) as n
    from st, jsonb_object_keys(case when jsonb_typeof(st.data->'squares') = 'object' then st.data->'squares' else '{}'::jsonb end) as k(key)
    group by k.key
  ),
  tl as (
    select case when coalesce(e.v->>'th', '') = '' then e.v->>'plot' else (e.v->>'plot') || '/' || (e.v->>'th') end as key,
           left(e.v->>'text', 60) as txt, e.v->>'date' as d
    from st, jsonb_array_elements(case when jsonb_typeof(st.data->'traces') = 'array' then st.data->'traces' else '[]'::jsonb end) as e(v)
    where coalesce(e.v->>'text', '') <> '' and coalesce(e.v->>'plot', '') <> ''
  )
  select jsonb_build_object(
    'stamp', stamp,
    'lands', coalesce((select j from lands), '[]'::jsonb),
    'squares', coalesce((select jsonb_object_agg(key, n) from sq), '{}'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'text', txt, 'date', d) order by d desc nulls last) from tl), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function public.geonilgi(text) from public;
grant execute on function public.geonilgi(text) to anon, authenticated;


-- ② 거닐기에서 남기는 표정 흔적
create table if not exists public.traces (
  id bigint generated always as identity primary key,
  thought_id text not null,
  emoticon text not null,
  created_at timestamptz default now()
);
alter table public.traces enable row level security;
drop policy if exists "흔적 보기" on public.traces;
drop policy if exists "흔적 남기기" on public.traces;
create policy "흔적 보기" on public.traces for select using (true);
create policy "흔적 남기기" on public.traces for insert with check (char_length(emoticon) < 40 and char_length(thought_id) <= 80);


-- ③ 방명록 싸인
create table if not exists public.guestbook (
  id bigint generated always as identity primary key,
  strokes jsonb not null,
  aspect real default 1,
  created_at timestamptz default now()
);
alter table public.guestbook enable row level security;
drop policy if exists "방명록 보기" on public.guestbook;
drop policy if exists "방명록 남기기" on public.guestbook;
create policy "방명록 보기" on public.guestbook for select using (true);
create policy "방명록 남기기" on public.guestbook for insert with check (pg_column_size(strokes) < 60000);


-- ④ 흔적·방명록 권한 + 방명록 사진 (supabase-guestbook-photo.sql과 같은 내용)
-- ⓐ 흔적·방명록 표를 거닐기 사이트(로그인 없는 방문자)가 읽고 쓸 수 있게
--    (이 프로젝트는 새 표가 자동으로 열리지 않는 설정이라, 지금까지 방명록이 서버에 안 남았어요)
grant usage on schema public to anon, authenticated;
grant select, insert on public.traces, public.guestbook to anon, authenticated;

-- ⓑ 방명록에 사진 이름 칸
alter table public.guestbook add column if not exists photo text;
drop policy if exists "방명록 남기기" on public.guestbook;
create policy "방명록 남기기" on public.guestbook for insert
  with check (pg_column_size(strokes) < 60000 and (photo is null or photo ~ '^[a-z0-9-]{1,80}\.jpg$'));

-- ⓒ 사진을 담는 공개 저장소 'guestbook' (사진 한 장 최대 2MB, jpg만)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('guestbook', 'guestbook', true, 2097152, array['image/jpeg'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 누구나 새 사진을 올릴 수는 있지만, 남의 사진을 덮어쓰거나 지울 수는 없음
drop policy if exists "방명록 사진 올리기" on storage.objects;
create policy "방명록 사진 올리기" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'guestbook' and name ~ '^[a-z0-9-]{1,80}\.jpg$');


-- 확인: 아래 한 줄을 따로 실행하면 거닐기에 보낼 내용이 보여요
-- select public.geonilgi();
