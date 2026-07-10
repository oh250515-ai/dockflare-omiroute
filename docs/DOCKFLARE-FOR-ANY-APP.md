# Kinh nghiem: dung DockFlare de expose BAT KY app nao

> Rut ra tu lan trien khai OmniRoute. Ap dung cho moi app (n8n, Grafana, Nextcloud,
> API noi bo...) muon dua ra Internet qua Cloudflare Tunnel ma khong mo cong,
> khong cau hinh dashboard Cloudflare bang tay.

## Mo hinh cot loi (nho 1 cau)

**DockFlare = control plane. App chi can 3 label + chung 1 network.**
DockFlare theo doi Docker, thay label thi tu tao **DNS (CNAME) + tunnel ingress + (tuy chon) Access**.

```
[ Internet ] --HTTPS--> [ Cloudflare edge ] --tunnel--> [ cloudflared ] --http--> [ container app:port ]
         CNAME <slug>.<domain>                                            cung network cloudflare-net
```

DockFlare tao CNAME + ingress tu label, ban khong dung tay vao dashboard.

> Kien truc repo nay: **compose da commit la nguon su that** (moi app/version 1 service);
> mot buoc nho `scripts/prepare-env.mjs` dich secret -> `.env` truoc khi `compose up`.
> Them/sua version = sua thang file compose, KHONG sinh compose dong.

---

## 1. PORT - hieu cho dung (phan hay nham nhat)

**Chi co DUY NHAT mot con so port can quan tam: cong NOI BO ma app lang nghe ben trong container.**

- Do la con so dat trong `dockflare.service=http://<ten-container>:<port-noi-bo>`.
- **KHONG** can `ports:` (publish ra host) trong public mode. Tunnel di outbound tu
  cloudflared toi container qua network noi bo, khong qua cong host.
- Nhieu app **cung port noi bo van OK**, mien **khac ten container**. Repo nay chay
  `omniroute-latest:20128` va `omniroute-v3-8-45:20128` song song: cung 20128, 2 container
  rieng, DockFlare dinh tuyen theo hostname.

**Cai gay xung dot that su:**

| Thu | Trung co xung dot? | Ghi chu |
| --- | --- | --- |
| Port noi bo (trong container) | **Khong** | Moi container co namespace rieng |
| `container_name` | **Co** | Phai duy nhat tren 1 host |
| Port publish ra host (`ports: "X:Y"`) | **Co** neu trung X | Tranh publish trong public mode |
| `dockflare.hostname` | **Co** | Moi CNAME phai duy nhat |

**Biet port noi bo cua app:** xem `EXPOSE`/`PORT` trong README/Dockerfile. OmniRoute 20128,
n8n 5678, Grafana 3000, Nextcloud 80, code-server 8080, Uptime Kuma 3001.

---

## 2. LABEL - ten label, cach tao CNAME

### 3 label toi thieu

```yaml
labels:
  - dockflare.enable=true                    # bat DockFlare cho container nay
  - dockflare.hostname=app.example.com       # => tao CNAME 'app' trong zone example.com
  - dockflare.service=http://myapp:8080      # dich noi bo: http://<ten-container>:<port-noi-bo>
```

### CNAME duoc tao nhu the nao

- `dockflare.hostname=app.example.com` -> DockFlare tra zone chua `example.com`, tao **CNAME**
  `app` tro toi `<tunnel-id>.cfargotunnel.com` (proxied). Khong can tao DNS tay.
- Domain (hoac domain cha) **phai da nam trong Cloudflare**.
- Trong repo nay hostname lay tu `${BASE_DOMAIN}` (dien san vao `.env` tu `cloudflare.domain`).

### Bang label hay dung

