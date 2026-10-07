# WhatsApp Cloud API (app de Meta "H4U INCIDENCIAS")

## Configuración (modo desarrollo, sin verificación de negocio)
1. developers.facebook.com → la app → **WhatsApp → Configuración de la API**.
2. Copiar el **Phone number ID** del número de prueba → `WHATSAPP_PHONE_NUMBER_ID` en `.env`.
3. En "Para", agregar y verificar los números que recibirán avisos (**máximo 5** en modo
   desarrollo): el del operador (`H4U_OPERATOR_PHONE`) y los de los responsables del demo.
4. Token:
   - El **token temporal** dura ~24 h. Sirve para grabar el video.
   - Para algo estable: Business Settings → Usuarios del sistema → generar token con permisos
     `whatsapp_business_messaging` y `whatsapp_business_management`.
   - Se guarda **solo** en la credencial de n8n "H4U · Token WhatsApp Cloud API" como `Bearer <token>`.

## Modos de mensaje (`WHATSAPP_MESSAGE_MODE`)

| Modo | Cuándo funciona | Qué se ve |
|---|---|---|
| `template` + `hello_world` | Siempre (viene aprobada) | Mensaje genérico de Meta, sin datos de la incidencia |
| `template` + `aviso_incidencia` | Cuando Meta apruebe la plantilla | El aviso completo |
| `text` | Solo si el destinatario escribió al número de prueba en las últimas 24 h | El aviso completo, sin esperar aprobación |

**Para el demo:** desde cada teléfono del demo, mandar "hola" al número de prueba, y usar
`WHATSAPP_MESSAGE_MODE=text`. En paralelo, enviar a revisión la plantilla de abajo.

## Plantilla `aviso_incidencia`
WhatsApp Manager → Plantillas → Crear → categoría **Utilidad**, idioma **Español (MEX)** (`es_MX`).

Cuerpo (6 variables, en este orden; las arma el nodo "Armar mensaje"):
```
Aviso H4U: {{1}}
Folio: {{2}}
Propiedad: {{3}} · {{4}}
Prioridad: {{5}}
Detalle: {{6}}
Por favor confirma al operador que recibiste este aviso.
```
Ejemplos para la revisión: `Nueva incidencia asignada`, `INC-0001`, `Casa Coral`, `Unidad 3`,
`alta`, `No sale agua caliente`.

Ya aprobada: `WHATSAPP_MESSAGE_MODE=template`, `WHATSAPP_TEMPLATE_NAME=aviso_incidencia`,
`WHATSAPP_TEMPLATE_LANG=es_MX`, y `docker compose up -d n8n`.

## Errores frecuentes
| Error de Meta | Causa |
|---|---|
| `(#131030) Recipient phone number not in allowed list` | El número no está verificado en el número de prueba |
| `(#131047) Re-engagement message` | Modo `text` y pasaron más de 24 h desde el último mensaje del destinatario |
| `(#132001) Template name does not exist in the translation` | Nombre o idioma de plantilla incorrectos, o aún no aprobada |
| `401` / `(#190)` | Token vencido |

El error queda en `notification_outbox.last_error` y el aviso se reintenta (hasta 5 veces, una
por minuto) antes de quedar en `failed`.
