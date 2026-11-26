# Runner de GitHub Actions en la oficina

Los jobs programados (por ahora el espejo diario de `crm-documents-downloader`) pueden correr en una máquina de la oficina que está prendida 24/7. Así no gastan minutos de GitHub Actions: los minutos en un runner propio no se cobran.

## Cómo funciona

- **Grupo `office`.** Las máquinas se registran en la organización dentro de este grupo, con la etiqueta `office-async`.
- **Quién puede usarlo.** Sólo los repos y workflows que lista el grupo, y sólo desde `main`. El código de un pull request o de otra rama **no** puede correr acá.
- **El switch.** Cada repo decide con una variable de Actions:
  ```yaml
  runs-on: ${{ vars.ASYNC_RUNNER || 'ubuntu-latest' }}
  ```
  - Con `ASYNC_RUNNER = office-async`, el job corre en la oficina.
  - Si se borra la variable, vuelve a los runners de GitHub, sin tocar código.
- **Si la máquina está apagada,** los jobs esperan hasta 24 horas y después fallan, con el aviso de falla de siempre.

## Seguridad

- **Usar una VM de Hyper-V, no WSL.** Desde WSL se pueden leer los discos de Windows (`/mnt/c`). Una VM no ve los archivos del PC.
- **Usuario `ghrunner`.** Corre sin `sudo`, pero está en el grupo `docker`, lo que equivale a root dentro de la VM. Por eso la VM es sólo para esto.
- **Secrets.** Los secrets llegan sólo mientras corre cada job. Los workflows escriben las llaves y las descargas en `$RUNNER_TEMP`, que el runner vacía al terminar cada job. El disco de un runner propio no se borra entre corridas, así que nada sensible debe quedar en el workspace ni en `/tmp`.
- **Red.** Sólo conexiones salientes por HTTPS. No hay que abrir puertos.
- **Un runner por VM.** El espejo levanta Gotenberg en el puerto 3000 de la máquina, así que dos runners en la misma VM chocarían.

## Lo que se necesita

- Windows 10 u 11 **Pro o Enterprise**, que traen Hyper-V. Con Windows Home, ver [Alternativa: WSL2](#alternativa-wsl2).
- Para la VM: 4 CPU, 8 GB de RAM y 80 GB de disco.
- Un administrador de la organización en GitHub, para sacar el token de registro.

## Instalación (Hyper-V)

### 1. Windows: activar Hyper-V y que el PC no se suspenda

En PowerShell como administrador:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reiniciar si lo pide. Después, en PowerShell como administrador:

```powershell
powercfg /change standby-timeout-ac 0
```

```powershell
powercfg /change hibernate-timeout-ac 0
```

### 2. Crear la VM de Ubuntu 24.04

- **Opción A:** en el Administrador de Hyper-V, *Creación rápida* → *Ubuntu 24.04 LTS*.
- **Opción B:** crear una VM de generación 2 e instalar Ubuntu Server 24.04 desde la ISO.

Usar el *Default Switch* como red. Con la VM apagada, en PowerShell como administrador (cambiar `runner-oficina` por el nombre de la VM):

```powershell
Set-VM -Name runner-oficina -ProcessorCount 4 -MemoryStartupBytes 8GB -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown
```

Con `-AutomaticStartAction Start`, la VM arranca sola cuando Windows se reinicia, aunque nadie inicie sesión.

### 3. Sacar un token de registro

Lo hace un administrador de la organización. El token dura una hora. Con `gh`:

```powershell
gh api -X POST orgs/TetherEducation/actions/runners/registration-token --jq .token
```

También se puede sacar en la web: *Settings* de la organización → *Actions* → *Runners* → *New runner*. Ahí es el valor que viene después de `--token`.

### 4. Correr el script en la VM

Copiar `setup-runner.sh` a la VM, por ejemplo con `scp setup-runner.sh usuario@<ip-de-la-vm>:` desde PowerShell. Después, adentro de la VM:

```bash
sudo RUNNER_TOKEN=<token> bash setup-runner.sh oficina-1
```

El script:
- instala Docker Engine;
- crea el usuario `ghrunner`;
- baja la última versión del runner y verifica su SHA-256;
- registra el runner en el grupo `office` con la etiqueta `office-async`;
- lo deja como servicio de systemd;
- agrega una limpieza semanal de imágenes de Docker.

Se puede volver a correr sin problema.

### 5. Verificar

1. **El runner está en línea.** En *Settings → Actions → Runners* de la organización, `oficina-1` aparece *Idle*, en el grupo `office` y con la etiqueta `office-async`.
2. **Arranca solo.** Reiniciar Windows **sin iniciar sesión**. En unos 2 minutos el runner tiene que volver a *Idle*.
3. **Corre un job de verdad.** En `crm-documents-downloader`: *Settings → Secrets and variables → Actions → Variables*, crear `ASYNC_RUNNER` = `office-async`. Después, correr a mano el workflow "CRM Documents Downloader". Cada job muestra en qué runner corrió.

## Operación

- **Actualizaciones.**
  - El runner se actualiza solo.
  - Ubuntu instala los parches de seguridad con `unattended-upgrades`, que viene activo en Ubuntu Server.
- **Volver a GitHub.** Borrar la variable `ASYNC_RUNNER` del repo.
- **Agregar un repo o workflow.** Editar el grupo `office` en *Settings → Actions → Runner groups* de la organización. Después, en el repo, cambiar `runs-on` como arriba y crear la variable.
- **Sacar un runner.** En la VM, desde `/opt/actions-runner`:
  ```bash
  sudo ./svc.sh stop
  ```
  ```bash
  sudo ./svc.sh uninstall
  ```
  ```bash
  sudo -u ghrunner ./config.sh remove --token <token>
  ```
  El token de remoción se saca con:
  ```powershell
  gh api -X POST orgs/TetherEducation/actions/runners/remove-token --jq .token
  ```

## Alternativa: WSL2

Sólo si la máquina no tiene Hyper-V (Windows Home). El aislamiento es menor: desde WSL se ven los discos de Windows.

1. En PowerShell como administrador:
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
   Al terminar, crear el usuario de Linux que pide.
2. Revisar que `/etc/wsl.conf` tenga `[boot]` y `systemd=true`, que es lo normal en Ubuntu 24.04. Si hubo que cambiarlo, correr `wsl --shutdown` en Windows y volver a entrar.
3. Correr el paso 4 de arriba adentro de Ubuntu.
4. **Mantener WSL vivo.** WSL apaga la distro cuando nadie la usa. En el Programador de tareas, crear una tarea con estas opciones:
   - **Disparador:** *Al iniciar el sistema*.
   - **Usuario:** el usuario de Windows que instaló Ubuntu, con *Ejecutar tanto si el usuario inició sesión como si no*.
   - **Acción:** `wsl.exe -d Ubuntu-24.04 -u root -- sleep infinity`.
   - **Configuración:** sin límite de tiempo de ejecución.
5. Hacer la verificación 2: reiniciar sin iniciar sesión y confirmar que el runner vuelve a *Idle*.
