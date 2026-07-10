# Port, label & CNAME: hướng dẫn chi tiết + ví dụ nhiều kiểu app

> Mục tiêu: bạn có thể thay OmniRoute bằng BẤT KỲ app nào (image Docker có sẵn,
> build từ source, hay chạy bằng npm/node) và DockFlare vẫn tự tạo CNAME + tunnel.

---

## 1. Port hoạt động ra sao (đọc kỹ phần này)

Có **hai loại port**, đừng nhầm:

| Loại | Là gì | Có cần cho DockFlare không |
| --- | --- | --- |
| **Port nội bộ (container)** | Cổng app listen bên trong container, ví dụ `20128` | **CÓ.** DockFlare đấu thẳng vào đây qua mạng Docker. |
| **Port publish ra host** (`ports:` trong compose) | Ánh xạ `hostPort:containerPort` ra máy chủ | **KHÔNG.** Với tunnel bạn **không cần** publish. Bỏ `ports:` đi cho kín. |

**Nguyên tắc vàng:** `dockflare.service` trỏ tới **tên container/service + PORT NỘI BỘ**, không phải port publish, không phải `localhost`.

```
dockflare.service = http://<tên-service-trong-compose>:<port-app-listen>
```

### Nhiều app / nhiều bản có trùng port không?

**Không sao nếu mỗi app là một container riêng.** Ví dụ cả `omniroute-latest` và
`omniroute-v3-8-45` cùng listen `20128` — không đụng nhau vì mỗi container có không gian
mạng riêng, DockFlare phân biệt bằng **hostname** chứ không bằng port:

```
latest.example.com   -> http://omniroute-latest:20128
v3-8-45.example.com  -> http://omniroute-v3-8-45:20128
```

Port **chỉ** đụng nhau khi bạn **publish ra host** (`ports: 20128:20128` hai lần) — mà ta
không làm điều đó. Nếu bắt buộc publish (debug), mỗi container chọn hostPort khác nhau:
`20128:20128` và `20129:20128`.

### App đổi port mặc định thế nào

Hầu hết app cho đổi qua env (`PORT`, `APP_PORT`, `HTTP_PORT`…). Đổi thì phải đổi
**đồng bộ cả hai chỗ**: env của app **và** số port trong `dockflare.service`.

```yaml
environment:
  - PORT=8080
labels:
  - dockflare.service=http://myapp:8080   # phải khớp với PORT trên
```

---

## 2. Các label DockFlare để tạo CNAME + route

| Label | Bắt buộc | Tác dụng |
| --- | --- | --- |
| `dockflare.enable=true` | ✅ | Bật DockFlare cho container này. Thiếu = bỏ qua. |
| `dockflare.hostname=sub.example.com` | ✅ | Hostname công khai. DockFlare tạo **CNAME** `sub` -> tunnel, trong zone chứa `example.com`. |
| `dockflare.service=http://myapp:PORT` | ✅ | Đích nội bộ tunnel đẩy traffic tới. `http` hoặc `https`. |
| `dockflare.zonename=example.com` | — | Ép zone cụ thể khi hostname nằm ở domain khác với zone mặc định. |
| `dockflare.no_tls_verify=true` | — | Bỏ verify TLS khi origin là HTTPS self-signed. |
| `dockflare.access.policy=authenticate` | — | Bắt đăng nhập qua Cloudflare Access. |
| `dockflare.access.email=you@x.com,@x.com` | — | Danh sách email / domain được phép (dùng với policy trên). |
| `dockflare.access.group=<ten-nhom>` | — | Gán Access Group có sẵn thay vì khai email từng cái. |

### CNAME được tạo thế nào

DockFlare lấy `dockflare.hostname`, tìm zone Cloudflare bao phủ hostname đó (khớp
đuôi dài nhất), rồi tạo bản ghi **CNAME proxied** trỏ về `<tunnel-id>.cfargotunnel.com`.
Bạn **không** tạo DNS tay. Domain phải đã nằm trong Cloudflare (NS trỏ về Cloudflare).

