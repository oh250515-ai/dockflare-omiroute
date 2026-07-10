# Kinh nghiệm: dùng DockFlare để expose BẤT KỲ app nào

> Rút ra từ lần triển khai OmniRoute. Áp dụng cho mọi app (n8n, Grafana, Nextcloud,
> API nội bộ…) muốn đưa ra Internet qua Cloudflare Tunnel mà không mở cổng,
> không cấu hình dashboard Cloudflare bằng tay.

## Mô hình cốt lõi (nhớ 1 câu)

**DockFlare = control plane. App chỉ cần 3 label + chung 1 network.**
DockFlare theo dõi Docker, thấy label thì tự tạo **DNS (CNAME) + tunnel ingress + (tùy chọn) Access**.

```
[ Internet ] --HTTPS--> [ Cloudflare edge ] --tunnel--> [ cloudflared ] --http--> [ container app:port ]
         CNAME <slug>.<domain>                                            cùng network cloudflare-net
```

DockFlare tạo CNAME + ingress từ label, bạn không đụng tay vào dashboard.

---

## 1. PORT — hiểu cho đúng (phần hay nhầm nhất)

**Chỉ có DUY NHẤT một con số port cần quan tâm: cổng NỘI BỘ mà app lắng nghe bên trong container.**

- Đó là con số đặt trong `dockflare.service=http://<ten-container>:<port-noi-bo>`.
- **KHÔNG** cần `ports:` (publish ra host) trong public mode. Tunnel đi outbound từ
  cloudflared tới container qua network nội bộ, không qua cổng host.
- Nhiều app **cùng dùng port nội bộ giống nhau vẫn OK**, miễn là **khác tên container**.
  Ví dụ repo này chạy `omniroute-latest:20128` và `omniroute-v3-8-45:20128` song song:
  cùng 20128 nhưng là 2 container riêng, DockFlare định tuyến theo hostname nên không đụng nhau.

**Cái gây xung đột thật sự:**

| Thứ | Có xung đột khi trùng? | Ghi chú |
| --- | --- | --- |
| Port nội bộ (trong container) | **Không** | Mỗi container có network namespace riêng |
| Tên container (`container_name`) | **Có** | Phải duy nhất trên 1 host |
| Port publish ra host (`ports: "X:Y"`) | **Có** nếu trùng X | Tránh publish trong public mode |
| Hostname (`dockflare.hostname`) | **Có** | Mỗi CNAME phải duy nhất |

**Biết port nội bộ của app bằng cách nào?**
- Xem README/Dockerfile của app: dòng `EXPOSE`, hoặc biến `PORT`.
- OmniRoute: 20128. n8n: 5678. Grafana: 3000. Nextcloud: 80. code-server: 8080. Uptime Kuma: 3001.
- Nếu app cho đổi port qua env (ví dụ `PORT=...`), đặt env đó và khớp với số trong `dockflare.service`.

---

## 2. LABEL — tên label, cách tạo CNAME

### 3 label tối thiểu

```yaml
labels:
  - dockflare.enable=true                    # bật DockFlare cho container này
  - dockflare.hostname=app.example.com       # => tạo CNAME 'app' trong zone example.com
  - dockflare.service=http://myapp:8080      # đích nội bộ: http://<ten-container>:<port-noi-bo>
```

### CNAME được tạo như thế nào

- `dockflare.hostname=app.example.com` -> DockFlare tra zone chứa `example.com`, tạo **CNAME**
  `app` trỏ tới `<tunnel-id>.cfargotunnel.com` (proxied). Không cần tạo DNS tay.
- Domain (hoặc domain cha) **phải đã nằm trong Cloudflare** (NS trỏ về Cloudflare).
- Subdomain nhiều cấp cũng được: `v1.api.example.com` -> CNAME `v1.api`.
- Repo này sinh hostname theo version qua `slug()` trong `scripts/render.mjs`:
  `latest` -> `latest.<domain>`, `3.8.45` -> `v3-8-45.<domain>` (thay ký tự lạ bằng `-`, thêm tiền tố `v`).

### Bảng label hay dùng

| Label | Tác dụng | Ví dụ |
| --- | --- | --- |
| `dockflare.enable` | Bật quản lý | `true` |
| `dockflare.hostname` | Hostname công khai -> CNAME | `app.example.com` |
| `dockflare.service` | Đích nội bộ | `http://myapp:8080` |
| `dockflare.zonename` | Ép zone nếu khác domain mặc định | `otherdomain.com` |
| `dockflare.no_tls_verify` | Bỏ verify TLS khi origin là https self-signed | `true` |
| `dockflare.access.policy` | Yêu cầu đăng nhập | `authenticate` |
| `dockflare.access.email` | Danh sách email/domain được phép | `you@x.com,@x.com` |
| `dockflare.access.group` | Gán Access Group có sẵn | `nas-family` |

