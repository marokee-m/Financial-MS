-- =========================================================================
-- PATCH: แก้ไข search_path ของทุกฟังก์ชัน (ปัญหา "function crypt(text,text) does not exist")
-- รันไฟล์นี้แทน schema.sql ตัวเต็ม — ตารางและ admin เริ่มต้นถูกสร้างไปแล้วจากรอบแรก
-- ไฟล์นี้ประกอบด้วยแต่ "create or replace function" เท่านั้น ปลอดภัยที่จะรันซ้ำได้เสมอ
-- =========================================================================

-- =========================================================================
-- INTERNAL HELPERS (ไม่เปิดให้ client เรียกตรง)
-- หมายเหตุ: search_path ต้องรวม "extensions" ด้วย เพราะ Supabase ติดตั้ง pgcrypto
-- (crypt/gen_salt) ไว้ในสคีมา extensions ไม่ใช่ public
-- =========================================================================

create or replace function public._require_session(p_token uuid)
returns public.profiles
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_profile public.profiles;
begin
  select p.* into v_profile
  from public.sessions s join public.profiles p on p.id = s.user_id
  where s.token = p_token and s.expires_at > now();

  if not found then
    raise exception 'SESSION_INVALID: เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่อีกครั้ง';
  end if;

  return v_profile;
end;
$$;
revoke all on function public._require_session(uuid) from public, anon, authenticated;

create or replace function public._student_balance(p_student_id uuid)
returns numeric
language sql security definer set search_path = public, extensions as $$
  select coalesce(sum(case when type='income' then amount when type='expense' then -amount else 0 end), 0)
  from public.transactions where student_id = p_student_id;
$$;
revoke all on function public._student_balance(uuid) from public, anon, authenticated;

create or replace function public._account_json(a public.accounts)
returns jsonb
language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', a.id, 'name', a.name, 'type', a.type,
    'balance', (
      select coalesce(sum(
        case
          when t.type='income'  and t.account_id = a.id      then t.amount
          when t.type='expense' and t.account_id = a.id      then -t.amount
          when t.type='transfer' and t.from_account_id = a.id then -t.amount
          when t.type='transfer' and t.to_account_id = a.id   then t.amount
          else 0
        end
      ), 0)
      from public.transactions t
      where t.student_id = a.student_id
        and (t.account_id = a.id or t.from_account_id = a.id or t.to_account_id = a.id)
    )
  );
$$;
revoke all on function public._account_json(public.accounts) from public, anon, authenticated;

-- =========================================================================
-- AUTH RPCs
-- =========================================================================

create or replace function public.login(p_username text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_profile public.profiles;
  v_token uuid;
begin
  select * into v_profile from public.profiles where lower(username) = lower(p_username);

  if not found or v_profile.password_hash <> crypt(p_password, v_profile.password_hash) then
    raise exception 'INVALID_CREDENTIALS: ชื่อผู้ใช้งานหรือรหัสผ่านไม่ถูกต้อง';
  end if;

  insert into public.sessions (user_id) values (v_profile.id) returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'user', jsonb_build_object(
      'id', v_profile.id, 'username', v_profile.username, 'name', v_profile.name,
      'email', v_profile.email, 'role', v_profile.role, 'advisorId', v_profile.advisor_id,
      'major', v_profile.major, 'dept', v_profile.dept
    )
  );
end;
$$;
grant execute on function public.login(text, text) to anon, authenticated;

create or replace function public.logout(p_token uuid)
returns void language sql security definer set search_path = public, extensions as $$
  delete from public.sessions where token = p_token;
$$;
grant execute on function public.logout(uuid) to anon, authenticated;

