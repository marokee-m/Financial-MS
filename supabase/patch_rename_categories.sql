-- =========================================================================
-- PATCH: เปลี่ยนชื่อหมวดรายจ่ายเริ่มต้น 2 รายการ
--   "ค่าเล่าเรียน" -> "ค่าอุปกรณ์การเรียน"
--   "ค่ากินอยู่รายวัน" -> "ค่ากินค่าใช้รายวัน"
-- รันไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัยที่จะรันซ้ำได้)
-- =========================================================================

-- 1) เปลี่ยนชื่อหมวดหมู่ที่มีอยู่แล้วของนักศึกษาทุกคนในระบบ (เฉพาะหมวดล็อกเริ่มต้น)
update public.expense_categories set name = 'ค่าอุปกรณ์การเรียน' where name = 'ค่าเล่าเรียน' and locked = true;
update public.expense_categories set name = 'ค่ากินค่าใช้รายวัน' where name = 'ค่ากินอยู่รายวัน' and locked = true;

-- 2) แก้ไขฟังก์ชันสร้างผู้ใช้ใหม่ ให้ใช้ชื่อหมวดใหม่กับนักศึกษาที่จะสร้างในอนาคต
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
      (v_id,'ค่ากินค่าใช้รายวัน','🍜',true), (v_id,'ค่าน้ำมันรถ','⛽',true), (v_id,'ค่าน้ำค่าไฟ','💡',true),
      (v_id,'ค่าอุปกรณ์การเรียน','🎓',true), (v_id,'ค่าผ่อนรายเดือน','💳',true), (v_id,'ค่าเน็ท/บริการต่างๆ','📶',true);
    insert into public.income_categories (student_id, name, icon, locked) values
      (v_id,'เงินเดือน','💰',true), (v_id,'รายได้เสริม','➕',true);
  end if;

  return v_id;
end;
$$;
grant execute on function public.admin_create_user(uuid,text,text,text,text,text,uuid,text,text) to anon, authenticated;
