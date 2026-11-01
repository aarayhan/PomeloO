# PomeloO untuk Mac (Swift native)

Folder ini berisi versi Mac dari PomeloO: file converter dan toolbox yang sampai sekarang hanya ada untuk Windows (Python, folder `pomeloo/`). Versi Mac ditulis ulang sebagai app Swift native. Branch kerja: `mac/mvp`.

## Baca dulu

- `docs/features.md`: apa yang dilakukan PomeloO, termasuk aturan nama hasil.
- `docs/catalog.json`: sumber kebenaran format, tool, dan action (versi 5: 45 format, 34 tool, 8 action).
- `mac/docs/install.md`: pemasangan, tanda tangan ad-hoc, dan peringatan Gatekeeper. Bagian bertanda **[BELUM DIUJI]** belum diverifikasi di Mac.
- `mac/scripts/make-app.sh` dan `make-dmg.sh`: pembuatan `PomeloO.app` dan DMG dari executable arm64.
- `mac/docs/tangerine-analysis.md`: analisis Tangerine, app Mac sejenis. Dipakai hanya sebagai bahan banding arsitektur.
- `pomeloo/` (Python): perilaku acuan, misalnya `rename.py`, `recipes.py`, `history.py`. Port perilakunya, bukan strukturnya.

## Aturan keras

- **Jangan menyalin dari Tangerine.** Tidak boleh ada kode, skrip Perl atau JavaScript, template, aset, atau teks UI dari Tangerine. PomeloO berlisensi AGPL-3.0 dan Tangerine adalah karya pihak lain. Dokumen analisis berisi observasi, bukan sumber untuk ditiru.
- **Jangan commit atau push tanpa diminta.**
- **Tandai klaim yang belum diuji di Mac** dengan **[BELUM DIUJI]**, seperti di `mac/docs/install.md`. Jangan menyatakan sesuatu berfungsi sebelum benar-benar dijalankan.
- Jangan menulis ulang matriks format. Muat `docs/catalog.json` sebagai resource supaya Mac dan Windows tidak berbeda.

## Arsitektur

- **SwiftPM saja**, tanpa `.xcodeproj`. Swift 6, macOS 13+, hanya arm64 (Apple Silicon). `make-app.sh` menerima executable hasil `swift build -c release --arch arm64`.
- **Dua target.**
  - `PomeloOCore`: pemuat katalog, penamaan hasil, mesin konversi, job runner. Tanpa UI, bisa dites dengan `swift test`.
  - `PomeloOMac`: UI menu bar.