-- แก้ไข username / รหัสผ่านของตัวเอง (เมนู "บัญชีของฉัน")
create or replace function public.update_my_account(p_token uuid, p_username text, p_new_password text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
begin
  v_me := public._require_session(p_token);

  if exists(select 1 from public.profiles where lower(username) = lower(p_username) and id <> v_me.id) then
    raise exception 'USERNAME_TAKEN: ชื่อผู้ใช้งานนี้มีผู้อื่นใช้งานอยู่แล้ว';
  end if;

  update public.profiles
  set username = p_username,
      password_hash = case when p_new_password is not null and p_new_password <> ''
                            then crypt(p_new_password, gen_salt('bf'))
                            else password_hash end
  where id = v_me.id;
end;
$$;
grant execute on function public.update_my_account(uuid, text, text) to anon, authenticated;

-- =========================================================================
-- READ RPCs
-- =========================================================================

create or replace function public.get_app_state(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_result jsonb;
begin
  v_me := public._require_session(p_token);

  if v_me.role = 'student' then
    v_result := jsonb_build_object(
      'profile', jsonb_build_object('id',v_me.id,'username',v_me.username,'name',v_me.name,'email',v_me.email,'role',v_me.role,'major',v_me.major),
      'accounts', (select coalesce(jsonb_agg(public._account_json(a) order by a.created_at), '[]'::jsonb) from public.accounts a where a.student_id = v_me.id),
      'expenseCategories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'icon',icon,'locked',locked) order by created_at), '[]'::jsonb) from public.expense_categories where student_id = v_me.id),
      'incomeCategories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'icon',icon,'locked',locked) order by created_at), '[]'::jsonb) from public.income_categories where student_id = v_me.id),
      'transactions', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',type,'date',date,'categoryId',category_id,'accountId',account_id,'fromAccountId',from_account_id,'toAccountId',to_account_id,'amount',amount,'note',note) order by date, created_at), '[]'::jsonb) from public.transactions where student_id = v_me.id)
    );

  elsif v_me.role = 'advisor' then
    v_result := jsonb_build_object(
      'profile', jsonb_build_object('id',v_me.id,'username',v_me.username,'name',v_me.name,'email',v_me.email,'role',v_me.role,'dept',v_me.dept),
      'students', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'name', s.name, 'email', s.email, 'major', s.major,
          'accountCount', (select count(*) from public.accounts a where a.student_id = s.id),
          'txnCount', (select count(*) from public.transactions t where t.student_id = s.id),
          'balance', public._student_balance(s.id)
        ) order by s.name), '[]'::jsonb)
        from public.profiles s where s.advisor_id = v_me.id
      )
    );

  elsif v_me.role = 'admin' then
    v_result := jsonb_build_object(
      'profile', jsonb_build_object('id',v_me.id,'username',v_me.username,'name',v_me.name,'email',v_me.email,'role',v_me.role),
      'users', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', u.id, 'name', u.name, 'email', u.email, 'username', u.username, 'role', u.role,
          'advisorId', u.advisor_id, 'major', u.major, 'dept', u.dept,
          'advisorName', (select a.name from public.profiles a where a.id = u.advisor_id),
          'studentCount', (case when u.role='advisor' then (select count(*) from public.profiles st where st.advisor_id = u.id) else null end),
          'balance', (case when u.role='student' then public._student_balance(u.id) else null end)
        ) order by u.role, u.name), '[]'::jsonb)
        from public.profiles u
      )
    );
  end if;

  return v_result;
end;
$$;
grant execute on function public.get_app_state(uuid) to anon, authenticated;

-- ใช้ตอนอาจารย์/แอดมินเปิดดูรายละเอียดนักศึกษารายคน
create or replace function public.get_student_detail(p_token uuid, p_student_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_student public.profiles;
begin
  v_me := public._require_session(p_token);

  select * into v_student from public.profiles where id = p_student_id and role = 'student';
  if not found then raise exception 'NOT_FOUND: ไม่พบนักศึกษา'; end if;

  if not (v_me.role = 'admin' or (v_me.role = 'advisor' and v_student.advisor_id = v_me.id)) then
    raise exception 'FORBIDDEN: ไม่มีสิทธิ์เข้าถึงข้อมูลนี้';
  end if;

  return jsonb_build_object(
    'profile', jsonb_build_object('id',v_student.id,'name',v_student.name,'email',v_student.email,'major',v_student.major),
    'accounts', (select coalesce(jsonb_agg(public._account_json(a) order by a.created_at), '[]'::jsonb) from public.accounts a where a.student_id = v_student.id),
    'expenseCategories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'icon',icon,'locked',locked) order by created_at), '[]'::jsonb) from public.expense_categories where student_id = v_student.id),
    'incomeCategories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'icon',icon,'locked',locked) order by created_at), '[]'::jsonb) from public.income_categories where student_id = v_student.id),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',type,'date',date,'categoryId',category_id,'accountId',account_id,'fromAccountId',from_account_id,'toAccountId',to_account_id,'amount',amount,'note',note) order by date, created_at), '[]'::jsonb) from public.transactions where student_id = v_student.id)
  );
