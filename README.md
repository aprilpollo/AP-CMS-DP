# AP-CMS-DP

Deployment สำหรับ AP CMS — Helm chart (`k8s/`) + สคริปต์ช่วยสั่งงาน (`k8s.sh`)

## Components

| Component | Deployment | Service | Port |
|---|---|---|---|
| API | `<release>-api` | `<release>-api-service` | 3000 |
| Mail | `<release>-mail` | `<release>-mail-service` | 8081 |
| Redis | `<release>-redis` | `<release>-redis-service` | 6379 |
| PostgreSQL | `<release>-postgres` | `<release>-postgres-service` | 5432 |

`<release>` ค่า default คือ `apcms-uat` (มาจาก `apcms-<DEPLOY_ENV>`)

## Configuration

| ตัวแปร | Default | หมายเหตุ |
|---|---|---|
| `DEPLOY_ENV` | `uat` | เลือกไฟล์ values และเป็น suffix ของ release |
| `VALUES_FILE` | `k8s/values/<DEPLOY_ENV>.yaml` | |
| `NAMESPACE` | อ่านจาก `namespace:` ใน values file | **อย่า hardcode สวนกับ values** |
| `RELEASE` | `apcms-<DEPLOY_ENV>` | |
| `ENV_FILE` | `.env` | ต้นทางของ ConfigMap |

`NAMESPACE` ถูกอ่านจาก values file โดยตั้งใจ เพราะทุก template ตั้ง `metadata.namespace`
จาก `.Values.namespace` ถ้า kubectl กับ helm ใช้คนละ namespace ConfigMap จะไปอยู่คนละที่
กับ Deployment แล้ว pod จะค้างที่ `CreateContainerConfigError`

## Deploy

```bash
export KUBECONFIG=tai.yaml

./k8s.sh create-np          # สร้าง namespace

POSTGRES_USER=apcms POSTGRES_PASSWORD=xxx POSTGRES_DB=apcms \
  ./k8s.sh create-secret    # Secret ของ Postgres

./k8s.sh create-cf          # ConfigMap: apcms-env + apcms-dotenv จาก .env

./k8s.sh deploy             # helm upgrade --install
```

`./k8s.sh help` ดูคำสั่งทั้งหมด (logs / restart / port-forward / shell / backup)

### ConfigMap สองตัวทำไม

- `apcms-env` — สร้างจาก `--from-env-file` ทุก service ใช้ผ่าน `envFrom`
- `apcms-dotenv` — ไฟล์ `.env` ดิบ ๆ mount เข้า `/app/.env` เฉพาะ mail
  เพราะ mail (Go/godotenv) เปิดไฟล์ `.env` จาก working dir ไม่ได้อ่าน OS env

ทั้งสองตัวสร้างแบบ imperative จาก `k8s.sh` **ไม่ได้อยู่ใน Helm chart** ดังนั้นต้องรัน
`create-cf` ก่อน `deploy` เสมอ และต้องรันซ้ำทุกครั้งที่แก้ `.env`
(ตามด้วย `restart-all` เพราะ `envFrom` ไม่ reload เอง)

## Ingress

ปิดไว้เป็น default ต้องตั้ง `ingress.className` ให้ตรงกับ controller ในคลัสเตอร์ก่อน:

```yaml
ingress:
  enabled: true
  className: nginx        # หรือ gce ตามคลัสเตอร์
  tls:
    enabled: true
    secretName: apcms-uat-tls
```

## ข้อควรระวัง

- **PostgreSQL ใช้ `strategy: Recreate`** — PVC เป็น ReadWriteOnce ถ้าใช้ RollingUpdate
  pod ใหม่จะติด Multi-Attach error แล้ว rollout ค้าง ตอน deploy จะมี downtime สั้น ๆ
- **PVC มี `helm.sh/resource-policy: keep`** — `helm uninstall` / `delete-all` จะไม่ลบข้อมูล
  ถ้าต้องการลบจริงใช้ `./k8s.sh delete-pvcs`
- **`.env` และ `tai.yaml` อยู่ใน `.gitignore`** — อย่า commit
- **ค่า secret ยังอยู่ใน ConfigMap `apcms-env`** (`JWT_SECRET_KEY`, `EMAIL_PASSWORD`,
  `POSTGRES_PASSWORD`) ใครมีสิทธิ์ `get configmaps` ในนamespace อ่านได้หมด
  ควรแยกไปเป็น Secret — Postgres รองรับแล้วผ่าน `apcms-postgres-secret`
- **`ALLOWED_CREDENTIAL_ORIGINS=*`** — ควรเปลี่ยนเป็น origin ของ frontend จริง