| Label | Tac dung | Vi du |
| --- | --- | --- |
| `dockflare.enable` | Bat quan ly | `true` |
| `dockflare.hostname` | Hostname cong khai -> CNAME | `app.example.com` |
| `dockflare.service` | Dich noi bo | `http://myapp:8080` |
| `dockflare.zonename` | Ep zone neu khac domain mac dinh | `otherdomain.com` |
| `dockflare.no_tls_verify` | Bo verify TLS khi origin https self-signed | `true` |
| `dockflare.access.policy` | Yeu cau dang nhap | `authenticate` |
| `dockflare.access.email` | Email/domain duoc phep | `you@x.com,@x.com` |
| `dockflare.access.group` | Gan Access Group co san | `nas-family` |

### Nhieu route cho cung container (path-based, label danh so)

```yaml
labels:
  - dockflare.enable=true
  - dockflare.hostname=app.example.com
  - dockflare.service=http://myapp:8080
  - dockflare.0.hostname=app.example.com
  - dockflare.0.path=/api
  - dockflare.0.service=http://myapp-api:9000
```

---

## 3. VI DU - thay OmniRoute bang app khac (nhieu kieu cai)

Tat ca chung 3 dieu kien: **container nam tren `cloudflare-net`**, **co 3 label**,
**`dockflare.service` tro dung port noi bo**. Khac nhau chi o cho lay image o dau.

### 3a. Image Docker co san (don gian nhat - giong OmniRoute)

```yaml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_PORT=5678
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
  cloudflare-net: { name: cloudflare-net, external: true }
```

### 3b. Build truc tiep tu source (repo co Dockerfile)

```yaml
services:
  myapp:
    build:
      context: ./myapp
      # target: runner
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

Build ton thoi gian + RAM tren host/runner. Uu tien image dung san neu co.

### 3c. App cai bang npm / Node (khong co image chinh thuc)

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

Bay: app **phai bind 0.0.0.0**, khong phai `127.0.0.1`.

### 3d. App/VM ngoai Docker (manual rule)

Khong gan label duoc thi vao **UI DockFlare -> Manual Rules**, khai hostname + service URL
(vi du `http://192.168.1.50:8096`). DockFlare van tao CNAME + ingress.

---

## 4. Checklist trien khai app moi (dung thu tu)

1. DockFlare da **Operational** (co file config ma hoa trong volume, khong phai chi set env).
2. `docker network create cloudflare-net` (external) da ton tai.
3. Domain nam trong zone Cloudflare cua account.
4. Token du quyen **account + zone** (Tunnel Write, DNS Write, Zone Read, Account Settings Read).
5. Container app: `networks: [cloudflare-net]` + 3 label + `dockflare.service` tro dung port noi bo.
6. App bind `0.0.0.0`, khong publish port ra host.
7. Neu app co phien dang nhap: cap secret ky cookie (vi du `JWT_SECRET`) va co secure-cookie
   khi chay sau HTTPS - neu khong se bi vong lap login (xem bay ben duoi).
8. `docker compose up -d` -> cho ~1-2 phut -> kiem CNAME + mo URL.

---

## 5. BAY thuong gap

