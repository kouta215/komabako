# コマバコ

だれでも漫画を投稿して、縦スクロールで読めるサイト。

- `index.html` … サイト本体
- `config.js` … Supabase の接続先（Project URL と anon public キーを貼る）
- `terms.html` / `privacy.html` … 利用規約とプライバシーポリシーの下書き
- `supabase/setup.sql` … Supabase の SQL Editor で一度だけ実行する初期設定

## 管理者になる（通報の確認・他人の作品の削除）

サイトで会員登録したあと、Supabase の SQL Editor で次を実行（メールアドレスは自分のものに変える）。

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'あなたのメールアドレス');
```