### Nhiều route cho cùng container (path-based, label đánh số)

```yaml
labels:
  - dockflare.enable=true
  # route chính
  - dockflare.hostname=app.example.com
  - dockflare.service=http://myapp:8080
  # route phụ theo path
  - dockflare.0.hostname=app.example.com
  - dockflare.0.path=/api
  - dockflare.0.service=http://myapp-api:9000
```

---

## 3. VÍ DỤ — thay OmniRoute bằng app khác (nhiều kiểu cài)

Tất cả đều chung 3 điều kiện: **container nằm trên `cloudflare-net`**, **có 3 label**,
**`dockflare.service` trỏ đúng port nội bộ**. Khác nhau chỉ ở chỗ lấy image ở đâu.

### 3a. Dùng image Docker có sẵn (đơn giản nhất — giống OmniRoute)

```yaml
# docker-compose.yml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_PORT=5678
      - WEBHOOK_URL=https://n8n.example.com/    # app cần biết URL công khai
    volumes:
      - n8n-data:/home/node/.n8n
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=n8n.example.com
      - dockflare.service=http://n8n:5678         # 5678 = port nội bộ của n8n
volumes:
  n8n-data:
networks:
  cloudflare-net:
    name: cloudflare-net
    external: true
```

### 3b. Build trực tiếp từ source (repo có Dockerfile)

```yaml
services:
  myapp:
    build:
      context: ./myapp          # thư mục chứa Dockerfile (clone sẵn hoặc submodule)
      # target: runner          # nếu Dockerfile nhiều stage
    container_name: myapp
    restart: unless-stopped
    environment:
      - PORT=8080
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=myapp.example.com
      - dockflare.service=http://myapp:8080
networks:
  cloudflare-net: { name: cloudflare-net, external: true }
```

Lưu ý: build tốn thời gian + RAM trên host/runner. Ưu tiên image dựng sẵn nếu có.

### 3c. App cài bằng npm / Node (không có image chính thức)

Dùng image `node` chung rồi `npm i -g` app lúc khởi động — không cần viết Dockerfile:

```yaml
services:
  mynode:
    image: node:22-alpine
    container_name: mynode
    restart: unless-stopped
    working_dir: /app
    command: sh -c "npm i -g some-cli@latest && some-cli serve --port 3000 --host 0.0.0.0"
    environment:
      - PORT=3000
    volumes:
      - mynode-data:/app
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=mynode.example.com
      - dockflare.service=http://mynode:3000
volumes:
  mynode-data:
networks:
  cloudflare-net: { name: cloudflare-net, external: true }
```

Bẫy: app **phải bind 0.0.0.0**, không phải `127.0.0.1` — nếu chỉ nghe loopback,
cloudflared ở container khác sẽ không tới được.

### 3d. App/VM ngoài Docker (manual rule)

App chạy trực tiếp trên máy (systemd, VM khác…): không gắn label được thì vào **UI DockFlare
-> Manual Rules**, khai hostname + service URL (ví dụ `http://192.168.1.50:8096`). DockFlare
vẫn tạo CNAME + ingress như với container.

---

## 4. Checklist triển khai app mới (đúng thứ tự)

1. DockFlare đã **Operational** (có file config mã hóa trong volume, không phải chỉ set env).
2. `docker network create cloudflare-net` (external) đã tồn tại.
3. Domain nằm trong zone Cloudflare của account.
4. Token đủ quyền **account + zone** (Tunnel Write, DNS Write, Zone Read, Account Settings Read).
5. Container app: `networks: [cloudflare-net]` + 3 label + `dockflare.service` trỏ đúng port nội bộ.
6. App bind trên `0.0.0.0`, không publish port ra host.
7. `docker compose up -d` -> chờ ~1-2 phút -> kiểm tra CNAME + mở URL.

---

## 5. BẪY thường gặp