| Bay | Hau qua | Tranh bang cach |
| --- | --- | --- |
| Quen `networks: [cloudflare-net]` | DockFlare khong thay / connector khong toi app | Luon gan network chung |
| App nghe `127.0.0.1` thay vi `0.0.0.0` | Tunnel tra 502 | Bat app bind 0.0.0.0 / `HOST=0.0.0.0` |
| `dockflare.service` dung port da publish ra host | Sai dich | Dung port NOI BO + ten container |
| Trung `container_name` | Compose loi / ghi de | Moi app 1 ten duy nhat |
| Trung `dockflare.hostname` | 2 app tranh 1 CNAME | Moi app 1 hostname |
| DockFlare chua Operational (moi set env) | Khong tao tunnel/DNS | Seed config ma hoa (README loi #2) |
| Token thieu quyen account | Tunnel 403 code 10000 | Cap group account+zone theo scope (README loi #4) |
| Healthcheck bao unhealthy nhung app chay | Cho vo ich | Chap nhan "serving HTTP" (README loi #7) |
| App co login nhung thieu secret ky cookie / secure-cookie | Dang nhap xong bi da ve /login | Cap `JWT_SECRET` co dinh + `AUTH_COOKIE_SECURE=true` (README loi #8) |
| App SQLite bi `docker stop` dot ngot | Hong du lieu | Dat `stop_grace_period` du dai |

---

## 6. PROMPT MAU cho AI agent trien khai app moi

Copy nguyen khoi duoi, thay phan `[...]`, giao cho agent:

```
Nhiem vu: expose app [TEN APP] ra Internet qua Cloudflare Tunnel, dung DockFlare lam
control plane, theo dung mo hinh repo dockflare-omiroute (config-only, it code nhat):
compose da commit la nguon su that; mot buoc prepare-env dich secret -> .env; khong sinh compose.

Input:
- App: [image docker / repo source / cach cai npm]
- Port noi bo app lang nghe: [SO, xem EXPOSE/PORT]
- Hostname mong muon: [sub.domain.com] (domain da nam trong Cloudflare)
- Bien moi truong app can (neu co): [base URL, secret ky session, API key...]

Yeu cau:
1. Khong viet code app. Them service vao docker-compose (commit san) + label. Image dung san neu co.
2. Container phai: tren network external `cloudflare-net`; 3 label
   dockflare.enable=true, dockflare.hostname=<hostname>, dockflare.service=http://<ten-container>:<port-noi-bo>.
3. App bind 0.0.0.0, KHONG publish port ra host.
4. Khong trung container_name, khong trung hostname.
5. App co login: cap secret ky cookie co dinh + bat secure-cookie (sau HTTPS).
6. App ghi dia/SQLite: mount volume + stop_grace_period hop ly.

Truoc khi bao xong PHAI self-check, neu ro tung muc:
- [ ] DockFlare Operational (co dockflare_config.dat), KHONG chi dua CF_API_TOKEN env.
- [ ] Token co quyen account (list cfd_tunnel OK).
- [ ] CNAME <hostname> da co (dns Status:0), khong NXDOMAIN.
- [ ] cloudflared connector dang chay.
- [ ] curl https://<hostname> tra 2xx/3xx (khong 502).
- [ ] Neu co login: dang nhap roi click link khong bi da ra.

BAY PHAI TRANH (da tung dinh, dung lap lai):
- Dung tuong set CF_API_TOKEN env la DockFlare tu cau hinh - phai co file config ma hoa
  (seed headless bang chinh image DockFlare, hoac wizard 1 lan).
- Dung match Cloudflare permission-group theo TEN (da bi doi ten) - cap theo scope. Thieu
  quyen account -> tunnel 403 code 10000, DNS khong len.
- Dung chi dua Docker healthcheck de ket luan app hong - nhieu app unhealthy gia. Kiem curl that.
- Dung de app login ma thieu secret ky cookie - se vong lap /login. Sau HTTPS can secure-cookie.
- Dung bind 127.0.0.1; phai 0.0.0.0.
- Dung publish port ra host trong public mode.
- Dung quen `networks: [cloudflare-net]`.
- Shell doc output node bang `read`: nho newline cuoi (console.log), tranh `set -e` giet script.

Khi ket, chay scripts/diagnose.sh va soi: log DockFlare (tunnel/CF API) -> connector
cloudflared -> DNS live -> health app.
```

---

## 7. Debug nhanh khi hostname khong len

Dung `scripts/diagnose.sh` (9 muc). Thu tu soi:
1. **Log DockFlare (muc 4)** - co tao duoc tunnel khong? 403/code 10000 = thieu quyen token.
2. **Connector cloudflared (muc 6)** - chua co = tunnel chua tao.
3. **DNS live (muc 8)** - Status:3 = chua co CNAME; Status:0 = co roi.
4. **Health app (muc 7)** - 502 qua tunnel = app chua serve / bind sai / sai port.

> Buoc dich secret -> env nam o `scripts/prepare-env.mjs` (Cloudflare token/account/zone +
> secret phien cho app). Compose doc cac gia tri nay tu `.env`.
