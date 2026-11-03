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

Keputusan pemilik proyek: **tool "Add password" (`protectPDF`) tetap ada di Mac dengan AES-128**, dan label di dialog
tertulis "AES-128". Jangan menyebut AES-256 untuk Mac di `docs/features.md` atau di mana pun. Windows memakai AES-256
lewat PyMuPDF; itu selisih yang disengaja. Tidak ada kriptografi buatan sendiri. Kalau suatu saat AES-256 wajib,
pakai pustaka yang sudah teruji (misalnya qpdf) sebagai tugas terpisah.

Satu catatan kekuatan: pada PDF versi R4 (AES-128) kunci diturunkan dari kata sandi dengan MD5, jadi kekuatannya
bergantung pada kata sandi yang panjang. Dialog mengatakan hal yang sama. Kata sandi kosong ditolak, dan PDF yang
sudah terkunci tidak bisa diberi kata sandi lagi sebelum dibuka.

"Remove password" (`unlockPDF`) memakai `PDFDocument.unlock` lalu menyimpan tanpa enkripsi; kata sandi yang sekarang
diperlukan. Ia membaca semua tingkat.

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
  penuh warna, target ukuran untuk PNG yang tidak bisa dipadatkan lagi tercapai dengan memperkecil piksel. Pengguna
  **diberi tahu**: hasilnya memuat catatan "diperkecil menjadi W×H px" yang tampil di notifikasi hasil. Ini selisih
  yang diketahui dan harus ditutup **sebelum rilis pertama** (tugas terpisah): kuantisasi ke PNG berpalet 256 warna
  dengan transparansi. Rencana: (1) uji dulu apakah palet terindeks CoreGraphics bisa membawa alfa per entri
  **[BELUM DIUJI]**; (2) bila tidak, pustaka C kecil di dalam repo (pola `CWebP`) yang menulis PLTE/tRNS/IDAT, dengan
  kuantiser octree sendiri di Swift; (3) periksa lisensi libimagequant sebelum mempertimbangkannya.
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

## Alat audio dan video (kelompok 4c)

Diuji dengan ffmpeg build rilis (`mac/build/ffmpeg`) dan dengan Homebrew; tes `MediaToolsTests` (41) lulus di keduanya.
Tool yang ada: compress, metadata, normalize, visualizer, trim (audio dan video), channels, bleep, mute, crop, speed,
snapshots, split, redact, join. Yang sama dengan Windows: rumus filter dan urutannya (`pomeloo/tools/media.py`), label hasil,
penamaan, dua lintasan loudnorm, atempo berantai, join di kanvas klip pertama dengan keheningan untuk klip tanpa suara.
Selisihnya:

- **H.264 ditulis oleh VideoToolbox, bukan libx264** (build rilis tidak punya libx264 karena GPL). Konversi ke MP4, MOV, MKV dan
  semua tool yang menulis ulang video memakai `-q:v 65`, bukan CRF 23. **[BELUM DIUJI]** bahwa kualitasnya setara pada
  rekaman nyata; hanya klip sintetis yang dibandingkan. Build pengembangan juga memilih VideoToolbox lebih dulu supaya
  perilakunya sama dengan rilis; libx264 hanya dipakai bila VideoToolbox tidak ada.
- **Kompres video satu lintasan dengan bitrate hitungan**, bukan dua lintasan x264. Ukuran hasil mendekati target (klip uji 4 detik:
  target 400 kbps menjadi 432 kbps), tidak setepat dua lintasan. Dialog mengatakannya.
- **OGG ditulis oleh libvorbis** (`-q:a 5`, seperti Windows), yang ada di build rilis (libvorbis 1.3.7 dan libogg 1.3.6, BSD-3-Clause).
  Encoder bawaan ffmpeg untuk Vorbis tidak dipakai (eksperimental) dan OGG tidak diganti dengan Opus. Build Homebrew tidak punya
  libvorbis, jadi di sana OGG tidak ditawarkan dan tes OGG (`OGGTests`) memakai build rilis langsung; tanpa build itu tes
  dilewati dengan penanda **[BELUM DIUJI]**, tidak dihitung lulus. Kompres OGG berhenti di 48 kbps ke bawah karena libvorbis menolak
  bitrate di bawah 45 kbps untuk stereo 44,1 atau 48 kHz (kode Windows memakai batas bawah 32 untuk semua format; apakah ini membuat
  kompres OGG gagal di Windows **[BELUM DIUJI]**).
- **Burn in subtitles ditunda sampai setelah rilis pertama.** Filter `subtitles` dan `drawtext` butuh libass dan freetype, yang
  tidak ada di build rilis, jadi tool ini disembunyikan. Keputusan pemilik: kerjakan sebagai tugas build tersendiri bila ada
  permintaan, bukan sekarang. Alasannya empat sampai lima pustaka baru dengan lisensi berbeda (libass ISC, freetype FTL, harfbuzz MIT,
  fribidi LGPL-2.1+, libunibreak), pengujian font untuk Arab, Thai, CJK, dan gaya .ass. Jangan membuat versi setengah jadi lewat
  `drawtext` dengan penguraian SRT sendiri (tanpa gaya .ass, teks kanan-ke-kiri salah) atau lewat AVFoundation (hanya MP4 dan MOV).
  Bila dibuka lagi: periksa apakah libass memakai penyedia font CoreText di macOS **[BELUM DIUJI]** supaya fontconfig tidak
  diperlukan, dan periksa kewajiban LGPL fribidi pada build statis.
- **Blur redaksi memakai `gblur`**, karena filter `boxblur` tidak ada di build rilis. Kekuatannya mirip, bukan identik.
- **Metadata**: menghapus memakai `-fflags +bitexact` supaya ffmpeg tidak menulis tag "Lavf" ke file yang seharusnya tanpa tag
  (kode Windows tidak memakai opsi ini). Mengedit dibatasi enam kolom (title, artist, album, genre, date, comment); Windows menampilkan
  semua tag file.
- **Dialog memakai angka, bukan pemutar dan gambar area.** Waktu diketik (`83.5`, `1:23.5`), crop video dari tengah (aspek atau piksel
  persis), redaksi video lewat kotak persen dengan waktu mulai dan selesai. Pemutar dengan tanda In/Out, pemilihan area, dan
  pemutaran Original/Result ada di Windows dan belum ada di Mac.
- **Kecepatan dibatasi 0,25× sampai 8×.** Visualizer tidak memakai `-tune stillimage` (khusus libx264). Snapshot di ujung video
  digeser sedikit ke dalam supaya selalu ada bingkai.
- **Alat ditawarkan hanya bila ffmpeg yang dipakai bisa menulis formatnya**: misalnya Compress untuk WAV butuh encoder FLAC,
  visualizer dan join butuh H.264 dan AAC. Tanpa ffmpeg tidak ada tool audio atau video yang muncul.
- **Split tepat** memaksa key frame di titik potong dan memotong dengan segmen; durasi tiap bagian cocok dalam 0,3 detik di klip uji.
  **[BELUM DIUJI]** pada video nyata dengan GOP panjang.
- **Dialog audio dan video belum dilihat dengan tangan**; tes hanya membuktikan tata letak dan kata-katanya digambar. **[BELUM DIUJI]**
  macOS 13 sampai 15.
