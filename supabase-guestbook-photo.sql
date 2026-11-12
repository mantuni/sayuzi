-- 사유지 거닐기 · 방명록 사진 + 흔적/방명록 권한 고치기
-- Supabase → SQL Editor → New query 에 전부 붙여넣고 Run 한 번. 여러 번 실행해도 괜찮아요.

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
