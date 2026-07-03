# ขั้นตอนตั้งค่า Supabase สำหรับระบบจัดการการเงินนักศึกษา

ระบบนี้ใช้ **username/password ของตัวเอง** (ไม่ใช้ Supabase Auth) รหัสผ่านถูก hash ด้วย `pgcrypto`
(bcrypt) ก่อนเก็บลงฐานข้อมูลเสมอ การตรวจสอบสิทธิ์ทั้งหมดทำผ่าน RPC function ในฐานข้อมูล
ไม่ต้องมี Edge Function หรือเซิร์ฟเวอร์เพิ่มเติมใดๆ

## ขั้นตอนตั้งค่า (ทำครั้งเดียว)

1. เปิด Supabase Dashboard ของโปรเจกต์คุณ → เมนู **SQL Editor**
2. คัดลอกเนื้อหาทั้งหมดในไฟล์ [`schema.sql`](schema.sql) ไปวาง แล้วกด **Run**
   - จะได้ตาราง `profiles`, `sessions`, `accounts`, `expense_categories`, `income_categories`, `transactions`
   - RPC function ทั้งหมดที่แอปเรียกใช้ (login, get_app_state, add_transaction ฯลฯ)
   - บัญชีแอดมินเริ่มต้น 1 บัญชี: **username `admin` / password `1234`**
3. เข้าสู่ระบบด้วย `admin` / `1234` แล้ว **เปลี่ยนรหัสผ่านทันทีที่เมนู "บัญชีของฉัน"** ก่อนใช้งานจริง
4. ใช้เมนู "เพิ่มผู้ใช้งาน" ในหน้า Admin สร้างอาจารย์ที่ปรึกษาและนักศึกษาจริงตามต้องการ

## ความปลอดภัยที่ออกแบบไว้

- ทุกตารางเปิด Row Level Security (RLS) แต่ไม่มี policy ใดๆ ผูกไว้เลย → ปิดกั้นการเข้าถึงผ่าน REST API
  โดยตรงทั้งหมด (ต่อให้มี anon key ก็ query ตารางตรงๆ ไม่ได้)
- การเข้าถึง/แก้ไขข้อมูลทั้งหมดต้องผ่าน RPC function ที่ตรวจสอบ session token + สิทธิ์ตามบทบาทก่อนทุกครั้ง
- รหัสผ่านเก็บเป็น bcrypt hash เท่านั้น ไม่มีการเก็บ plain text ที่ใดในระบบ
- Session token มีอายุ 30 วัน (ปรับได้ในฟังก์ชัน `sessions.expires_at` ของ schema.sql)

## หมายเหตุสำหรับผู้ดูแลระบบ

- ถ้าต้องการรีเซ็ตรหัสผ่านให้ผู้ใช้คนอื่น: แก้ไขผู้ใช้นั้นในหน้า Admin แล้วกรอกรหัสผ่านใหม่ในช่อง "รหัสผ่าน"
- ถ้าลืมรหัสผ่านแอดมินเอง และไม่มีแอดมินคนอื่นช่วยรีเซ็ตให้ได้ ให้รันคำสั่งนี้ใน SQL Editor
  (แทนที่ `<username>` และ `<new_password>` ตามจริง):

```sql
update public.profiles
set password_hash = crypt('<new_password>', gen_salt('bf'))
where username = '<username>';
```
