pkgname=appsupport_launcher_windows
pkgver=1.0.0
_tag=dev-v1.0.0
pkgrel=1
pkgdesc="Windows application support for JappeOS."
arch=('x86_64')
url="https://github.com/JappeOS/$pkgname"
license=('GPL-3.0')
depends=('glibc' 'gtk3' 'zenity' 'perl-image-exiftool')
makedepends=('git' 'clang' 'cmake' 'ninja' 'xdg-utils')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/$_tag.tar.gz")
sha256sums=('SKIP')

_bundle="$srcdir/$pkgname-$_tag/build/linux/x64/release/bundle"
_desktopFile="appsupport-launcher-windows.desktop"

build() {
  cd "$srcdir/$pkgname-$_tag"
  flutter build linux --release
  dart compile exe bin/appsupport_launcher_windows.dart -o $_bundle/$pkgname
}

package() {
  cd "$_bundle"

  # Install to /opt
  install -dm755 "$pkgdir/opt/$pkgname"
  cp -r * "$pkgdir/opt/$pkgname"

  # Symlink executable to /usr/bin
  install -dm755 "$pkgdir/usr/bin"
  ln -s "/opt/$pkgname/$pkgname" "$pkgdir/usr/bin/$pkgname"

  # Install desktop entry
  install -Dm644 "$srcdir/$pkgname-$_tag/appsupport-launcher-windows.desktop" \
    "$pkgdir/usr/share/applications/appsupport-launcher-windows.desktop"

  # Set MIME types
  xdg-mime default "$_desktopFile" application/x-ms-dos-executable application/x-msdownload application/vnd.microsoft.portable-executable
}