| Bẫy | Hậu quả | Tránh bằng cách |
| --- | --- | --- |
| Quên `networks: [cloudflare-net]` | DockFlare không thấy / connector không tới app | Luôn gắn network chung |
| App nghe `127.0.0.1` thay vì `0.0.0.0` | Tunnel trả 502 | Bắt app bind 0.0.0.0 / `HOST=0.0.0.0` |
| `dockflare.service` dùng port đã publish ra host | Sai đích | Dùng port NỘI BỘ + tên container |
| Trùng `container_name` | Compose lỗi / ghi đè | Mỗi app 1 tên duy nhất |
| Trùng `dockflare.hostname` | 2 app tranh 1 CNAME | Mỗi app 1 hostname |
| DockFlare chưa Operational (mới set env) | Không tạo tunnel/DNS | Seed config mã hóa (xem README lỗi #2) |
| Token thiếu quyền account | Tunnel 403 code 10000 | Cấp group account+zone (README lỗi #4) |
| Healthcheck báo unhealthy nhưng app chạy | Chờ vô ích | Chấp nhận "serving HTTP" (README lỗi #7) |
| App SQLite bị `docker stop` đột ngột | Hỏng dữ liệu | Đặt `stop_grace_period` đủ dài |

---

## 6. PROMPT MẪU cho AI agent triển khai app mới

Copy nguyên khối dưới, thay phần `[...]`, giao cho agent:

```
Nhiệm vụ: expose app [TÊN APP] ra Internet qua Cloudflare Tunnel, dùng DockFlare làm
control plane, theo đúng mô hình repo dockflare-omiroute (config-only, ít code nhất).

Input:
- App: [image docker / repo source / cách cài npm]
- Port nội bộ app lắng nghe: [SỐ, xem EXPOSE/PORT của app]
- Hostname mong muốn: [sub.domain.com] (domain đã nằm trong Cloudflare)
- Biến môi trường app cần (nếu có): [ví dụ base URL, API key]

Yêu cầu:
1. Không viết code app. Chỉ viết docker-compose + label. Tận dụng image dựng sẵn nếu có.
2. Container phải: nằm trên network external `cloudflare-net`; có 3 label
   dockflare.enable=true, dockflare.hostname=<hostname>, dockflare.service=http://<ten-container>:<port-noi-bo>.
3. App phải bind 0.0.0.0, KHÔNG publish port ra host (public mode dùng tunnel).
4. Không đặt trùng container_name và không trùng hostname với service khác.
5. Nếu app dùng SQLite/ghi đĩa: mount volume + đặt stop_grace_period hợp lý.

Trước khi báo xong PHẢI tự kiểm (self-check), nêu rõ kết quả từng mục:
- [ ] DockFlare đang Operational (có dockflare_config.dat), KHÔNG chỉ dựa vào CF_API_TOKEN env.
- [ ] Token có quyền account (tạo được tunnel) — xác minh bằng list cfd_tunnel.
- [ ] CNAME <hostname> đã xuất hiện (dns Status:0), không còn NXDOMAIN.
- [ ] cloudflared connector đang chạy.
- [ ] curl https://<hostname> trả 2xx/3xx (không 502).

BẪY PHẢI TRÁNH (đã từng dính, đừng lặp lại):
- Đừng tưởng set CF_API_TOKEN env là DockFlare tự cấu hình — SAI, phải có file config
  mã hóa (seed headless bằng chính image DockFlare, hoặc chạy wizard 1 lần).
- Đừng match Cloudflare permission-group theo TÊN (Cloudflare đã đổi tên) — cấp theo scope.
  Token thiếu quyền account -> tạo tunnel 403 code 10000, DNS không bao giờ lên.
- Đừng chỉ dựa vào Docker healthcheck để kết luận app hỏng — nhiều app báo unhealthy
  giả (false-negative) dù vẫn serve. Kiểm bằng curl HTTP thực tế.
- Đừng bind app vào 127.0.0.1; phải 0.0.0.0, nếu không tunnel 502.
- Đừng publish port ra host trong public mode (thừa + dễ trùng). Tunnel đi nội bộ.
- Đừng quên `networks: [cloudflare-net]` — thiếu là DockFlare không route được.
- Khi shell đọc output từ node bằng `read`: nhớ newline cuối (dùng console.log), tránh
  `set -e` giết script ở dòng đầu.

Khi kẹt, chạy scripts/diagnose.sh và soi theo thứ tự: log DockFlare (tunnel/CF API) ->
connector cloudflared -> DNS live -> health app.
```

---

## 7. Debug nhanh khi hostname không lên

Dùng `scripts/diagnose.sh` (9 mục). Thứ tự soi:
1. **Log DockFlare (mục 4)** — có tạo được tunnel không? 403/code 10000 = thiếu quyền token.
2. **Connector cloudflared (mục 6)** — chưa có = tunnel chưa tạo.
3. **DNS live (mục 8)** — Status:3 = chưa có CNAME; Status:0 = có rồi.
4. **Health app (mục 7)** — 502 qua tunnel = app chưa serve / bind sai / sai port.
