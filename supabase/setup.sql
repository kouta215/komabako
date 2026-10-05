-- コマバコ 初期設定
-- Supabase の「SQL Editor」に全部貼り付けて、一度だけ「Run」を押してください。

-- ========== テーブル ==========
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  pen_name text not null default '' check (char_length(pen_name) <= 30),
  shelf_name text not null default '' check (char_length(shelf_name) <= 30),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.works (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  author text not null check (char_length(author) between 1 and 30),
  description text not null default '' check (char_length(description) <= 200),
  pages text[] not null check (array_length(pages, 1) between 1 and 60),
  created_at timestamptz not null default now()
);
create index works_created_at on public.works (created_at desc);

create table public.likes (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  work_id uuid not null references public.works on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, work_id)
);
create index likes_work on public.likes (work_id);

create table public.bookmarks (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  work_id uuid not null references public.works on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, work_id)
);
create index bookmarks_work on public.bookmarks (work_id);

-- 読んだ人数（ログイン中は会員ID、未ログインは端末ごとのID）
create table public.views (
  work_id uuid not null references public.works on delete cascade,
  viewer text not null check (char_length(viewer) between 8 and 64),
  created_at timestamptz not null default now(),
  primary key (work_id, viewer)
);

create table public.reports (
  id bigint generated always as identity primary key,
  work_id uuid not null references public.works on delete cascade,
  reason text not null check (char_length(reason) <= 40),
  user_id uuid references auth.users on delete set null,
  created_at timestamptz not null default now()
);

-- ========== 管理者かどうか ==========
create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ========== 会員登録時にプロフィールを自動作成 ==========
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, pen_name)
  values (new.id, left(coalesce(new.raw_user_meta_data->>'pen_name', ''), 30));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ========== 権限（誰が何をできるか） ==========
alter table public.profiles  enable row level security;
alter table public.works     enable row level security;
alter table public.likes     enable row level security;
alter table public.bookmarks enable row level security;
alter table public.views     enable row level security;
alter table public.reports   enable row level security;

revoke all on public.profiles, public.works, public.likes, public.bookmarks, public.views, public.reports from anon, authenticated;

-- プロフィール：誰でも読める。本人はペンネームと本棚名だけ変えられる（管理者フラグは変えられない）
grant select on public.profiles to anon, authenticated;
grant update (pen_name, shelf_name) on public.profiles to authenticated;
create policy "profiles read"   on public.profiles for select using (true);
create policy "profiles update" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- 作品：誰でも読める。投稿は会員本人として。削除は本人か管理者
grant select on public.works to anon, authenticated;
grant insert, delete on public.works to authenticated;
create policy "works read"   on public.works for select using (true);
create policy "works insert" on public.works for insert to authenticated
  with check (user_id = auth.uid() and pages[1] like auth.uid()::text || '/%');
create policy "works delete" on public.works for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- いいね：自分の分だけ読み書き
grant select, insert, delete on public.likes to authenticated;
create policy "likes read"   on public.likes for select to authenticated using (user_id = auth.uid());
create policy "likes insert" on public.likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes delete" on public.likes for delete to authenticated using (user_id = auth.uid());

-- 本棚：シェアできるよう誰でも読める。追加・削除は本人だけ
grant select on public.bookmarks to anon, authenticated;
grant insert, delete on public.bookmarks to authenticated;
create policy "bookmarks read"   on public.bookmarks for select using (true);
create policy "bookmarks insert" on public.bookmarks for insert to authenticated with check (user_id = auth.uid());
create policy "bookmarks delete" on public.bookmarks for delete to authenticated using (user_id = auth.uid());

-- 閲覧：記録の追加だけ（中身は誰も読めない。人数は下の一覧で集計）
grant insert on public.views to anon, authenticated;
create policy "views insert" on public.views for insert with check (true);

-- 通報：誰でも送れる。読めるのと消せるのは管理者だけ
grant insert on public.reports to anon, authenticated;
grant select, delete on public.reports to authenticated;
create policy "reports insert" on public.reports for insert
  with check (user_id is null or user_id = auth.uid());
create policy "reports read"   on public.reports for select to authenticated using (public.is_admin());
create policy "reports delete" on public.reports for delete to authenticated using (public.is_admin());

-- ========== 作品一覧（いいね数・本棚数・読んだ人数つき） ==========
create view public.work_list as
select w.id, w.user_id, w.title, w.author, w.description, w.pages, w.created_at,
  (select count(*) from public.likes l     where l.work_id = w.id)::int as like_count,
  (select count(*) from public.bookmarks b where b.work_id = w.id)::int as shelf_count,
  (select count(*) from public.views v     where v.work_id = w.id)::int as view_count
from public.works w;
grant select on public.work_list to anon, authenticated;

-- ========== 画像の保存場所 ==========
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pages', 'pages', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "pages read" on storage.objects for select
  using (bucket_id = 'pages');
create policy "pages upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'pages' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "pages delete own or admin" on storage.objects for delete to authenticated
  using (bucket_id = 'pages' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
