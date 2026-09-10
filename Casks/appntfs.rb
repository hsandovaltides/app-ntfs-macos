cask "appntfs" do
  version :latest
  sha256 :no_check

  url "https://github.com/hsandovaltides/app-ntfs-macos/releases/latest/download/AppNTFS.zip"
  name "AppNTFS"
  desc "Menu bar app that auto-remounts NTFS drives read-write on macOS"
  homepage "https://github.com/hsandovaltides/app-ntfs-macos"

  depends_on cask: "macfuse"

  app "AppNTFS.app"

  # Build isn't notarized (free/personal-team certificate, no Developer ID —
  # see the project's README). This clears the quarantine flag so it opens
  # without the "unidentified developer" prompt; it's still the real signed
  # binary from the release, not a bypass of code-signature verification.
  postflight do
    system_command "/usr/bin/xattr",
                    args: ["-dr", "com.apple.quarantine", "#{appdir}/AppNTFS.app"],
                    sudo: false
  end

  caveats do
    <<~EOS
      NOTA: este build está firmado con un certificado "Apple Development"
      (cuenta gratuita, sin Developer ID ni notarización). Puede no abrir en
      algunas Macs distintas a la del autor. Ver el README del proyecto.

      ntfs-3g viene incluido dentro de la app: no hace falta el tap
      gromgit/homebrew-fuse ni `brew install ntfs-3g-mac`. Se distribuye bajo
      GPLv2; las licencias y el enlace al código fuente están en
      AppNTFS.app/Contents/Resources/ntfs-3g/.

      Quedan dos pasos manuales de aprobación en Ajustes del Sistema (una sola vez):
        1. macFUSE: kernel extension de terceros — necesita el paso de
           Recovery Mode (Utilidad de Seguridad de Arranque → Seguridad
           reducida). Ver el README del proyecto para el detalle.
        2. El helper privilegiado de AppNTFS y su permiso de Acceso completo
           al disco — la propia app te guía a estos dos desde su menú.
    EOS
  end
end
