# Analisis Tangerine untuk Mac: struktur dan alur

Dokumen ini mencatat hasil analisis terhadap **Tangerine 2.0.3** yang terpasang di `/Applications/Tangerine.app`.
Tujuannya memahami arsitektur dan alur kerjanya sebagai bahan banding untuk PomeloO di Mac.
Ini bukan panduan untuk menyalin Tangerine. Jangan menyalin kode, skrip Perl atau JavaScript, template, aset, atau teks UI dari Tangerine ke PomeloO. Itu karya pihak lain, sedangkan PomeloO berlisensi AGPL-3.0.

Analisis dilakukan pada 2026-11-01 dengan dua cara:

- **REA** (Reverse Engineer Anything, server MCP `rea`): inventaris bundle, metadata Mach-O, dan Evidence yang bisa diperiksa ulang.
- **SRE** (reverse engineering statis lanjutan): Ghidra 12.2 headless, `otool`, `strings`, dan pemindai sendiri atas disassembly. Ditambah observasi runtime berupa argumen proses anak yang ditangkap saat Tangerine mengonversi file.

## Cara membaca dokumen ini

Setiap klaim diberi salah satu label:

- **[TEROBSERVASI]**: dibaca langsung dari artefak (file, metadata, string, instruksi) atau ditangkap saat berjalan.
- **[INFERENSI]**: disimpulkan dari bukti tidak langsung, misalnya nama tipe, string, dan resource. Bisa keliru.
- **[TIDAK DIKETAHUI]**: tidak berhasil dipastikan oleh analisis ini.

Analisis ini statis dan sebagian kecil runtime. Alur kode di dalam binary tidak dijalankan langkah demi langkah, dan binary tidak didekompilasi menjadi sumber yang bisa dibaca. Semua hal di luar yang tercatat di bagian "Yang tidak diketahui" belum diperiksa.

---

## 1. Identitas

| Hal | Nilai | Label |
|---|---|---|
| Bundle ID | `com.th.Tangerine` | TEROBSERVASI |
| Versi | 2.0.3 (build 10) | TEROBSERVASI |
| Distribusi | Mac App Store (ada `_MASReceipt`, ditandatangani "Apple Mac OS Application Signing") | TEROBSERVASI |
| Team ID | `GTF45UH2VQ` | TEROBSERVASI |
| Binary | satu Mach-O arm64, 11.629.680 byte, SHA-256 `48cc4e09a274a832a26f6f429fd46e61af83d4db2a716cd8d519315720244d5a` | TEROBSERVASI |
| UUID Mach-O | `6DE95636-B8F8-3B17-AC9D-D57A07456B70` | TEROBSERVASI |
| Arsitektur | hanya arm64, tanpa slice Intel | TEROBSERVASI |
| macOS minimum | 13.0 | TEROBSERVASI |
| Dibangun dengan | Xcode 27A266a, SDK `macosx27.0`, macOS build mesin `26A428` | TEROBSERVASI |
| Kategori | `public.app-category.utilities` | TEROBSERVASI |
| Tipe aplikasi | `LSUIElement=true`: tidak muncul di Dock, hidup di menu bar | TEROBSERVASI |
| Bahasa | Swift dengan SwiftUI dan AppKit, ditambah sedikit Objective-C | TEROBSERVASI |
| Biner di-strip | hanya 1 simbol yang dikenali `nm`; nama fungsi Swift hampir tidak ada | TEROBSERVASI |

### Entitlements dan sandbox

Hak akses yang diberikan ke binary utama, dibaca dengan `codesign`:

- `com.apple.security.app-sandbox` = true
- `com.apple.security.network.client` = true
- `com.apple.security.files.user-selected.read-write` = true
- `com.apple.security.files.bookmarks.app-scope` = true
- `com.apple.application-identifier` = `GTF45UH2VQ.com.th.Tangerine`
- Hardened runtime aktif.

