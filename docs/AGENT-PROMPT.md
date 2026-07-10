# PROMPT mau cho agent: trien khai 1 app qua DockFlare + Cloudflare Tunnel

> Copy nguyen khoi duoi day, dien phan `<...>`, dua cho agent. Phan "BAY" da goi
> san cac loi that da gap de agent khong dam lai.

---

## PROMPT

```
Ban la agent trien khai. Muc tieu: expose app "<TEN_APP>" ra Internet qua Cloudflare
Tunnel, dung DockFlare lam control plane, trien khai vao repo <OWNER/REPO>.

YEU CAU:
- It code nhat, chu yeu cau hinh; tan dung image/opensource co san.
- Toan bo thong tin nhay cam nam trong 1 GitHub Secret JSON duy nhat: DEPLOY_CONFIG_JSON.
- Truy cap theo hostname: <sub>.<DOMAIN> (nhieu ban/phien ban thi moi cai 1 sub).
- THEO DOI DEN KHI TRUY CAP DUOC TU BEN NGOAI moi dung.

THONG TIN APP:
- Cach chay: <image Docker co san | build tu source | npm/node>. Chi tiet: <...>
- Port app listen (NOI BO): <vi du 8080>
- Bien moi truong can thiet: <PORT=..., BASE_URL=..., ...>
- Volume du lieu (neu co): <duong dan trong container>

CLOUDFLARE (dua vao DEPLOY_CONFIG_JSON, tu suy ra cai con lai):
- email + globalApiKey + domain. Account ID / Zone ID / scoped token deu TU SUY RA.

QUY TRINH BAT BUOC:
1. Doc README + docs/APP-EXAMPLES.md + docs/DOCKFLARE-FOR-ANY-APP.md truoc khi sua code.
2. Gan container app: networks:[cloudflare-net] + 3 label (enable/hostname/service).
3. Dam bao dockflare.service tro toi <ten-service>:<port-NOI-BO>, KHONG phai port publish.
4. Deploy, roi probe https://<sub>.<DOMAIN> tu ngoai cho toi khi 2xx/3xx.
5. Neu ket: chay scripts/diagnose.sh, soi theo thu tu section 4 -> 6 -> 8 -> 7.

BAO CAO: URL cong khai, trang thai tung buoc, va xac nhan da truy cap duoc tu ngoai.
```

---

## BAY HAY GAP - agent PHAI tranh (tung lam chet deploy that)

1. **Runner hosted la ephemeral.** GitHub/Azure hosted runner bi xoa khi job xong ->
   tunnel chet theo. Muon ben: dung `server` (SSH toi host that) hoac self-hosted runner.
   `keepalive.yml` chi de test.
2. **Env khong du de cau hinh DockFlare.** Dat `CF_API_TOKEN` chi dien san wizard. Phai
   **seed file config ma hoa** (`scripts/seed-dockflare.py`, chay BANG image DockFlare).
   Kiem: `diagnose.sh` section 2 phai thay `dockflare_config.dat`.
3. **`set -e` + `read` thieu newline.** `node -e` dung `console.log` (co newline), dung dung
   `process.stdout.write`; them `|| true` sau `read`. Khong thi script chet ngay dong dau.
4. **Token thieu quyen account.** Dung match permission-group theo TEN (Cloudflare da
   doi ten). Phan loai theo `scopes` va cap toan bo group account + zone; verify token
   list duoc tunnel truoc khi chay tiep. Sai -> tao tunnel 403 code 10000, DNS khong len.
5. **`dockflare.service` dung sai port.** Phai la port app listen NOI BO, khop voi env
   `PORT`. Khong dung `localhost`, khong dung port publish ra host.
6. **Quen network chung.** Container app va DockFlare phai cung `cloudflare-net` (external).
   Thieu -> DockFlare khong thay / connector khong toi duoc app.
7. **Domain chua nam trong Cloudflare.** NS phai tro ve Cloudflare thi moi tao CNAME duoc.
8. **Tin mu vao Docker healthcheck.** Nhieu app (vi du OmniRoute) bao `unhealthy`
   false-negative du van serve. Dung chan pipeline chi vi health; chap nhan "dang serve HTTP".
9. **`docker stop` dot ngot app dung SQLite.** Dat `stop_grace_period` du dai de tranh hong DB.
10. **Pull cham.** Login Docker Hub (khoi `dockerhub`), pull song song, cache image giua cac run.

## Tieu chi "xong" (Definition of Done)

- `https://<sub>.<DOMAIN>` tra 2xx/3xx tu Internet (khong phai 502/NXDOMAIN).
- `diagnose.sh`: section 6 co connector cloudflared, section 8 DNS Status:0, section 7 app serve.
- Neu nhieu ban: moi hostname len doc lap.
- Da ghi URL + admin login (neu co) vao bao cao cuoi.
