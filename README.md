# app-ntfs-macos

App de barra de menú para macOS que detecta pendrives/discos NTFS al conectarse
y los remonta automáticamente en modo lectura/escritura, usando
[macFUSE](https://github.com/macfuse/macfuse) + [ntfs-3g](https://www.tuxera.com/community/open-source-ntfs-3g/)
como driver NTFS. macOS solo soporta NTFS en modo lectura de forma nativa —
esta app no reimplementa un driver NTFS, orquesta el motor que ya existe.

### Backends de FUSE

macFUSE ofrece dos backends: el kernel extension (kext) clásico, y uno basado
en **FSKit** (user-space, sin kext, `-o backend=fskit`, macOS 15.4+). La app
**intenta FSKit primero y cae al kext** si no monta — ver `FuseBackend` y
`DependencyStatus.mountBackends`.

Esto importa porque el kext es lo que obliga a los dos pasos manuales que la
app no puede automatizar: entrar en **Modo Recuperación** para bajar la
política de seguridad, y aprobar la extensión de kernel, cada uno con su
reinicio. Con FSKit no hace falta ninguno: el usuario activa un interruptor en
Ajustes del Sistema y listo. Por eso, cuando FSKit está disponible, la app deja
de exigir que macFUSE esté aprobado (`DependencyStatus.macFUSEUsable`).

Dos cosas que conviene dejar dichas, porque contradicen lo que uno esperaría:

- **No hace falta recompilar `ntfs-3g` ni usar `fuse-t`.** El binario tal cual
  viene del tap `gromgit/homebrew-fuse` enlaza `libfuse.2.dylib` y aun así
  acepta `-o backend=fskit`; la libfuse2 de macFUSE lo reenvía a `MFMount`.
  Las notas de la 5.1.0 dicen que el backend FSKit es solo para libfuse3, pero
  desde la 5.2.0 ambas pasan por el mismo camino (verificado ejecutando el
  montaje y viendo la llamada a `MFMount`).
- **`ntfs-3g` sale con código 0 aunque el montaje falle** — se demoniza, y el
  proceso padre vuelve antes de que el hijo sepa el resultado (medido: un
  montaje rechazado con "File system extension not enabled" sale 0 y sin
  stderr). Por eso el pipeline confirma el montaje contra la tabla de montajes
  (`statfs`) y no por el exit code. macFUSE 5.4.0 arregla esto
  ([macfuse#1178](https://github.com/macfuse/macfuse/issues/1178)), pero la
  comprobación se queda: cuesta un `statfs` y es lo que hace correcto el
  pipeline en las versiones de macFUSE que la gente ya tiene instaladas.

El paso que sí queda es activar la extensión: **Ajustes del Sistema → General →
Elementos de inicio y extensiones → Extensiones del sistema de archivos →
macFUSE**. No hay API ni comando que lo haga por el usuario. Si macFUSE ni
siquiera aparece en esa lista, sus extensiones quedaron sin registrar en
PluginKit — algo bastante común, y que `macfuse install --components
file-system-extensions --force` no arregla (sale 0 sin registrar nada). Para
eso está `Scripts/register-fskit.sh`, que es el workaround de
[macfuse#1071](https://github.com/macfuse/macfuse/issues/1071); la app ofrece
el mismo comando desde el menú cuando un montaje falla.

Limitaciones conocidas de FSKit, ninguna bloqueante acá: los mountpoints tienen
que estar bajo `/Volumes` (que es lo único que
`HelperRequestValidation.isValidMountPath` acepta de todos modos) y varias
mount options tradicionales todavía no están implementadas (`volname` puede
ignorarse — cosmético).

El montaje real en escritura requiere privilegios de root (`ntfs-3g` se niega
a montar como usuario normal — ver "Arquitectura" abajo), así que la app
instala un **helper privilegiado** (`AppNTFSHelper`, un `LaunchDaemon`
registrado vía `SMAppService`) que el usuario aprueba una sola vez en Ajustes
del Sistema.

## Requisitos

- macOS 15 (Sequoia) o superior.
- [Xcode](https://developer.apple.com/xcode/) instalado (no alcanza con las
  Command Line Tools: `xcodebuild`/ejecutar la app requiere el Xcode.app
  completo).
- [Homebrew](https://brew.sh).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para regenerar
  `AppNTFS.xcodeproj` si cambia `project.yml`:
  ```
  brew install xcodegen
  ```
- Un Team ID de Apple Developer (alcanza con una cuenta personal gratuita)
  configurado en `project.yml` (`DEVELOPMENT_TEAM`, hoy vacío) — la app y el
  helper privilegiado deben firmar con el mismo Team ID para que la
  validación de código del helper (ver `AppNTFSHelper/HelperListenerDelegate.swift`)
  y el registro vía `SMAppService` funcionen. Configuralo en Xcode
  (Signing & Capabilities de ambos targets) o directamente en `project.yml` y
  volvé a correr `xcodegen generate`.

## Instalar las dependencias NTFS (macFUSE)

**ntfs-3g ya no hay que instalarlo.** `Scripts/embed-ntfs-3g.sh` copia
`ntfs-3g`, `ntfs-3g.probe` y `ntfsfix` (más sus dylibs) dentro del bundle
durante el build, reescribe sus rutas de carga a `@executable_path/../Frameworks`
y los vuelve a firmar. `DependencyChecker` prefiere esas copias y solo cae a
Homebrew si el bundle no las trae.

Para *compilar* la app sí hace falta tenerlo instalado, porque el script lo
copia de ahí. El `ntfs-3g` de homebrew-core es **solo para Linux**; en macOS
hay que usar la formula `ntfs-3g-mac` del tap `gromgit/homebrew-fuse`:

```sh
brew tap gromgit/homebrew-fuse
brew trust --formula gromgit/fuse/ntfs-3g-mac
brew install ntfs-3g-mac
```

El `brew trust` hace falta desde Homebrew 6.0: los taps de terceros ya no se
cargan sin confiar en ellos explícitamente, y sin esa línea el `install` corta
con *«Refusing to load formula … from untrusted tap»*. Confiar en la fórmula
concreta en vez de en el tap entero (`brew trust gromgit/fuse`) deja fuera las
otras 35 fórmulas del tap.

Si no está, el build no falla: emite un warning y produce una app que seguirá
pidiendo Homebrew en la máquina del usuario. Eso está bien para compilar en
local, pero sería un desastre silencioso en un release —así que el workflow de
release pasa `REQUIRE_EMBEDDED_NTFS3G=1`, que convierte ese warning en error, y
después verifica sobre el `.app` ya construido que los tres binarios y las
licencias estén adentro y que ningún load command siga apuntando al Homebrew de
la máquina de build.

ntfs-3g es GPLv2 (y libntfs-3g LGPLv2), así que el script también copia
`COPYING`, `COPYING.LIB`, `AUTHORS` y una nota con el origen del código a
`AppNTFS.app/Contents/Resources/ntfs-3g/`. Eso es obligatorio al redistribuir
los binarios, no opcional.

**macFUSE sí sigue haciendo falta.** No se puede empotrar: `ntfs-3g` enlaza
`/usr/local/lib/libfuse.2.dylib` por ruta absoluta, y esa librería es la mitad
en espacio de usuario de una kernel extension que el usuario tiene que
instalar y aprobar igual.

```sh
brew install --cask macfuse
```

### Activar la extensión FSKit (camino recomendado, sin reinicios)

En macOS 15.4 o superior con un macFUSE que traiga su módulo FSKit, este es el
único paso que queda:

**Ajustes del Sistema → General → Elementos de inicio y extensiones →
Extensiones del sistema de archivos → activar macFUSE.**

Si macFUSE no aparece en esa lista, registrá sus extensiones primero:

```sh
./Scripts/register-fskit.sh
```

(La app ofrece las dos cosas —abrir el panel y correr el registro— desde el
menú cuando un montaje falla.)

### Aprobar el kext (solo si no podés usar FSKit)

Con el backend kext clásico hace falta un paso único de **Recovery Mode** para
permitir kernel extensions de terceros (en Apple Silicon, el ajuste general de
"seguridad reducida" no alcanza por sí solo — confirmado en pruebas reales):

1. Apagá el Mac. Mantené presionado el botón de encendido/Touch ID hasta ver
   "Cargando opciones de arranque" y entrá a **Utilidad de Seguridad de
   Arranque**.
2. **Política de seguridad...** → elegí **Seguridad reducida** y marcá
   **"Permitir la gestión de extensiones del kernel desde desarrolladores
   identificados"**. Confirmá; el Mac reinicia normal.
3. Intentá montar algo con `ntfs-3g` (a mano o desde la app) — recién ahí
   macOS muestra el banner de aprobación puntual para el desarrollador de
   macFUSE ("Benjamin Fleischer") en **Ajustes del Sistema → Privacidad y
   Seguridad**. Aprobalo y reiniciá una vez más.

La primera vez que corrés la app, además, va a registrar el helper
privilegiado (`AppNTFSHelper`), que también necesita una aprobación en
**Ajustes del Sistema → Elementos de inicio y extensiones**. La app detecta
ambos estados (instalado pero no aprobado / aprobado) y te guía desde el
propio menú si falta algo.

Un tercer permiso, separado y fácil de pasar por alto: el helper corre como
root, pero **root no alcanza** para leer los dispositivos de disco raw
(`/dev/rdiskN`) — eso está protegido por **Acceso completo al disco** (TCC),
que se concede por binario específico, no por usuario/proceso-root en
general (confirmado en pruebas reales: sin este permiso, el helper falla con
`EPERM`/"Operation not permitted" al abrir el device, aunque corra como
root). La app detecta esto automáticamente (intentando abrir un disco raw
desde el helper) y te guía desde el menú — "Mostrar el helper en Finder" para
arrastrarlo a la lista de Ajustes → Privacidad y Seguridad → Acceso completo
al disco.

## Arquitectura

- `AppNTFSKit/` — Swift Package con toda la lógica (sin UI), testeable de forma
  aislada:
  - `DiskWatcher` — detecta volúmenes NTFS vía DiskArbitration.
  - `DependencyChecker` — resuelve dónde está ntfs-3g (primero las copias
    empotradas en el bundle vía `BundledNtfs3g`, después Homebrew) y detecta
    macFUSE, el estado de
    aprobación de la extensión de sistema, del helper privilegiado y del
    Acceso completo al disco del helper (`FullDiskAccessProbing`, la
    implementación real vive en `AppNTFS/Helper/PrivilegedHelperMounter`
    porque requiere XPC).
  - `MountManager` — orquesta el desmontaje del volumen nativo (solo lectura)
    y el remontaje con `ntfs-3g` vía el helper privilegiado (`PrivilegedMounting`),
    con detección de "dirty flag" de Windows y fallback automático a solo
    lectura si algo falla.
  - `ProcessRunner` — wrapper inyectable sobre `Process`, para poder testear
    todo lo anterior sin tocar discos reales.
- `AppNTFS/` — target de la app (SwiftUI, `MenuBarExtra`), incluye
  `Helper/PrivilegedHelperMounter.swift` (cliente XPC hacia el helper).
- `AppNTFSHelper/` — target `tool` que corre como root (`LaunchDaemon`
  registrado vía `SMAppService.daemon`), expone un único método XPC
  (`mountReadWrite`, no un "ejecutar comando" genérico) y valida por firma de
  código que quien conecta es `AppNTFS.app`.
- `AppNTFSHelperProtocol/` — protocolo XPC + constantes compartidas entre
  `AppNTFS` y `AppNTFSHelper` (fuentes planas, no un paquete SPM — ver
  comentario en `DependencyChecker.swift` sobre por qué `AppNTFSKit` no puede
  compartir este módulo).
- `project.yml` — spec de XcodeGen que genera `AppNTFS.xcodeproj`, incluyendo
  el embed del helper en `Contents/MacOS/` y la copia de su `LaunchDaemon`
  plist a `Contents/Library/LaunchDaemons/`.
- `dev-tools/make-ntfs-fixture.sh` — genera una imagen de disco NTFS simulada
  para desarrollar sin necesitar un pendrive real.

### Por qué hace falta un helper privilegiado (no es solo FSKit)

Probando el pipeline a mano aparecieron dos problemas de permisos reales:

1. Crear el directorio de mountpoint bajo `/Volumes/<Nombre>` falla con
   `Permission denied` como usuario normal (`/Volumes` es `755 root:wheel`).
2. `ntfs-3g <device> <mountpoint> -o ...` como usuario normal falla con:
   *"Unprivileged user can not mount NTFS block devices using the external
   FUSE library."* — un chequeo del propio binario (compilado
   `--with-fuse=external`, no setuid), independiente del backend usado.

`diskutil unmount`/`diskutil mount` (remount nativo de solo lectura) sí
funcionan sin privilegios. Por eso el helper solo expone esa operación
puntual (crear el directorio + invocar `ntfs-3g`, atómico) y nada más.

## Compilar y correr

```sh
# 1. (Re)generar el proyecto Xcode a partir de project.yml
xcodegen generate

# 2. Abrir en Xcode
open AppNTFS.xcodeproj
```

Antes de compilar, configurá `DEVELOPMENT_TEAM` (ver "Requisitos"). Desde
Xcode: seleccioná el scheme `AppNTFS` y correlo (⌘R). Es una app de barra de
menú (`LSUIElement`), así que no vas a ver ícono en el Dock — buscá el ícono
nuevo en la barra de menú. Al primer arranque va a registrar el helper
privilegiado; aprobalo en Ajustes del Sistema cuando aparezca.

### Tests de AppNTFSKit

```sh
cd AppNTFSKit
swift test
```

> **Nota (entorno sin Xcode.app completo):** con solo las Command Line Tools
> instaladas, `swift test` puede fallar en tiempo de *link* buscando
> `Testing.framework`. Si te pasa, corré:
> ```sh
> swift test \
>   -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
>   -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
>   -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
> ```
> Con Xcode.app instalado (`xcode-select -p` apuntando a
> `/Applications/Xcode.app/...`) esto no hace falta.

### Simular un pendrive NTFS sin hardware real

```sh
dev-tools/make-ntfs-fixture.sh
hdiutil attach dev-tools/ntfs-fixture.sparseimage
```

Esto dispara los mismos eventos de DiskArbitration que insertar un pendrive
físico (verificado: el fixture termina detectado como `Windows_NTFS`/`ntfs`,
igual que un pendrive real), así que sirve para probar `DiskWatcher` +
`MountManager` de punta a punta desde Xcode. Para "expulsarlo":
`hdiutil detach <device>`.

Para simular un disco con **dos particiones NTFS** (probar que cada una se
detecta y remonta de forma independiente):
```sh
dev-tools/make-ntfs-fixture-multi.sh
hdiutil attach dev-tools/ntfs-fixture-multi.sparseimage
```

## Limitaciones conocidas / qué falta validar con hardware real

El flujo completo del helper (registro vía `SMAppService`, aprobación,
validación de firma vía `SecCodeCheckValidity`, XPC, probe, mount real) ya
se probó de punta a punta en Mac real y quedó funcionando en escritura,
tanto con el fixture simulado como con un pendrive físico. Bugs reales
encontrados y corregidos en el camino (todos con test de regresión en
`AppNTFSKit`):

- **Probe con permiso denegado se confundía con "disco sucio"**: corría como
  usuario normal antes de existir el helper; se movió al helper (root) —
  ver `PrivilegedMounting.probeReadWrite`.
- **`ntfs-3g.probe` corría antes de desmontar**: fallaba con "Resource busy"
  en cualquier disco montado (sin importar permisos) y eso también se leía
  como "sucio". Se invirtió el orden: desmontar → probar → montar/restaurar.
- **`HelperOperationResult` no cruzaba XPC**: al compilarse por separado en
  los targets `AppNTFS`/`AppNTFSHelper` (fuentes compartidas, no un
  framework), Swift le daba nombres de clase Objective-C distintos en cada
  uno; hacía falta `@objc(HelperOperationResult)` explícito.
- **Faltaba `setClasses` del lado del helper**: `NSXPCInterface` exige
  declarar las clases custom en ambos extremos de la conexión, no solo en
  el cliente — se centralizó en `AppNTFSHelperXPC.makeInterface()`.
- **Acceso completo al disco**: ser root no alcanza para leer
  `/dev/rdiskN`/`/dev/diskN` — es un permiso TCC aparte, por binario. Se
  agregó detección automática (`FullDiskAccessProbing`) y un banner con
  deep link + "mostrar en Finder" para guiar al usuario.
- **Loop de remontaje automático**: un fallo de mount disparaba
  `restoreReadOnly`, que generaba un nuevo evento de DiskArbitration que
  reingresaba al pipeline sin parar. El guard que lo evitaba solo cubría el
  camino de éxito.
- **El mount real necesita el device de *bloque*, no el raw**: `ntfs-3g.probe`
  funciona con `/dev/rdiskN`, pero el mount de escritura fallaba ahí con
  `ntfs_attr_pread_i: ntfs_pread failed: Invalid argument` leyendo el
  `$Bitmap` (lectura no alineada) — reproducible incluso en el fixture
  recién creado, nada específico del disco real. `NTFSVolume.blockDevicePath`
  (`/dev/diskN`) es lo que hay que pasarle al mount.

Otras limitaciones que siguen abiertas:

- El deep link a Ajustes del Sistema (`x-apple.systempreferences:...`) es
  best-effort — Apple reorganizó Ajustes del Sistema varias veces entre
  Ventura/Sonoma/Sequoia/Tahoe. Esto aplica a la aprobación de macFUSE, la
  del helper (Elementos de inicio y extensiones) y la de Acceso completo al
  disco.
- El parsing de `systemextensionsctl list` (para saber si la extensión de
  sistema de macFUSE está aprobada) es por substring, no hay una API
  estructurada de Apple para esto. Con el backend FSKit ese estado deja de ser
  bloqueante: una máquina que monta por FSKit se queda en "instalado, sin
  aprobar" para siempre y funciona igual.
- La detección de FSKit (`FuseBackendAvailability`) responde "¿puede llegar a
  funcionar?" —versión de macOS y extensión presente en disco—, no "¿está
  activado?". Si está registrada pero apagada no hay forma de saberlo sin
  intentar el montaje: incluso con `pluginkit` reportándola habilitada, el
  montaje falla con "File system extension not enabled" (macFUSE 5.3.3 /
  macOS 26.6.2). El pipeline lo resuelve intentando y cayendo al kext.

Checklist de hardware real — todo confirmado funcionando:

- ✅ Nombres de archivo Unicode (acentos, japonés, emoji).
- ✅ Extracción sin expulsar (unsafe removal): la app no crashea, el disco se
  limpia del estado interno y se vuelve a detectar/montar bien al
  reconectarlo.
- ✅ Sleep/wake con el disco montado en escritura.
- ✅ Múltiples particiones NTFS en el mismo disco físico, detectadas y
  remontadas cada una de forma independiente — ver
  `dev-tools/make-ntfs-fixture-multi.sh` para reproducir sin hardware real.
- La app no está sandboxed (necesario para invocar `diskutil`/`ntfs-3g`).
  Sin una cuenta de Apple Developer Program paga no hay Developer ID ni
  notarización posibles — el release automático (ver "Distribución" abajo)
  firma con el Team ID gratuito, así que Gatekeeper va a advertir
  "desarrollador no identificado" la primera vez que alguien la abra.

## Distribución

`.github/workflows/release.yml` compila, firma, tagea y publica un
[GitHub Release](https://github.com/hsandovaltides/app-ntfs-macos/releases)
con el `.zip` de `AppNTFS.app` en cada push a `main` (o sea, en cada PR
mergeado) — el tag es un patch-bump automático sobre el último `vX.Y.Z`
existente (`v0.1.0` si todavía no hay ninguno).

Como no hay Developer ID, la firma usa el certificado "Apple Development"
de una cuenta personal/gratuita (el mismo Team ID que ya está en
`project.yml`) importado desde secrets — Xcode no puede auto-gestionar el
signing en CI sin una sesión de Apple ID, así que el workflow compila sin
firma y firma después a mano con `codesign` directo (primero el helper,
después la app, igual que exige la validación de firma en
`AppNTFSHelper/HelperListenerDelegate`).

> **Advertencia sobre "Apple Development":** ese tipo de certificado está
> pensado para *desarrollo local*, no para distribución. Un `.app` firmado
> así corre bien en la máquina que generó el certificado, pero en **otra**
> Mac puede directamente no abrir (no solo el aviso de Gatekeeper —
> `SecCodeCheckValidity` del helper puede fallar, o el sistema rechazar el
> `LaunchDaemon`), porque estos certificados suelen estar atados a equipos
> registrados. Distribución realmente portable = cuenta de Apple Developer
> Program paga + "Developer ID Application" + notarización. Hasta entonces
> los releases sirven sobre todo para la propia máquina del autor y para
> pruebas.

### Configurar los secrets (una sola vez)

1. Exportá tu certificado de firma desde Keychain Access: buscá
   "Apple Development: ..." en la categoría "My Certificates", clic derecho
   → Exportar → formato `.p12`, con una contraseña.
2. Codificalo en base64:
   ```sh
   base64 -i Certificados.p12 | pbcopy
   ```
3. Encontrá el nombre exacto del certificado:
   ```sh
   security find-identity -v -p codesigning
   ```
   (algo como `Apple Development: tu@email.com (4AKKTNTXC4)`).
4. En GitHub → Settings → Secrets and variables → Actions, agregá:
   - `MACOS_CERTIFICATE_P12` — el base64 del paso 2.
   - `MACOS_CERTIFICATE_PASSWORD` — la contraseña que le pusiste al `.p12`.
   - `KEYCHAIN_PASSWORD` — cualquier contraseña nueva, solo la usa el
     keychain temporal de CI.
   - `MACOS_SIGNING_IDENTITY` — el nombre exacto del paso 3.

Si más adelante sacás una cuenta de Developer Program paga, el reemplazo es
sencillo: cambiar `DEVELOPMENT_TEAM` en `project.yml`, repetir estos pasos
con el certificado "Developer ID Application" nuevo, y agregar un paso de
`notarytool submit --wait` + `stapler staple` después de firmar.

## Instalar vía Homebrew

Este mismo repo funciona como tap (no hace falta uno separado):

```sh
brew tap hsandovaltides/app-ntfs-macos https://github.com/hsandovaltides/app-ntfs-macos.git
brew install --cask appntfs
```

El cask (`Casks/appntfs.rb`) apunta siempre al último release y le saca el
atributo de cuarentena automáticamente (la app sigue firmada, solo no está
notarizada — ver "Distribución" arriba). Instala `macfuse` como dependencia
del cask; ntfs-3g viene dentro de la app y no requiere ningún paso extra.