- **Menu bar app** (`LSUIElement=true`, sudah menjadi default `make-app.sh`). SwiftUI untuk isi panel, AppKit (`NSPanel` yang tidak mengaktifkan app) untuk panel melayang dan roda.
- **Job runner sebagai actor** sejak awal, karena Swift 6 ketat soal concurrency.
- **Pisahkan logika dari penangkap event.** State mesin roda ada di Core supaya bisa dites. Gestur global sulit diotomasi.
- **Framework Apple dulu.** Gambar: ImageIO dan CoreImage. PDF: PDFKit. OCR, QR, deteksi wajah dan teks: Vision. Dokumen teks (DOCX, RTF, HTML, TXT): `NSAttributedString`.
- **WebP ditulis in-process oleh libwebp, SVG dibaca lewat NSImage.** ImageIO hanya membaca WebP, jadi target `CWebP` berisi sumber libwebp (BSD-3-Clause) yang disalin dari repo resmi oleh `mac/scripts/vendor-libwebp.sh`; EXIF dimasukkan dengan libwebpmux. WebP tidak lewat ffmpeg. SVG digambar oleh CoreSVG (`NSImage`) sampai sekitar 2000 px di sisi terpanjang, seperti versi Windows. **[BELUM DIUJI]** SVG di macOS 13 (diuji di 26.5.1).
- **Gestur global (Fase 3) memakai pembacaan keadaan, bukan pemantau event.** `DragGestureMonitor` membaca `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, dan `changeCount` pasteboard seret (10 Hz, 30 Hz selagi tombol mouse ditekan); aturannya ada di `DragGestureDetector` (Core, bisa dites). Spike di macOS 26.5.1 tidak memunculkan dialog izin. Pintasan ⌃⇧Space memakai `RegisterEventHotKey` (tanpa izin).
- **ffmpeg hanya untuk audio dan video** yang tidak dijangkau AVFoundation (OGG, Opus, WMA, MKV, WebM, AVI, WMV, dan MP3 sebagai target). Build rilis dibundel di `Contents/Resources/Tools/` lewat parameter ketiga `make-app.sh` (helper ditandatangani sebelum app luar) dan dibuat dari sumber resmi, arm64, **tanpa `--enable-gpl`**, lewat skrip tersendiri yang belum ada; itu tugas terpisah sebelum rilis pertama, bukan bagian Fase 4. Jangan mengunduh build statis dari situs pihak ketiga. `THIRD_PARTY_NOTICES.md` untuk libwebp dan ffmpeg dikerjakan di tugas yang sama.
  - **Set encoder build rilis:** `h264_videotoolbox`, `hevc_videotoolbox`, `libvpx-vp9`, `libopus`, `libmp3lame`, ditambah encoder bawaan ffmpeg (`aac`, `flac`, PCM, GIF). `libx264` dan `libx265` **tidak** ada. VideoToolbox tidak mengenal CRF, jadi kompres ke ukuran target dihitung dari bitrate (ukuran dan durasi).
  - **ffmpeg Homebrew hanya untuk pengembangan lokal lewat PATH dan tidak pernah dibundel** (GPL-3.0-or-later, `--enable-shared`, bergantung pada `.dylib` di `/opt/homebrew`). Tulis tool video terhadap set rilis, bukan terhadap Homebrew.
  - Tool atau target yang butuh encoder yang tidak ada tidak boleh ditawarkan: turunkan dari pemeriksaan kapabilitas saat dijalankan (`FFmpegEncoders`, `availableTargets`).
- **Konversi Office (PPTX, XLSX) dan Pages ditunda.** Tangerine memakai JVM dan JavaScript bawaan untuk itu, yang mahal untuk ukuran bundle. Mulai dari format yang bisa dikerjakan framework Apple dan ffmpeg.
- **Tanpa sandbox.** Rilis lewat DMG dengan tanda tangan ad-hoc, bukan Mac App Store. Tanpa sandbox, pemantauan seret global dan peluncuran helper lebih sederhana. Kalau suatu saat ingin App Store, sandbox harus dirancang dari awal. Ini keputusan pemilik proyek.
- Bundle ID (`app.pomeloo.mac`) dan macOS minimum (13.0) di `make-app.sh` tertulis sebagai asumsi. Tanyakan sebelum mengubah atau memastikannya.

## Pola konversi

- Tulis hasil ke file sementara tersembunyi `.pomeloo-<UUID>.<ext>` di folder sumber, lalu rename atomik ke nama akhir. Hasil yang belum selesai tidak terlihat pengguna.
- Nama akhir mengikuti `docs/features.md`: `photo.webp`, lalu `photo 2.webp` bila nama sudah dipakai. Hasil selalu file baru di sebelah sumber; sumber tidak pernah ditimpa.
- Probe file dulu sebelum konversi, misalnya `ffmpeg -i <input> -map 0:v? -map 0:a? -c copy -t 0 -f null -`, supaya gagal lebih awal.
- Progres dari `ffmpeg -progress pipe:1`. **Baca stdout dan stderr secara asinkron**, atau proses macet saat buffer pipe penuh.
- Batal berarti menghentikan proses dan menghapus file sementara.

## Urutan pengerjaan

Kerjakan satu fase sekali jalan, hentikan setelah kriterianya terpenuhi, dan jangan lompat ke fase berikutnya sebelum tes fase sebelumnya hijau.

| Fase | Isi | Selesai bila | Status |
|---|---|---|---|
| 0 | `Package.swift`, menu bar kosong, build release arm64, lalu `make-app.sh` dan `make-dmg.sh` menghasilkan DMG | app terbuka di Mac dan ikon muncul di menu bar | selesai |
| 1 | Core: protokol mesin, pemuat katalog, penamaan hasil, job runner dengan progres dan batal; konversi gambar (ImageIO) dan audio/video (ffmpeg) | `swift test` hijau; satu konversi gambar dan satu audio berjalan | selesai |
| 2 | Pintu masuk UI: pad melayang untuk drop file, lalu roda format di kursor | drop file memilih format dan konversi jalan | selesai |
| 3 | Gestur global (seret file di Finder lalu tap Shift, Ctrl, atau Alt) dan pintasan keyboard | roda muncul dari Finder | selesai |
| 4 | Tool per jenis file (kompres, metadata, OCR, PDF, dan seterusnya), bertahap menurut pemakaian | tiap tool punya tes di Core | belum |
| 5 | Recipes, riwayat dengan undo, pembaruan | paritas dengan Windows | belum |

Fase 3 selesai dengan Shift; tap Control dan Option sudah dikenali tetapi belum membuka roda Tools dan Actions (Fase 4). **[BELUM DIUJI]** tap Control dan Option, dan macOS 13 sampai 15.

## Jebakan yang sudah diketahui

- **Gestur Fase 3 tidak butuh izin Accessibility atau Input Monitoring, jadi tidak butuh sertifikat penandatangan yang stabil.** Itu terverifikasi di macOS 26.5.1 dengan spike (tidak ada dialog, tidak ada permintaan di log sistem). **[BELUM DIUJI]**: tap Control dan Option, macOS 13 sampai 15, dan seret dari app selain Finder. Detailnya ada di `mac/docs/install.md`.
- **Izin Automation (Apple Events, dipakai untuk membaca pilihan Finder) bertahan di antara build ad-hoc dengan bundle ID yang sama.** Terbukti di macOS 26.5.1 dengan dua build berurutan (CDHash berbeda): dialog tidak muncul lagi. Jangan ubah bundle ID `app.pomeloo.mac` tanpa mengulang izin. **[BELUM DIUJI]**: versi macOS lain, update lewat DMG yang menimpa app, dan layanan lain (Screen Recording, Accessibility).
- **Helper bertanda sandbox-inherit tidak bisa dijalankan sendiri.** Itu kasus di Tangerine; PomeloO tanpa sandbox tidak punya batasan ini. Jangan meniru entitlement itu.
- **Mengubah isi `.app` setelah ditandatangani merusak segelnya.** Jalankan `make-app.sh` lagi, jangan mengedit bundle.
- **Peringatan Gatekeeper** saat membuka DMG pertama kali sudah tercatat di `mac/docs/install.md` dan belum diuji.
- **Build ini hanya arm64.** Tidak ada slice Intel; `make-app.sh` menolak executable tanpa arm64.