**[TEROBSERVASI]** Tidak ada akses jaringan masuk, tidak ada akses folder tanpa pilihan pengguna, dan tidak ada entitlement `get-task-allow`. Dampaknya: Tangerine hanya bisa menyentuh file yang dipilih pengguna (atau folder yang disimpan sebagai bookmark), dan binary-nya tidak bisa di-debug langsung dengan LLDB.

### Privacy manifest

`Resources/PrivacyInfo.xcprivacy` **[TEROBSERVASI]**:

- Tracking: tidak ada, tanpa domain tracking.
- Data yang dikumpulkan: satu jenis, riwayat pembelian (`PurchaseHistory`), untuk fungsi aplikasi.
- API yang diakses: UserDefaults (alasan `CA92.1`), system boot time (`35F9.1`), file timestamp (`3B52.1`, `C617.1`).

Ini hanya deklarasi pengembang, bukan bukti perilaku.

---

## 2. Struktur bundle

```
Tangerine.app/Contents
├─ Info.plist, PkgInfo
├─ MacOS/Tangerine                  inti Swift, arm64, stripped
├─ _CodeSignature/, _MASReceipt/
└─ Resources/
   ├─ Tools/
   │  ├─ ffmpeg                     helper, arm64, sandbox inherit
   │  ├─ cwebp                      helper
   │  └─ licenses/{ffmpeg,lame,opus,libvpx,libwebp}
   ├─ ExifTool/
   │  ├─ tangerine_metadata.pl      jembatan baca/edit metadata
   │  ├─ tangerine_privacy.pl       penghapusan metadata gambar
   │  ├─ lib/{File,Image}/...       distribusi ExifTool (Perl)
   │  └─ README, Artistic.txt
   ├─ PowerPoint/
   │  ├─ arm64/ , x86_64/           masing-masing satu JRE lengkap (bin, lib, conf, legal, release)
   │  └─ lib/*.jar                  Apache POI + PDFBox + tangerine-powerpoint.jar
   ├─ OfficePreview.js              188.843 byte
   ├─ PagesWriter.js                694.646 byte
   ├─ PagesTemplate.pages           82.768 byte
   ├─ Assets.car                    3.324.536 byte
   ├─ AppIcon.icns, HighlightSound.{mp3,wav}
   ├─ PrivacyInfo.xcprivacy
   ├─ RevenueCat_RevenueCat.bundle  resource SDK pembelian
   └─ CupertinoFiles-Licenses.txt, OfficePreview-Licenses.txt
```

Inventaris REA: 529 entri, 59 file diprobe, 36 symlink tidak diikuti, nol entri khusus. Tidak ada kandidat Electron, .NET, Unity, atau Godot **[TEROBSERVASI]**.

### Isi `tangerine-powerpoint.jar` dan library Java

**[TEROBSERVASI]** Jar milik Tangerine hanya berisi `TangerinePowerPoint.class`, `TangerineSpreadsheet.class`, dan beberapa kelas dalam (`DelimitedSheetWriter`, `PositionStripper`, `Piece`, `SizeForIndex`). Pustaka di sampingnya: Apache POI 5.5.1 (`poi`, `poi-ooxml`, `poi-ooxml-lite`, `poi-scratchpad`), PDFBox 3.0.6 (`pdfbox`, `pdfbox-io`, `fontbox`), `xmlbeans` 5.3.0, `commons-*` (lang3, io, codec, compress, collections4, math3, logging), `curvesapi`, `graphics2d`, `SparseBitSet`, `log4j-api`.

**[INFERENSI]** Folder `x86_64/` kemungkinan tidak terpakai, sebab binary utama hanya arm64. Itu sisa dari pembangunan lintas arsitektur dan menambah ukuran bundle.

### Framework yang di-link (57 dependensi)

**[TEROBSERVASI]** Yang paling menunjukkan fungsi:

