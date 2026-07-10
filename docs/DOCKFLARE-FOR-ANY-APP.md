# Kinh nghiệm: dùng DockFlare để expose BẤT KỲ app nào

> Rút ra từ lần triển khai OmniRoute này. Áp dụng cho mọi app khác (n8n, Grafana,
> Nextcloud, API nội bộ…) muốn đưa ra Internet qua Cloudflare Tunnel mà không
> mở cổng, không cấu hình dashboard bằng tay.

## Mô hình cốt lõi (nhớ 1 câu)

**DockFlare = control plane. App của bạn chỉ cần 3 label + chung 1 network.**
DockFlare theo dõi Docker, thấy label thì tự tạo DNS + tunnel ingress + (tùy chọn) Access.
Bạn không viết code, không đụng dashboard Cloudflare.

## 3 label bắt buộc trên container app

```yaml
services:
  myapp:
    image: some/app:tag
    restart: unless-stopped
    networks: [cloudflare-net]      # PHẢI chung network với DockFlare
    labels:
      - dockflare.enable=true
      - dockflare.hostname=myapp.example.com     # domain nằm trong zone Cloudflare của bạn
      - dockflare.service=http://myapp:8080       # tên-service : cổng NỘI BỘ (không publish ra host)
```

Bản chất chỉ có 3 thứ: **bật**, **hostname công khai**, **đích nội bộ**. Hết.

## Checklist triển khai app mới (đúng thứ tự)

1. **DockFlare đã chạy và đã được cấu hình** (Operational Mode). Nếu chưa: seed headless
   (xem `scripts/seed-dockflare.py`) hoặc chạy wizard 1 lần. Env `CF_API_TOKEN` **không**
   đủ — phải có file config mã hóa trong volume `/app/data`.
2. **Network chung tồn tại**: `docker network create cloudflare-net` (external).
3. **Domain nằm trong zone Cloudflare** của account đó (NS trỏ về Cloudflare). DockFlare tự
   tra zone từ hostname; không cần tạo DNS tay.
4. **Token đủ quyền account + zone**: Tunnel (Cloudflare One Connector) Write, DNS Write,
   Zone Read, Account Settings Read. Thiếu quyền account -> tạo tunnel 403 (xem bài học #4 README).
5. **Đặt 3 label + `networks: [cloudflare-net]`** lên container app.
6. `docker compose up -d` -> DockFlare tự tạo CNAME + ingress trong ~1-2 phút.

## Nhiều phiên bản / nhiều app song song

Mỗi container = 1 hostname riêng, chỉ cần `dockflare.hostname` khác nhau. Cùng 1 DockFlare
quản lý thoải mái nhiều service/nhiều domain. Đó là cách repo này chạy `latest` +
`v3-8-45` cùng lúc (xem `scripts/render.mjs`).

## Path-based routing / nhiều route cho cùng host

Dùng label đánh số: `dockflare.0.hostname`, `dockflare.0.path=/api`, `dockflare.0.service=...`,
rồi `dockflare.1.*`… Hữu ích khi muốn `/` và `/api` trỏ về 2 service khác nhau.

## Bảo vệ bằng Access (Zero Trust) — tùy chọn

- Public (ai cũng vào): không cần label Access, hoặc dùng nhóm bypass.
- Yêu cầu đăng nhập: `dockflare.access.policy=authenticate` + `dockflare.access.email=you@x.com,@x.com`,
  hoặc gán `dockflare.access.group=<ten-nhom>`.
- Lưu ý: Access cần **Zero Trust đã bật** trên account. Chưa bật thì log báo
  `access.api.error.not_enabled` — vô hại ở chế độ public, nhưng bắt buộc nếu muốn dùng Access.

## App không chạy HTTP thuần?

- HTTPS origin (self-signed): `dockflare.service=https://myapp:8443` và nếu cần
  `dockflare.no_tls_verify=true`.
- App bắt buộc biết public URL (nhiều SPA/Next.js): set biến môi trường base-URL của
  chính app (ví dụ OmniRoute dùng `NEXT_PUBLIC_BASE_URL=https://myapp.example.com`).

## BẪY thường gặp (trả giá bằng thời gian debug)

| Bẫy | Hậu quả | Tránh bằng cách |
| --- | --- | --- |
| Quên `networks: [cloudflare-net]` | DockFlare không thấy container / connector không tới được app | Luôn gắn network chung |
| `dockflare.service` dùng cổng đã publish ra host | Sai đích, phụ thuộc host | Dùng `http://<ten-service>:<cổng-nội-bộ>` |
| DockFlare chưa Operational (mới set env) | Không bao giờ tạo tunnel/DNS | Seed config mã hóa, xác minh section 2 của `diagnose.sh` |
| Token thiếu quyền account | Tạo tunnel 403 code 10000 | Cấp đủ group account+zone (xem `cf-bootstrap.mjs`) |
| Healthcheck app báo unhealthy nhưng app vẫn chạy | Pipeline chờ vô ích / tưởng hỏng | Chấp nhận "serving HTTP" thay vì chỉ trạng thái Docker health |
| `docker stop` app SQLite đột ngột | Hỏng dữ liệu | Đặt `stop_grace_period` đủ dài (OmniRoute 40s) |

## Debug nhanh khi hostname không lên

Dùng `scripts/diagnose.sh` (9 mục). Thứ tự soi: log DockFlare (mục 4) -> connector
cloudflared (mục 6) -> DNS live (mục 8) -> health app (mục 7). Câu hỏi theo thứ tự:
1. DockFlare có tạo được tunnel không? (không -> quyền token / creds)
2. Connector cloudflared chạy chưa? (không -> tunnel chưa tạo)
3. CNAME xuất hiện chưa? (Status:3 = chưa; Status:0 = rồi)
4. App trả HTTP trên cổng nội bộ chưa? (502 qua tunnel = app chưa sẵn sàng)
