# PomeloO untuk Mac: pemasangan dan rilis

Dokumen ini memuat teks untuk README dan halaman install, cara membuat rilis, dan cara menguji karantina.
Bagian yang belum diverifikasi ditandai **[BELUM DIUJI]**. Jangan dianggap fakta sebelum diisi dari hasil uji di Mac.

## Status penandatanganan

- Rilis Mac ditandatangani **ad-hoc** (`Signature=adhoc`) dan **belum dinotarisasi**.
- Penyebabnya adalah proyek ini belum punya akun Apple Developer berbayar. Format DMG bukan penghalang: DMG bisa dinotarisasi.
  Kalau akunnya ada, rilis yang sama bisa ditandatangani dengan Developer ID dan dinotarisasi tanpa mengubah format.
- Karena belum dinotarisasi, macOS akan memperingatkan saat aplikasi dibuka pertama kali setelah diunduh.
- Hanya Apple Silicon (arm64).

## Langkah membuka pertama kali

**[BELUM DIUJI]** Langkah berikut menunggu verifikasi di macOS 26; teks dialog yang persis akan ditambahkan dari hasil uji.

1. Seret `PomeloO.app` ke `Applications` di jendela DMG, lalu buka PomeloO dari sana.
2. Kalau macOS menolak membukanya, buka **Pengaturan Sistem > Privasi & Keamanan**, cari pesan tentang PomeloO, lalu pilih **Buka Saja**.
3. Konfirmasi dialog berikutnya.

Alternatif lewat Terminal (menghapus atribut karantina dari aplikasi yang sudah ada di `Applications`):

```bash
xattr -dr com.apple.quarantine /Applications/PomeloO.app
```

**[BELUM DIUJI]** Apakah perintah ini cukup di macOS 26 belum diverifikasi.

Cara "klik kanan lalu Open" sengaja tidak dicantumkan: perilakunya di macOS 15 ke atas belum diverifikasi.

## Teks untuk README (draf, bahasa Inggris seperti README)

> ### PomeloO for Mac
> Apple Silicon only. Download `PomeloO-Mac-X.Y.Z.dmg` from the release tagged `mac-vX.Y.Z`.
> The app is signed ad-hoc and **not notarized yet**, because the project doesn't have a paid Apple Developer
> account yet (a DMG can be notarized; the account is what's missing). macOS will warn you the first time you
> open it. See [mac/docs/install.md](mac/docs/install.md) for the steps.
> PomeloO for Mac does not update itself: it shows a notification when a newer `mac-v…` release exists.

README akar berada di luar `mac/`, jadi teks ini belum dipasang di sana.

## Teks untuk halaman install (draf)

> **Mac (Apple Silicon)**: unduh `PomeloO-Mac-X.Y.Z.dmg`, seret PomeloO ke Applications.
> Aplikasi ini belum dinotarisasi karena kami belum punya akun Apple Developer berbayar, jadi macOS akan
> memperingatkan saat pertama dibuka. **[BELUM DIUJI: langkah membukanya, lihat bagian di atas.]**

Halaman install ada di repo website, bukan di sini.

## Membuat rilis

Dari akar repo, setelah executable arm64 selesai dibangun:

```bash
mac/scripts/make-app.sh path/ke/executable 1.0.0 [path/ke/resources]
mac/scripts/make-dmg.sh 1.0.0
```

- `make-app.sh` membuat `mac/build/PomeloO.app`, memasang `Info.plist` dan resource, **baru kemudian** menandatangani ad-hoc,
  lalu menjalankan `codesign --verify --deep --strict` dan `codesign -dv` (harus `Signature=adhoc`, dan `Info.plist entries=`
  harus muncul). Mengubah isi `.app` sesudahnya merusak tanda tangan: jalankan ulang skrip.
- `make-dmg.sh` memeriksa tanda tangan lagi, menyalin app dengan `ditto`, menambah symlink `/Applications`, membuat
  `mac/build/PomeloO-Mac-1.0.0.dmg` (UDZO), menjalankan `hdiutil verify`, dan mencetak SHA-256.
- Bundle ID (`app.pomeloo.mac`), versi macOS minimum (13.0), dan mode tanpa ikon Dock (`LSUIElement`) di `make-app.sh`
  masih **asumsi**. Ganti lewat `BUNDLE_ID`, `MIN_MACOS`, `MENU_BAR_ONLY`.
- Tag rilis: `mac-vX.Y.Z`, versi di nama file sama dengan `X.Y.Z`. Release Mac tidak boleh menjadi "latest" di GitHub,
  supaya cek update Windows (`/releases/latest`) tidak terganggu.

## Menguji karantina

Unduhan dari browser diberi atribut `com.apple.quarantine`. Untuk menirunya pada DMG hasil build:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" mac/build/PomeloO-Mac-X.Y.Z.dmg
xattr -l mac/build/PomeloO-Mac-X.Y.Z.dmg      # pastikan atributnya terpasang
open mac/build/PomeloO-Mac-X.Y.Z.dmg
```

Lalu seret app ke Applications, buka, dan catat setiap dialog yang muncul. Untuk mengulang dari awal, lepas DMG dan hapus
atributnya (`xattr -d com.apple.quarantine <file>.dmg`) atau buat DMG baru.

Catatan hasil (isi dari uji di Mac sendiri, jangan menebak):

| Versi macOS | Langkah | Dialog / hasil yang terlihat |
|---|---|---|
| 26.x | membuka DMG yang diberi karantina | **[BELUM DIUJI]** |
| 26.x | membuka PomeloO.app dari Applications | **[BELUM DIUJI]** |
| 26.x | Pengaturan Sistem > Privasi & Keamanan > Buka Saja | **[BELUM DIUJI]** |
| 26.x | `xattr -dr com.apple.quarantine` lalu buka | **[BELUM DIUJI]** |