### Nhiều route cho cùng 1 container (path-based)

Dùng tiền tố đánh số `dockflare.<n>.*`:

```yaml
labels:
  - dockflare.enable=true
  - dockflare.0.hostname=app.example.com
  - dockflare.0.path=/
  - dockflare.0.service=http://myapp:3000
  - dockflare.1.hostname=app.example.com
  - dockflare.1.path=/api
  - dockflare.1.service=http://myapi:8000
```

---

## 3. Ví dụ: thay OmniRoute bằng app khác

Tất cả đều gắn `networks: [cloudflare-net]` (external) và 3 label. Khác biệt duy nhất
là cách app “tồn tại”: image có sẵn, build từ source, hay chạy npm.

### 3A. Image Docker có sẵn (dễ nhất)

Ví dụ n8n (listen `5678`):

```yaml
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - N8N_PORT=5678
      - N8N_HOST=n8n.example.com
      - WEBHOOK_URL=https://n8n.example.com/
    volumes:
      - n8n-data:/home/node/.n8n
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=n8n.example.com
      - dockflare.service=http://n8n:5678

volumes:
  n8n-data:
networks:
  cloudflare-net:
    name: cloudflare-net
    external: true
```

Grafana chỉ khác port (`3000`): `image: grafana/grafana`, `dockflare.service=http://grafana:3000`.

### 3B. Build từ source (có Dockerfile trong repo app)

Khi app không có image publish, hoặc bạn muốn build riêng:

```yaml
services:
  myapp:
    build:
      context: ./myapp        # thư mục chứa Dockerfile
      # target: runner         # nếu Dockerfile multi-stage
    image: myapp:local          # đặt tên để cache lại
    restart: unless-stopped
    environment:
      - PORT=8080               # app tự đọc biến này để listen
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=myapp.example.com
      - dockflare.service=http://myapp:8080

networks:
  cloudflare-net:
    name: cloudflare-net
    external: true
```

Lưu ý: DockFlare chỉ cần container **chạy + đúng network + đúng label**; nó không quan
tâm image đến từ `pull` hay `build`. Trong CI, `docker compose build` rồi `up -d`.

### 3C. App chạy bằng npm / Node (không có Dockerfile)

Hai hướng:

**(i) Bọc nhanh bằng image node + cài lúc chạy** (ít code, hợp triết lý repo):

```yaml
services:
  mynode:
    image: node:24-alpine
    working_dir: /app
    command: sh -c "npm i -g some-app && some-app --port 3000"
    environment:
      - PORT=3000
    networks: [cloudflare-net]
    labels:
      - dockflare.enable=true
      - dockflare.hostname=mynode.example.com
      - dockflare.service=http://mynode:3000

networks:
  cloudflare-net:
    name: cloudflare-net
    external: true
```

**(ii) App Node có source, muốn cài deps 1 lần** — viết Dockerfile tối thiểu rồi dùng 3B:

```dockerfile
FROM node:24-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.js"]
```

> Cách (i) đơn giản nhưng cài lại mỗi lần khởi động; cách (ii) build 1 lần, chạy
> nhanh và ổn định hơn cho production.

### 3D. App không phải HTTP (TCP/SSH…)

Cloudflare Tunnel ingress của DockFlare tập trung HTTP/HTTPS. Dịch vụ TCP thuần
(Postgres, SSH) cần cấu hình tunnel kiểu khác (`cloudflared access`), nằm ngoài phạm
vi tự-động-hóa của repo này. Để web UI của chúng thì vẫn dùng được bình thường.

---

## 4. Đưa app vào repo này (tự động qua config)

Repo hiện sinh compose từ `omniroute.versions`. Để tổng quát cho app khác, cách nhanh
nhất là thêm một file `docker-compose.<app>.yml` tự viết (theo mẫu 3A/3B/3C) và nối
nó vào `COMPOSE_FILES` trong `.deploy-plan`. Giữ nguyên DockFlare control plane
(`docker-compose.dockflare.yml`). Miễn container có 3 label + đúng network là xong.
