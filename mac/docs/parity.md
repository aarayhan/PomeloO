# PomeloO untuk Mac: selisih dengan versi Windows

Catatan apa yang berbeda dari versi Windows dan alasannya, supaya tidak ada yang mengira keduanya sama.
Setiap angka di sini diukur di macOS 26.5.1 (arm64) kecuali ditandai **[BELUM DIUJI]**.

## Kata sandi PDF: AES-128, bukan AES-256

`docs/features.md` menyebut AES-256 untuk "Add password". Framework Apple di Mac ini hanya sampai AES-128:

| Cara | Hasil di file | Catatan |
|---|---|---|
| `PDFDocument.write(to:withOptions:)` dengan `userPasswordOption` dan `ownerPasswordOption` | `/CFM /AESV2` (AES-128) | |
| `CGContext` dengan `kCGPDFContextEncryptionKeyLength` 40 | RC4 40 bit | tidak aman |
| `CGContext` dengan `kCGPDFContextEncryptionKeyLength` 128 | `/CFM /AESV2` (AES-128) | |
| `CGContext` dengan 256 | konteks menolak (nil) | tidak ada AES-256 |

Karena itu **tool "Add password" (`protectPDF`) belum dibuat di Mac**. Menjanjikan AES-256 dari framework Apple tidak
mungkin, dan mengeluarkan AES-128 dengan nama yang sama adalah keputusan pemilik proyek (pilihan: AES-128 dengan
catatan jelas, pustaka enkripsi sendiri, atau tidak ada tool itu di Mac). "Remove password" (`unlockPDF`) sudah ada
dan membaca semua tingkat.

Temuan lain: menulis ulang dokumen PDFKit yang sudah dibuka dengan `write(to:)` **mempertahankan** enkripsinya.
`unlockPDF` karena itu menggambar ulang tiap halaman ke PDF baru, dan tesnya memastikan hasilnya tidak terenkripsi
sama sekali (`isEncrypted == false`).

## PDF: alat yang menggambar ulang halaman

Watermark, nomor halaman, dan hapus kata sandi menggambar tiap halaman asli ke PDF baru dengan Core Graphics.
Teks dan vektor tetap teks dan vektor (teksnya masih bisa dicari dan disalin), ukuran halaman tetap, dan halaman
yang diputar keluar tegak. Yang **tidak** ikut: penanda (bookmark), tautan, kolom formulir, dan informasi dokumen
(judul, penulis). Versi Windows mengubah dokumen di tempat dan mempertahankannya. Gabung, pecah, dan susun ulang
memakai PDFKit dan menyalin halaman utuh.

## Urutan petal Tools untuk beberapa berkas

`docs/catalog.json` memuat tool untuk satu berkas (`tools`) dan tambahan untuk beberapa berkas (`tools_many`), tetapi
tidak urutan di roda untuk beberapa berkas. Mac menaruh tambahan itu di akhir. Urutan yang sama dengan Windows butuh
`scripts/export_catalog.py` mengekspor daftar itu (file di luar `mac/`).

## OCR ("Copy text")

`VNRecognizeTextRequest` tingkat `.accurate` mendukung bahasa Indonesia (`id-ID`) di macOS 26.5.1, bersama 29 bahasa
lain (Inggris, Prancis, Italia, Jerman, Spanyol, Portugis Brasil, Mandarin, Kanton, Korea, Jepang, Rusia,
Ukraina, Thai, Vietnam, Arab, Turki, Ceko, Denmark, Belanda, Norwegia, Melayu, Polandia, Rumania, Swedia). Tingkat `.fast`
hanya mendukung enam: en-US, fr-FR, it-IT, de-DE, es-ES, pt-BR. Jadi fitur ini harus memakai `.accurate` supaya
mencakup Indonesia. **[BELUM DIUJI]** mutu hasilnya pada teks Indonesia nyata, dan daftar bahasa di macOS 13 sampai 15.

## Alat gambar (kelompok 4b)

Yang sama dengan Windows: rumus "Edit photo" dan urutannya (`apply_edit`), tingkat kualitas, label hasil
(`Compressed`, `No Metadata`, `Edited`, `Cropped`, `Redacted`), kotak wajah dan teks diperbesar 15%, dan aturan
ukuran-target (pencarian biner kualitas 5 sampai 92 untuk JPEG, WebP, HEIC, AVIF, lalu gambar diperkecil 85% bila masih
terlalu besar). Selisihnya:

- **Kompres PNG tidak mengurangi warna ke 256** (Windows memakai kuantisasi FASTOCTREE). Karena ImageIO menulis PNG
  penuh warna, target ukuran untuk PNG yang tidak bisa dipadatkan lagi tercapai dengan memperkecil piksel lebih cepat.
  Kuantisasi ke PNG berpalet (dengan transparansi) belum ada; itu keputusan yang tertunda.
- **Kompres dan metadata menjatuhkan data kamera** (seperti Windows). Crop mempertahankannya, redaksi menjatuhkannya.
- **Grain** memakai pola acak tetap sendiri, bukan `numpy.random.default_rng(0)`, jadi bintiknya berbeda tapi rata-ratanya sama.
  **Clarity** dan **Noise reduction** memakai hampiran: blur Gaussian dari tiga kali kotak, dan median 5×5 yang membiarkan
  dua piksel tepi (seperti filter rank Pillow). Hasilnya mirip, bukan identik piksel per piksel.
- **Deteksi** memakai Vision (wajah, teks per kata) dan bukan detektor Windows. Kotak bisa berbeda; wajah **[BELUM DIUJI]**
  pada foto wajah sungguhan (tes hanya memastikan gambar tanpa wajah tidak diubah).
- **OCR** ("Copy text") memakai `.accurate` dan bahasa otomatis (Indonesia dan Inggris diuji di Mac ini); Windows memakai
  bahasa profil pengguna. **QR dan barcode** lewat Vision: semua jenis barcode yang dikenal Vision, bukan hanya QR.
- **Tidak ditawarkan bila Mac tidak bisa menulis format itu** (misalnya HEIC tanpa encoder): alat yang menulis ulang
  berkas asli (kompres, metadata, edit, crop, redaksi) hanya muncul untuk format yang bisa ditulis.
- Tes tidak membandingkan piksel dengan hasil Python. Yang diuji adalah rumusnya di titik-titik yang bisa dihitung.