end;
$$;
grant execute on function public.get_student_detail(uuid, uuid) to anon, authenticated;

-- =========================================================================
-- STUDENT MUTATION RPCs (นักศึกษาแก้ไขได้เฉพาะข้อมูลของตัวเองเท่านั้น)
-- =========================================================================

create or replace function public.add_transaction(
  p_token uuid, p_type text, p_date date, p_category_id uuid, p_account_id uuid, p_amount numeric, p_note text
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_id uuid;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'student' then raise exception 'FORBIDDEN'; end if;
  if p_type not in ('income','expense') then raise exception 'INVALID_TYPE'; end if;
  if p_amount <= 0 then raise exception 'INVALID_AMOUNT: จำนวนเงินต้องมากกว่า 0'; end if;

  insert into public.transactions (student_id, type, date, category_id, account_id, amount, note)
  values (v_me.id, p_type, p_date, p_category_id, p_account_id, p_amount, p_note)
  returning id into v_id;

  return v_id;
end;
$$;
grant execute on function public.add_transaction(uuid,text,date,uuid,uuid,numeric,text) to anon, authenticated;

create or replace function public.add_transfer(
  p_token uuid, p_date date, p_from_account_id uuid, p_to_account_id uuid, p_amount numeric, p_note text
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_id uuid;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'student' then raise exception 'FORBIDDEN'; end if;
  if p_from_account_id = p_to_account_id then raise exception 'SAME_ACCOUNT: บัญชีต้นทางและปลายทางต้องต่างกัน'; end if;
  if p_amount <= 0 then raise exception 'INVALID_AMOUNT: จำนวนเงินต้องมากกว่า 0'; end if;

  insert into public.transactions (student_id, type, date, from_account_id, to_account_id, amount, note)
  values (v_me.id, 'transfer', p_date, p_from_account_id, p_to_account_id, p_amount, p_note)
  returning id into v_id;

  return v_id;
end;
$$;
grant execute on function public.add_transfer(uuid,date,uuid,uuid,numeric,text) to anon, authenticated;

create or replace function public.edit_transaction(
  p_token uuid, p_txn_id uuid, p_date date, p_category_id uuid, p_account_id uuid, p_amount numeric, p_note text
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
begin
  v_me := public._require_session(p_token);
  if p_amount <= 0 then raise exception 'INVALID_AMOUNT: จำนวนเงินต้องมากกว่า 0'; end if;

  update public.transactions
  set date = p_date, category_id = p_category_id, account_id = p_account_id, amount = p_amount, note = p_note
  where id = p_txn_id and student_id = v_me.id and type in ('income','expense');

  if not found then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
end;
$$;
grant execute on function public.edit_transaction(uuid,uuid,date,uuid,uuid,numeric,text) to anon, authenticated;

create or replace function public.delete_transaction(p_token uuid, p_txn_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
begin
  v_me := public._require_session(p_token);
  delete from public.transactions where id = p_txn_id and student_id = v_me.id;
  if not found then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
end;
$$;
grant execute on function public.delete_transaction(uuid,uuid) to anon, authenticated;

create or replace function public.add_account(p_token uuid, p_name text, p_type text)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_count int;
  v_id uuid;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'student' then raise exception 'FORBIDDEN'; end if;
  if p_type not in ('spending','holding','savings') then raise exception 'INVALID_TYPE'; end if;

  select count(*) into v_count from public.accounts where student_id = v_me.id;
  if v_count >= 5 then raise exception 'LIMIT_REACHED: มีบัญชีครบจำนวนสูงสุดแล้ว (5 บัญชี)'; end if;

  insert into public.accounts (student_id, name, type) values (v_me.id, p_name, p_type) returning id into v_id;
  return v_id;
end;
$$;
grant execute on function public.add_account(uuid,text,text) to anon, authenticated;

create or replace function public.delete_account(p_token uuid, p_account_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_acc public.accounts;
  v_balance numeric;
begin
  v_me := public._require_session(p_token);
  select * into v_acc from public.accounts where id = p_account_id and student_id = v_me.id;
  if not found then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  if v_acc.type = 'cash' then raise exception 'CASH_LOCKED: ไม่สามารถลบบัญชีเงินสดหลักได้'; end if;

  select coalesce(sum(
    case
      when type='income'  and account_id = v_acc.id      then amount
      when type='expense' and account_id = v_acc.id      then -amount
      when type='transfer' and from_account_id = v_acc.id then -amount
      when type='transfer' and to_account_id = v_acc.id   then amount
      else 0 end
  ), 0) into v_balance
  from public.transactions
  where student_id = v_me.id and (account_id = v_acc.id or from_account_id = v_acc.id or to_account_id = v_acc.id);

  if v_balance <> 0 then raise exception 'NOT_EMPTY: กรุณาโอนยอดเงินคงเหลือออกจากบัญชีนี้ก่อนลบ'; end if;

  delete from public.accounts where id = v_acc.id;
end;
$$;
grant execute on function public.delete_account(uuid,uuid) to anon, authenticated;

create or replace function public.add_category(p_token uuid, p_kind text, p_name text, p_icon text)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_count int;
  v_max int;
  v_id uuid;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'student' then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('expense','income') then raise exception 'INVALID_KIND'; end if;

  v_max := case when p_kind = 'expense' then 10 else 5 end;
  if p_kind = 'expense' then
    select count(*) into v_count from public.expense_categories where student_id = v_me.id;
  else
    select count(*) into v_count from public.income_categories where student_id = v_me.id;
  end if;
  if v_count >= v_max then raise exception 'LIMIT_REACHED: มีหมวดหมู่ครบจำนวนสูงสุดแล้ว'; end if;

  if p_kind = 'expense' then
    insert into public.expense_categories (student_id, name, icon, locked) values (v_me.id, p_name, coalesce(nullif(p_icon,''),'🏷️'), false) returning id into v_id;
  else
    insert into public.income_categories (student_id, name, icon, locked) values (v_me.id, p_name, coalesce(nullif(p_icon,''),'💵'), false) returning id into v_id;
  end if;
  return v_id;
end;
$$;
grant execute on function public.add_category(uuid,text,text,text) to anon, authenticated;

create or replace function public.delete_category(p_token uuid, p_kind text, p_category_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_locked boolean;
  v_used boolean;
begin
  v_me := public._require_session(p_token);
  if p_kind not in ('expense','income') then raise exception 'INVALID_KIND'; end if;

  if p_kind = 'expense' then
    select locked into v_locked from public.expense_categories where id = p_category_id and student_id = v_me.id;
  else
    select locked into v_locked from public.income_categories where id = p_category_id and student_id = v_me.id;
  end if;
  if v_locked is null then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  if v_locked then raise exception 'LOCKED: ไม่สามารถลบหมวดหมู่เริ่มต้นได้'; end if;

  select exists(
    select 1 from public.transactions
    where student_id = v_me.id and category_id = p_category_id and type = p_kind
  ) into v_used;
  if v_used then raise exception 'IN_USE: ไม่สามารถลบหมวดหมู่นี้ได้ เนื่องจากมีรายการที่ใช้งานอยู่'; end if;

  if p_kind = 'expense' then
    delete from public.expense_categories where id = p_category_id;
  else
    delete from public.income_categories where id = p_category_id;
  end if;
end;
$$;
grant execute on function public.delete_category(uuid,text,uuid) to anon, authenticated;

-- =========================================================================
-- ADMIN MUTATION RPCs
-- =========================================================================

create or replace function public.admin_create_user(
  p_token uuid, p_role text, p_name text, p_email text, p_username text, p_password text,
  p_advisor_id uuid, p_major text, p_dept text
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_id uuid;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if p_role not in ('admin','advisor','student') then raise exception 'INVALID_ROLE'; end if;
  if p_username is null or p_username = '' or p_password is null or p_password = '' then
    raise exception 'MISSING_FIELDS: กรุณากรอกชื่อผู้ใช้งานและรหัสผ่าน';
  end if;
  if exists(select 1 from public.profiles where lower(username) = lower(p_username)) then
    raise exception 'USERNAME_TAKEN: ชื่อผู้ใช้งาน "%" มีผู้ใช้งานอื่นใช้อยู่แล้ว', p_username;
  end if;

  insert into public.profiles (username, password_hash, name, email, role, advisor_id, major, dept)
  values (
    p_username, crypt(p_password, gen_salt('bf')), p_name, p_email, p_role,
    case when p_role = 'student' then p_advisor_id else null end,
    case when p_role = 'student' then p_major else null end,
    case when p_role = 'advisor' then coalesce(p_dept,'') else null end
  )
  returning id into v_id;

  if p_role = 'student' then
    insert into public.accounts (student_id, name, type) values (v_id, 'บัญชีเงินสด', 'cash');
    insert into public.expense_categories (student_id, name, icon, locked) values
      (v_id,'ค่ากินอยู่รายวัน','🍜',true), (v_id,'ค่าน้ำมันรถ','⛽',true), (v_id,'ค่าน้ำค่าไฟ','💡',true),
      (v_id,'ค่าเล่าเรียน','🎓',true), (v_id,'ค่าผ่อนรายเดือน','💳',true), (v_id,'ค่าเน็ท/บริการต่างๆ','📶',true);
    insert into public.income_categories (student_id, name, icon, locked) values
      (v_id,'เงินเดือน','💰',true), (v_id,'รายได้เสริม','➕',true);
  end if;

  return v_id;
end;
$$;
grant execute on function public.admin_create_user(uuid,text,text,text,text,text,uuid,text,text) to anon, authenticated;

create or replace function public.admin_update_user(
  p_token uuid, p_target_id uuid, p_name text, p_email text, p_username text,
  p_password text, p_advisor_id uuid, p_major text
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_target public.profiles;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'admin' then raise exception 'FORBIDDEN'; end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  if exists(select 1 from public.profiles where lower(username) = lower(p_username) and id <> p_target_id) then
    raise exception 'USERNAME_TAKEN: ชื่อผู้ใช้งาน "%" มีผู้ใช้งานอื่นใช้อยู่แล้ว', p_username;
  end if;

  update public.profiles set
    name = p_name,
    email = p_email,
    username = p_username,
    password_hash = case when p_password is not null and p_password <> '' then crypt(p_password, gen_salt('bf')) else password_hash end,
    advisor_id = case when v_target.role = 'student' then p_advisor_id else advisor_id end,
    major = case when v_target.role = 'student' then p_major else major end
  where id = p_target_id;
end;
$$;
grant execute on function public.admin_update_user(uuid,uuid,text,text,text,text,uuid,text) to anon, authenticated;

create or replace function public.admin_delete_user(p_token uuid, p_target_id uuid, p_cascade boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.profiles;
  v_target public.profiles;
  v_students jsonb;
  v_count int;
begin
  v_me := public._require_session(p_token);
  if v_me.role <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if p_target_id = v_me.id then raise exception 'SELF_DELETE: ไม่สามารถลบบัญชีของตัวเองได้'; end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  if v_target.role = 'advisor' then
    select count(*), coalesce(jsonb_agg(name), '[]'::jsonb) into v_count, v_students
    from public.profiles where advisor_id = p_target_id;

    if v_count > 0 and not p_cascade then
      return jsonb_build_object('needsCascadeConfirm', true, 'count', v_count, 'students', v_students);
    end if;
    if p_cascade then
      delete from public.profiles where advisor_id = p_target_id;
    end if;
  end if;

  delete from public.profiles where id = p_target_id;
  return jsonb_build_object('success', true);
end;
$$;
grant execute on function public.admin_delete_user(uuid,uuid,boolean) to anon, authenticated;

-- =========================================================================
-- BOOTSTRAP: สร้างผู้ดูแลระบบคนแรก (ทำครั้งเดียว)
-- username: admin / password: 1234  -- เข้าสู่ระบบครั้งแรกแล้วรีบเปลี่ยนรหัสผ่านที่เมนู "บัญชีของฉัน"
-- =========================================================================
insert into public.profiles (username, password_hash, name, email, role)
values ('admin', crypt('1234', gen_salt('bf')), 'ผู้ดูแลระบบ', 'admin@yru.ac.th', 'admin')
on conflict (username) do nothing;