- Dokumen dan gambar: PDFKit, Vision, ImageIO, CoreImage, CoreGraphics, CoreText, Quartz.
- Media: AVFoundation, AVKit, CoreMedia, QuickLookUI, QuickLookThumbnailing.
- Skrip dan web: JavaScriptCore, WebKit.
- Pembelian dan iklan: StoreKit, `_StoreKit_SwiftUI` (weak), AdServices.
- Sistem: ServiceManagement (login item), IOKit, Security, CryptoKit, Combine.
- UI: SwiftUI, AppKit.
- Swift runtime: `libswiftCore`, `libswift_Concurrency`, dan overlay Swift untuk framework di atas.

---

## 3. Struktur kode (dari metadata dan string)

Binary di-strip, jadi nama di bawah dikumpulkan dari string, metadata tipe Swift, dan path file sumber yang tertinggal. Nama kelas bisa saja bukan nama persis di sumber.

### File sumber yang tertinggal di binary

**[TEROBSERVASI]** Path relatif di dalam target `Tangerine/`:

`AnnotationEditorView`, `ConversionOverlay`, `ConversionTaskStore`, `DocumentConverter`, `Morph/DocumentConverter`, `DragGestureMonitor`, `FileClipboardController`, `FileMoveAction`, `FileToolOptionsModel`, `FloatingFileWindowController`, `FolderAccess`, `GeneratedAssetSymbols`, `LoginItemController`, `MenuBarController`, `OperationProgressWindowController`, `PDFAnnotationTransplant`, `PaywallWindowController`, `Purchases`, `QRCodeResultsWindowController`, `ReviewRequestController`, `SettingsWindowController`, `TerminalFileAction`, `Unlock`, `WelcomeModel`, `WelcomeView` (semua berekstensi `.swift`).

Ada dua `DocumentConverter.swift`, satu di folder `Morph/`. **[INFERENSI]** `Morph` kemungkinan nama modul atau subsistem konversi.

### Kelompok tipe

**[TEROBSERVASI]** (nama; fungsi di kolom kanan adalah **[INFERENSI]**)

| Kelompok | Nama yang ditemukan | Perkiraan fungsi |
|---|---|---|
| Jendela dan kontroler | `MenuBarController`, `FloatingFileWindowController`, `FloatingQuickLookController`, `FileToolOptionsWindowController`, `OperationProgressWindowController`, `QRCodeResultsWindowController`, `SettingsWindowController`, `WelcomeWindowController`, `PaywallWindowController`, `LoginItemController`, `ReviewRequestController`, `AirDropSharingController`, `ConversionOverlayController`, `FileClipboardController` | siklus UI aplikasi menu bar |
| Panel melayang | `FloatingFilePanel`, `FloatingFileItem`, `FloatingFileGroupModel`, `FloatingTab*` (Edge, File, Layout, Material, Placement, Presentation, ResizeMotion, Shape, StackPreview, ViewMode, GlassBackground), `FloatingPaperClip*`, `FloatingRubberBandSelection*`, `FloatingThumbnail`, `FloatingFileDragSourceView`, `FloatingWindowDragRegion`, `FloatingFileContextMenuController` | rak file melayang seperti "tab" dengan tampilan kaca, seret keluar, dan pilih dengan rubber band |
| Konversi | `DocumentConverter`, `ArchiveConverter`, `EPUBConverter`, `PDFOfficeConverter`, `SubtitleConverter`, `EPUBPDFRenderer`, `ConversionTaskStore`, `OperationDispatcher`, `OperationDispatcherWorkerQueue`, `FileToolOptionsModel` | pemilihan mesin dan penjadwalan konversi |
| EPUB | `EPUBBook`, `EPUBPackage`, `EPUBLayout`, `EPUBZIP`, `EPUBBlockingResult` | parser EPUB sendiri |
| Kompresi | `ImageCompression`, `ImageCompressionOptions`, `ImageCompressionSize`, `ImageCompressionStrength`, `ImageJPEGCompress`, `CompressionSettingsEditor`, `CompressionModePicker`, `CompressionPresetChoice`, `CompressionTargetMode`, `CompressionLevel` | kompresi gambar dengan kualitas atau ukuran target |
| Redaksi | `RedactionCanvas`, `RectangleRedactionEditor`, `AudioRedactionEditor`, `RedactionRectangle`, `RedactionStyle`, `RedactionTimeRange`, `RedactionTrack`, `RedactionDeleteKeyHandler`, `PhotoRedactionDetectionKind` | menutup area gambar dan rentang audio atau video |
| Metadata | `MetadataEditorView`, `MetadataField` | edit dan hapus metadata |
| Anotasi PDF | `AnnotationEditorView`, `AnnotationKeyboardHandler`, `PDFAnnotationTransplant` | anotasi PDF dan pemindahan anotasi ke hasil konversi |
| Kode QR | `QRCodeResult`, `QRCodeResultsModel`, `QRCodeResultsPanel`, `QRCodeResultsView` | pembaca QR (Vision) |
| Akses file | `FolderAccessStore`, `FileMoveAction`, `TerminalFileAction`, `DeleteKeyMonitor`, `DragGestureMonitor` | bookmark folder sandbox, pindah file, buka di Terminal |
| Pembatasan pemakaian | `UnlockStore`, `UsageCountStore` (varian `DefaultsUsageCountStore`, `KeychainUsageCountStore`, `MirroredUsageCountStore`, `InMemoryUsageCountStore`), `PurchaseService`, `RevenueCatPurchaseService`, `UnavailablePurchaseService` | gratis terbatas, lalu paywall |

