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
- **ffmpeg arm64 bawaan** untuk audio dan video yang tidak dijangkau AVFoundation (OGG, Opus, WMA, MKV, WebM, AVI, WMV). Taruh di `Contents/Resources/Tools/` lewat parameter ketiga `make-app.sh`, tandatangani helper sebelum app luar, dan periksa lisensi build ffmpeg serta perbarui `THIRD_PARTY_NOTICES.md`. ffmpeg belum terpasang di mesin pengembangan ini.
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

| Fase | Isi | Selesai bila |
|---|---|---|
| 0 | `Package.swift`, menu bar kosong, build release arm64, lalu `make-app.sh` dan `make-dmg.sh` menghasilkan DMG | app terbuka di Mac dan ikon muncul di menu bar |
| 1 | Core: protokol mesin, pemuat katalog, penamaan hasil, job runner dengan progres dan batal; konversi gambar (ImageIO) dan audio/video (ffmpeg) | `swift test` hijau; satu konversi gambar dan satu audio berjalan |
| 2 | Pintu masuk UI: pad melayang untuk drop file, lalu roda format di kursor | drop file memilih format dan konversi jalan |
| 3 | Gestur global (seret file di Finder lalu tap Shift, Ctrl, atau Alt) dan pintasan keyboard | roda muncul dari Finder |
| 4 | Tool per jenis file (kompres, metadata, OCR, PDF, dan seterusnya), bertahap menurut pemakaian | tiap tool punya tes di Core |
| 5 | Recipes, riwayat dengan undo, pembaruan | paritas dengan Windows |

## Jebakan yang sudah diketahui

- **Izin Accessibility hilang tiap build.** Tanda tangan ad-hoc berubah pada setiap build, jadi macOS menganggapnya app baru dan izin Accessibility atau Input Monitoring untuk gestur global harus diberikan ulang. Saat mengembangkan Fase 3, tandatangani dengan sertifikat lokal yang stabil. Ini belum jadi soal sebelum Fase 3.
- **Helper bertanda sandbox-inherit tidak bisa dijalankan sendiri.** Itu kasus di Tangerine; PomeloO tanpa sandbox tidak punya batasan ini. Jangan meniru entitlement itu.
- **Mengubah isi `.app` setelah ditandatangani merusak segelnya.** Jalankan `make-app.sh` lagi, jangan mengedit bundle.
- **Peringatan Gatekeeper** saat membuka DMG pertama kali sudah tercatat di `mac/docs/install.md` dan belum diuji.
- **Build ini hanya arm64.** Tidak ada slice Intel; `make-app.sh` menolak executable tanpa arm64.
