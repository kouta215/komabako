-- コマバコ 更新その2：連載（第2話、第3話…）に対応
-- Supabase の「SQL Editor」に全部貼り付けて、一度だけ「Run」を押してください。

alter table public.works add column parent_id uuid references public.works(id) on delete cascade;
alter table public.works add column episode_no int not null default 1 check (episode_no between 1 and 9999);
alter table public.works add column episode_title text not null default '' check (char_length(episode_title) <= 60);
create unique index works_episode_unique on public.works (parent_id, episode_no) where parent_id is not null;

-- 続きの話を足せるのは、その作品の作者だけ
create function public.owns_root(root uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.works where id = root and user_id = auth.uid() and parent_id is null)
$$;

drop policy "works insert" on public.works;
create policy "works insert" on public.works for insert to authenticated
  with check (
    user_id = auth.uid()
    and pages[1] like auth.uid()::text || '/%'
    and (parent_id is null or public.owns_root(parent_id))
  );

-- 作品一覧：1作品を1つにまとめ、話数と最終更新日を付ける
drop view public.work_list;
create view public.work_list as
select w.id, w.user_id, w.title, w.author, w.description, w.pages, w.created_at,
  (select count(*) from public.likes l     where l.work_id = w.id)::int as like_count,
  (select count(*) from public.bookmarks b where b.work_id = w.id)::int as shelf_count,
  (select count(*) from public.views v     where v.work_id = w.id)::int as view_count,
  (1 + (select count(*) from public.works e where e.parent_id = w.id))::int as episode_count,
  greatest(w.created_at, coalesce((select max(e.created_at) from public.works e where e.parent_id = w.id), w.created_at)) as updated_at
from public.works w
where w.parent_id is null;
grant select on public.work_list to anon, authenticated;