Banyak nama lain di binary (`OfferingsManager`, `CustomerInfoManager`, `RulesEngine`, `RemoteConfigManager`, `EventsManager`, dan seterusnya) milik **SDK RevenueCat**, bukan logika konversi Tangerine.

### Protokol milik Tangerine

**[TEROBSERVASI]** `LoginItemManaging`, `PurchaseService`, `UsageCountStoring`, `_ACResourceInitProtocol`. Pola ini menunjukkan penggunaan injeksi dependensi sederhana untuk pembelian dan penyimpanan hitungan pemakaian.

### Kunci pengaturan yang terlihat

**[TEROBSERVASI]** `toolsWheelDragModifierMask` dan `didMigrateToolsWheelToCommand`. **[INFERENSI]** ada "roda alat" yang dipanggil dengan menahan tombol modifier sambil menyeret file. Log dari kode memuat "Drag shortcut monitor started", jadi ada pemantau gestur seret global.

---

## 4. Helper dan cara dipanggil

### 4.1 ffmpeg dan cwebp

- **[TEROBSERVASI]** `Resources/Tools/ffmpeg` dan `Resources/Tools/cwebp` adalah Mach-O arm64 terpisah.
- **[TEROBSERVASI]** Entitlement ffmpeg: `app-sandbox` dan `inherit`. Dijalankan di luar Tangerine, ffmpeg mati dengan SIGTRAP (kode 133). Helper hanya berjalan sebagai anak proses app yang tersandbox.
- **[TEROBSERVASI]** Kode memuat path fallback `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, dan `/opt/homebrew/bin/cwebp` (alamat kode `0x10014232c`, `0x100142358`, `0x10019289c`; juga ada di `__DATA,__data` pada `0x100a39e50`/`0x100a3a148`). **[INFERENSI]** App mencari ffmpeg dan cwebp di Homebrew bila versi bundle tidak tersedia. Urutan pencarian persisnya tidak terbaca.
- **[TEROBSERVASI]** Encoder yang disebut di binary: `libmp3lame`, `libopus`, `libvpx-vp9`, `h264_videotoolbox`, `hevc_videotoolbox`. Lisensi yang dibawa: ffmpeg, lame, opus, libvpx, libwebp.

### 4.2 Argumen ffmpeg yang tertangkap saat berjalan

Ditangkap dari proses anak Tangerine dengan pemindai proses sendiri (membaca `KERN_PROCARGS2` tiap proses baru yang path-nya di dalam `Tangerine.app`). File masukan adalah file pribadi pengguna dan dihilangkan dari catatan ini.

**Tahap probe**, dijalankan tiga kali dengan argumen yang sama **[TEROBSERVASI]**:

```
ffmpeg -hide_banner -nostdin -y -i <input> -map 0:v? -map 0:a? -c copy -t 0 -f null -
```

Tidak menulis file. **[INFERENSI]** Hanya memeriksa stream video dan audio sebelum konversi.

**Video ke MP3** **[TEROBSERVASI]**:

```
ffmpeg -progress pipe:1 -nostats -hide_banner -loglevel error -y \
  -i <input.wmv> -map 0:1 -vn -c:a libmp3lame -b:a 256k \
  <folder-sumber>/.tangerine-<UUID>.mp3
