# n8n en Google Cloud (Compute Engine)

Producción del MVP: n8n + Postgres en una VM, con Caddy delante para HTTPS automático.
Supabase y Lovable ya son servicios en la nube; esto reemplaza el n8n local y su túnel temporal.

| Pieza | Valor |
|---|---|
| Proyecto / zona | `hire-4u` / `us-west1-b` (Oregon, junto a Supabase us-west-2) |
| VM | `h4u-n8n`, e2-small, Debian 12, 20 GB, swap 2 GB |
| IP fija | `h4u-n8n-ip` → URL `https://<ip-con-guiones>.sslip.io` (sin dominio propio) |
| Público | solo `/webhook/*` (Caddyfile). Editor y API de n8n → 404 desde internet |
| Firewall | `h4u-web`: 80 y 443 (80 solo redirige a HTTPS y sirve el reto de Let's Encrypt) |

## Crear la infraestructura (Cloud Shell)
```bash
gcloud config set project hire-4u
gcloud services enable compute.googleapis.com
gcloud compute addresses create h4u-n8n-ip --region=us-west1
IP=$(gcloud compute addresses describe h4u-n8n-ip --region=us-west1 --format='value(address)')
gcloud compute firewall-rules create h4u-web --network=default \
  --allow=tcp:80,tcp:443 --target-tags=h4u-web
gcloud compute instances create h4u-n8n --zone=us-west1-b --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=20GB \
  --address="$IP" --tags=h4u-web \
  --metadata=startup-script='#!/bin/bash
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi'
```

## Migrar n8n sin volver a capturar credenciales
El paquete lleva el `.env` de la VM (sin `SUPABASE_DB_URL`), los workflows y un `pg_dump`
de la base de n8n. Con el **mismo** `N8N_ENCRYPTION_KEY`, las credenciales siguen funcionando.
El paquete es sensible (lleva esa llave): se borra con `shred` en cada lugar por donde pasa.

```bash
# 1. Local: armar el paquete
./scripts/empaquetar_n8n.sh <ip-con-guiones>.sslip.io
# 2. Cloud Shell: subirlo (⋮ → Subir) y luego
gcloud compute scp ~/h4u_n8n_gcp.tgz h4u-n8n:~ --zone=us-west1-b && shred -u ~/h4u_n8n_gcp.tgz
gcloud compute ssh h4u-n8n --zone=us-west1-b --command='set -e; mkdir -p ~/h4u &&
  tar -xzf ~/h4u_n8n_gcp.tgz -C ~/h4u && shred -u ~/h4u_n8n_gcp.tgz && chmod 600 ~/h4u/.env &&
  cd ~/h4u && sudo ./deploy/gcp/instalar.sh'
# 3. Local: apuntar Supabase (Vault + app_config) a la URL fija
./scripts/actualizar_tunel.sh --url https://<ip-con-guiones>.sslip.io
```

## Operación
```bash
# Entrar al editor de n8n (no está expuesto): túnel SSH y abrir http://localhost:5678
gcloud compute ssh h4u-n8n --zone=us-west1-b -- -L 5678:localhost:5678

# Logs / estado (dentro de la VM)
cd ~/h4u && sudo docker compose -f docker-compose.yml -f docker-compose.gcp.yml ps
sudo docker compose -f docker-compose.yml -f docker-compose.gcp.yml logs -f n8n

# Verificación de punta a punta (local)
./scripts/prueba_e2e.sh

# Apagar para no pagar cómputo (la IP fija y el disco siguen cobrando poco)
gcloud compute instances stop h4u-n8n --zone=us-west1-b
```
Los contenedores tienen `restart: unless-stopped` y Docker arranca con la VM: un reinicio no
requiere intervención. Costo aproximado: e2-small + IP ≈ USD 17/mes.

## Pendiente para producción real
- Respaldos automáticos de la base de n8n (snapshot programado del disco o `pg_dump` a Cloud Storage).
- Monitoreo y alertas (uptime check sobre `/webhook/...`, uso de disco).
- Dominio propio en lugar de sslip.io.