```

- Progres dibaca dari stdout (`-progress pipe:1`).
- Hasil ditulis ke file tersembunyi `.tangerine-<UUID>.mp3` di folder yang sama dengan sumber.
- `-map 0:1` memilih stream audio berdasarkan indeks dari hasil probe, bukan `0:a`.

**PNG ke WebP** **[TEROBSERVASI]**:

```
ffmpeg -hide_banner -loglevel error -y -i <input.png> -frames:v 1 \
  -map_metadata 0 -c:v libwebp -quality 85 \
  <folder-sumber>/.tangerine-<UUID>.webp
```

Untuk kasus ini WebP dibuat oleh ffmpeg dengan `libwebp`, bukan oleh `cwebp`.

**Pola bersama** **[TEROBSERVASI]**: file sementara tersembunyi `.tangerine-<UUID>.<ext>` di folder sumber. **[INFERENSI]** Setelah sukses, file itu di-rename menjadi hasil akhir. Langkah rename tidak teramati.

Nilai `256k` dan `quality 85` adalah setelan untuk konversi yang dipilih saat itu. **[TIDAK DIKETAHUI]** apakah setelan lain di UI mengubahnya.

### 4.3 ExifTool lewat Perl sistem

- **[TEROBSERVASI]** `ExifTool/tangerine_metadata.pl` memuat distribusi ExifTool dari `ExifTool/lib`, dengan komentar "offline, fail-closed bridge to the unmodified ExifTool distribution". Ia memakai `JSON::PP`, `Digest::SHA`, `XML::Parser`, dan menambal penanganan maker note Apple (`LocateIFD`, `Image::ExifTool::Apple`) agar entri TIFF 64-bit tetap valid bila Make dihapus atau diedit.
- **[TEROBSERVASI]** `ExifTool/tangerine_privacy.pl` memberi komentar "Privacy-first image metadata removal. Keep encoded image samples intact." dan mem-parse kotak kontainer gambar (`size`, `type`, ukuran 64-bit) dengan batas ketat. Contoh pesan: "Image container is too large to clean safely", "Incomplete image container", "Unsupported image item layout".
- **[TEROBSERVASI]** Kode (`0x100147354`) memakai path `ExifTool/tangerine_metadata.pl` dan memiliki dua pesan galat berbeda, "Bundled ExifTool" dan "macOS Perl runtime".
- **[INFERENSI]** App memakai perl bawaan macOS (bukan perl yang dibawa app) untuk menjalankan skrip itu. Tidak pernah teramati saat runtime.

### 4.4 Java untuk PowerPoint dan spreadsheet

**[TEROBSERVASI]** Dua tempat di kode (`0x100073a58` dan `0x100086d38`) menyusun argumen JVM yang sama:

```
-XX:TieredStopAtLevel=1
-XX:ReservedCodeCacheSize=64m
-XX:+UseSerialGC
-XX:-UsePerfData
-Djava.awt.headless=true
-Djava.io.tmpdir=<direktori sementara>
```

Kelas yang dipanggil: `TangerineSpreadsheet` dan `TangerinePowerPoint`, dari `lib/tangerine-powerpoint.jar`. Nama folder runtime dalam kode: `Vendor/PowerPoint/PowerPoint`. Pesan terkait: "Bundled PowerPoint converter", "Bundled PowerPoint runtime". File keluaran sementara berawalan `Tangerine-powerpoint-output-<UUID>`. Setelah konversi ke PDF ada verifikasi, dengan galat "The converted PDF could not be verified."

**[INFERENSI]** Opsi JVM menunjukkan dioptimalkan untuk start cepat dan memori kecil, bukan throughput. **[TIDAK DIKETAHUI]** argumen lengkap (classpath, argumen kelas) dan urutan pemanggilannya.

### 4.5 JavaScript lewat JavaScriptCore

- **[TEROBSERVASI]** `PagesWriter.js` (hasil bundling, mem-polyfill `btoa`, `atob`, `TextEncoder`, `TextDecoder`, `crypto.getRandomValues` lewat fungsi native `tangerineRandomBytes`) dan `PagesTemplate.pages`.
- **[TEROBSERVASI]** `OfficePreview.js` (bundel hasil esbuild) dengan file lisensi `OfficePreview-Licenses.txt`.
- **[INFERENSI]** `PagesWriter.js` menulis dokumen `.pages` dari templat dan dijalankan di JavaScriptCore (framework di-link). `OfficePreview.js` merender pratinjau DOCX, XLSX, dan PPTX. Kemungkinan lewat WebKit. Keduanya tidak teramati saat berjalan.

### 4.6 Parser EPUB sendiri

**[TEROBSERVASI]** Dari pesan galat, parser EPUB melakukan pemeriksaan keamanan yang ketat:

- Menolak DTD dan deklarasi entity pada dokumen paket.
- Menolak symlink, nama file tidak aman, path arsip yang bentrok atau duplikat, dan path keluaran yang keluar dari workspace.
- Menolak EPUB terenkripsi atau dengan font yang di-obfuscate.
- Membatasi ukuran arsip, dokumen paket, bab fixed-layout, stylesheet, gambar, tabel, dan kedalaman blok.
- Merender dalam latar belakang dengan batas waktu ("EPUB rendering timed out") dan tanpa jaringan ("offline EPUB renderer").
- Memberi peringatan bila EPUB berisi media yang tidak bisa dipertahankan format dokumen yang bisa diedit.

**[INFERENSI]** EPUB dirender menjadi PDF (`EPUBPDFRenderer`), lalu diteruskan ke konverter lain.

### 4.7 Format yang tersirat

**[TEROBSERVASI]** string format di binary: `avif`, `heic`, `webp`, `tiff`, `docx`, `xlsx`, `pptx`, `pages`, `epub`, `html`, `opus`, `flac`, UTI `com.microsoft.powerpoint.ppt`. **[TIDAK DIKETAHUI]** peta lengkap format masukan ke keluaran. Konversi yang benar-benar diamati hanya audio dari video, dan PNG ke WebP.

---

## 5. Alur yang disimpulkan

Bagian ini **[INFERENSI]** yang disusun dari sumber di atas. Hanya langkah 4 untuk ffmpeg yang teramati langsung.

1. **Masuk.** App hidup di menu bar. File masuk lewat panel melayang (seret, clipboard file, Quick Look). Gestur seret global dipantau, dan ada "roda alat" yang bisa dipanggil dengan tombol modifier.
2. **Izin file.** Karena sandbox, folder yang disentuh disimpan sebagai bookmark (`FolderAccessStore`).
3. **Pilih operasi.** `FileToolOptionsModel` menampilkan opsi per jenis file. `OperationDispatcher` menjadwalkannya di worker queue, `ConversionTaskStore` menyimpan statusnya, dan overlay serta panel progres menampilkannya.
4. **Eksekusi.** `DocumentConverter` memilih mesin:
   - Audio dan video: ffmpeg, didahului probe `-c copy -t 0 -f null`; progres dari stdout; keluaran ke file `.tangerine-<UUID>.<ext>` di folder sumber **[TEROBSERVASI]**.
   - Gambar: ffmpeg `libwebp` untuk WebP **[TEROBSERVASI]**; ImageIO/CoreImage dan cwebp untuk jalur lain **[INFERENSI]**.
   - Metadata: skrip Perl ExifTool **[INFERENSI]**.
   - PPTX dan spreadsheet: JVM bawaan dan POI **[INFERENSI]**.
   - Pages: JavaScriptCore dan templat **[INFERENSI]**.
   - EPUB: parser sendiri lalu PDF **[INFERENSI]**.
5. **Hasil.** Salinan baru ("Save Redacted Copy", "Metadata Removed"), bisa dibagikan lewat AirDrop atau diseret keluar.
6. **Pembatasan.** `Unlock`/`Purchases` memakai StoreKit lewat RevenueCat. `UsageCountStore` (Defaults, Keychain, dan salinan cermin) membatasi pemakaian gratis, lalu muncul paywall. Teks "Unlimited conversions and tools" terlihat di binary.

---

## 6. Jaringan dan data

**[TEROBSERVASI]** URL non-Apple dan non-skema XML yang tertinggal di binary:

- RevenueCat: `api.revenuecat.com`, `api-diagnostics.revenuecat.com`, `api-paywalls.revenuecat.com`, `a.revenue.cat`, `api.rc-backup.com`, dan `api-production.8-lives-cat.io`.
- Situs pengembang: halaman privasi Tangerine.
- Apple: halaman langganan App Store dan EULA standar.

Tidak ada endpoint unggah file. **[INFERENSI]** Klaim "diproses lokal" konsisten dengan bukti ini, tapi lalu lintas jaringan tidak ditangkap, jadi ini bukan bukti perilaku. `Info.plist` memuat kunci SDK RevenueCat. Kunci itu publik menurut desain SDK dan sengaja tidak disalin ke dokumen ini.

---

## 7. Yang tidak diketahui

- **Alur kode di dalam binary.** Ghidra 12.2 menganalisis binary (38.240 fungsi terdeteksi) dan skrip ekspor saya tidak menghasilkan dekompilasi. Referensi string Swift lewat pasangan `adrp`+`add` tidak dibuat sebagai xref oleh Ghidra, dan string pendek disimpan sebagai nilai langsung di instruksi. Pelacakan saya akhirnya memakai pemindai sendiri atas disassembly `otool`, jadi hanya string panjang di `__cstring` yang terlacak.
- **Argumen cwebp, ExifTool, perl, dan Java.** Tidak teramati saat runtime. Konversi yang dijalankan hanya menyentuh ffmpeg.
- **Urutan pencarian helper** (bundle, lalu Homebrew, atau sebaliknya).
- **Peta lengkap format masukan ke keluaran.**
- **Perilaku UI**: isi pengaturan, urutan alur dari panel ke dialog opsi, dan batas pemakaian gratis.
- **Rename file sementara** menjadi hasil akhir dan penanganan bentrok nama.
- **Perilaku di Mac Intel**: binary arm64 saja.

### Kegagalan alat yang perlu diketahui

- REA tidak punya provider dekompilasi di mesin ini: Ghidra (`GHIDRA_INSTALL_DIR` kosong), Hopper, IDA, dan Kuna semuanya `not_configured` atau tidak ada. REA meminta Ghidra 12.1.x, sedangkan Homebrew menyediakan 12.2, jadi saya memakai `analyzeHeadless` langsung.
- `observe_native_calls` (LLDB) tidak bisa dipakai: runtime hardened tanpa `get-task-allow`.
- Tangerine tidak muncul di daftar aplikasi yang bisa dikendalikan lewat computer-use (aplikasi menu bar tanpa jendela biasa), jadi konversi dipicu manual oleh pengguna.
- Pemindai proses awal berbasis `ps` (50 ms) melewatkan proses ffmpeg yang hidup lebih singkat dari itu. Pemindai C yang membaca `KERN_PROCARGS2` dalam loop rapat menangkapnya, dengan menunggu proses anak selesai `exec`.

---

## 8. Metode dan bukti

### Evidence REA

Evidence berikut tersimpan di sesi REA saat analisis dan **tidak diekspor ke file**. Mereproduksinya berarti menjalankan ulang pemeriksaan.

- Inventaris direktori `Tangerine.app`: `ev_14234d9295d119b69e63913a414d92253c4c4f079456da35912b0d0d4ec74d7d` (induk `ev_3671c0ac5b09a5873517f6418917338de5170f7b2dcb9155acb8c49ed024d2cf`), SHA-256 direktori `99aea2ab…a60560`, cakupan lengkap dalam batas pindai.
- Metadata Mach-O: `ev_8d7009fe0d36a60dec787e174573ff71a22dfc4a0ea296f2b858de6e00a17c3c` (induk `ev_22975cecc527973863939b390aa86257db42f60a5c59d682a20da1ff27bd5c26`): 76 load command, 5 segmen, 57 dependensi, 3.294 impor yang tercatat (tidak dijamin lengkap).

### Perintah dan alat yang dipakai

- REA: `inspect_desktop_application` (ringkasan), `open_binary`, `inspect_macho` (ringkasan), `close_binary`. `analyze_swift_types` dan `binary_overview` gagal karena tidak ada provider.
- `codesign -dvv --entitlements -`, `otool -L`, `otool -l`, `otool -tvV`, `strings -a`, `nm -U`, `unzip -l` (pada jar), `file`.
- Ghidra 12.2 headless (`analyzeHeadless`, dipasang sementara lewat Homebrew), dengan dua skrip Java untuk ekspor fungsi dan pelacakan string. Hasilnya nol target dekompilasi.
- Skrip Python sendiri untuk memindai pasangan `adrp`+`add` atas keluaran `otool -tvV` dan menyelesaikan string di `__cstring`.
- Pemindai C sendiri (`libproc` + `sysctl KERN_PROCARGS2`) untuk menangkap argumen proses anak Tangerine.
- `log show` untuk memastikan ffmpeg berjalan (PID dan waktu) ketika pemindai awal gagal.

### Pengaman

- Tidak ada file di `/Applications/Tangerine.app` yang diubah. Binary disalin ke direktori sementara untuk Ghidra, dan direktori itu sudah dihapus.
- Tangerine hanya dijalankan dengan `open -a` dan dioperasikan oleh pengguna sendiri. Tidak ada proses yang diinjeksi atau di-debug.

---

## 9. Bahan banding untuk PomeloO

Bagian ini opini rancangan, bukan temuan bukti.

- **Helper terpisah per mesin.** Tangerine memakai ffmpeg, ExifTool, dan JVM sebagai proses anak yang mudah diganti dan diperbarui sendiri. Pola ini mirip yang bisa dilakukan PomeloO.
- **File sementara tersembunyi lalu rename** di folder sumber menjaga hasil yang belum selesai tidak terlihat dan memudahkan pembatalan.
- **Probe sebelum konversi.** Satu perintah `-c copy -t 0 -f null` murah dan menghindari kegagalan di tengah jalan.
- **Progres lewat `-progress pipe:1`** memudahkan bar progres yang akurat.
- **Parser berkas yang defensif.** Batas ukuran, penolakan DTD, dan penolakan path keluar workspace patut ditiru untuk format arsip.
- **Biaya bundle.** JRE dua arsitektur menambah ukuran. PomeloO perlu menimbang apakah konversi Office layak membawa runtime Java sendiri.
- **Sandbox Mac.** Helper bertanda `inherit` tidak bisa jalan di luar app. Pengujian helper secara terpisah perlu cara lain.
