# DCIM Rescue 📱➡️💻

Copy **all photos, videos and screenshots** from an iPhone to a Windows PC over a USB cable,
reliably. No iTunes, no cloud, no installation, just a double-click.

![DCIM Rescue window](docs/screenshot.png)

Windows' own "Import" and drag-and-drop in File Explorer tend to fail halfway through large
libraries (the phone locks, the connection drops, a 4 GB video times out) and then you don't
know what made it and what didn't. This tool fixes that:

- ✅ **Checks every file.** A file only counts as copied when its size on disk matches the phone.
- 🔁 **Retries failed files automatically** (5 times by default, with increasing pauses).
- 🔌 **Survives disconnects.** If the phone locks or the cable wiggles, it waits and carries on.
- ⏯️ **Resumes.** Run it again and it skips what's already there, copying only what's missing.
- 🔍 **"Check the copy" button.** Compares the phone and the folder file-by-file, copies nothing.
- 📊 Progress bar with speed (MB/s) and time left. Keeps the PC awake while copying.
- 📁 Keeps the phone's folder layout (`202506_a`, `202507_a`… or `100APPLE`… on older iOS).
- 📝 Writes a log (`iphone-copy-log.txt`) and a list of failed files (`iphone-copy-failed.txt`).
- Copies original files byte-for-byte: HEIC, JPG, PNG screenshots, MOV, MP4, Live Photo videos, AAE edit data.

## Requirements

- Windows 10 or 11 (uses the built-in PowerShell 5.1, so nothing to install)
- Apple's USB driver: install **[Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k)** from Microsoft Store (or iTunes)
- A Lightning / USB-C cable

## How to use

1. Download this repository (**Code → Download ZIP**) and unzip it anywhere.
2. Connect the iPhone, **unlock it** and tap **Trust** when asked.
3. *(Recommended)* On the iPhone set **Settings → Display & Brightness → Auto-Lock → Never** for the duration,
   and **Settings → Photos → Transfer to Mac or PC → Keep Originals**.
4. Double-click **`DCIM Rescue.bat`**.
5. Choose a folder and press **Start copying**. When it's done, press **Check the copy** to be sure.

If anything fails, just press **Start copying** again. Only missing files are copied.

### Command line

```powershell
# copy everything (default destination: Pictures\iPhone)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\iPhoneCopy.ps1 -Destination "D:\Photos\iPhone"

# only compare the phone with the folder
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\iPhoneCopy.ps1 -Destination "D:\Photos\iPhone" -Verify

# only count files and total size
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\iPhoneCopy.ps1 -ListOnly
```

| Option | Default | Meaning |
|---|---|---|
| `-Destination` | `Pictures\iPhone` | Where to save |
| `-MaxRetries` | `5` | Attempts per file |
| `-StallSeconds` | `90` | A copy that makes no progress for this long counts as failed and is retried |
| `-Verify` | | Compare only, copy nothing |
| `-ListOnly` | | Count files and size only |

Exit code is `0` when everything is copied / matches, `1` otherwise.

## FAQ

**The Photos app on my iPhone shows fewer items than the number of copied files. Is something wrong?**
No. A Live Photo is one item in the app but two files (photo + short `.MOV`), and `.AAE` files
(edit information) aren't shown in the app at all.

**Some photos are missing / the total is much smaller than my library.**
If **iCloud Photos** with **Optimize iPhone Storage** is on, many originals live only in iCloud and
the phone doesn't expose them over USB. Switch to **Download and Keep Originals**, wait for it
to finish, then run the copy again. Or use iCloud for Windows.

**It says "Can't see the iPhone's photos".**
Unlock the phone and tap **Trust**. If the phone doesn't appear in File Explorer at all, install
Apple Devices from Microsoft Store and reconnect the cable.

**I can't open `.HEIC` / `.MOV` files.**
Install **HEIF Image Extensions** and **HEVC Video Extensions** from Microsoft Store.

**Is it fast?**
It's as fast as the phone's USB connection allows (an iPhone 11 is USB 2.0: roughly 20–35 MB/s).
Use a USB 3 port and a good cable. ~55 GB / 6,700 files took about 50 minutes in testing.

## How it works

The iPhone shows up in Windows as an MTP device. The tool talks to it through the same shell
API as File Explorer (`Shell.Application`), lists every file with its exact size, and copies them
one by one with `CopyHere`. Because `CopyHere` is asynchronous and gives no error feedback, the tool
watches the destination file until it reaches the expected size and is no longer locked. A file that
stops growing for `StallSeconds` is treated as failed, the connection to the phone is re-established,
and the file is retried.

```
DCIM Rescue.bat           → starts the window
src/iPhoneCopyGUI.ps1     → Windows Forms UI (copy runs in a background runspace)
src/iPhoneCopy.ps1        → command-line version
src/iPhoneCopy.Core.ps1   → shared logic: device discovery, copy + retry, verify
```

Nothing is ever deleted from the phone. The tool only reads from it.

## License

[MIT](LICENSE)

---

### 🇵🇱 Po polsku w skrócie

Narzędzie kopiuje **wszystkie zdjęcia, filmy i zrzuty ekranu** z iPhone'a na komputer z Windows przez kabel.
Sprawdza rozmiar każdego pliku, przy błędzie ponawia kopiowanie, a po przerwaniu wznawia od miejsca, w którym skończyło.

1. Zainstaluj **Apple Devices** z Microsoft Store.
2. Podłącz iPhone'a, odblokuj go i kliknij **Zaufaj**.
3. Uruchom **`DCIM Rescue.bat`**, wybierz folder i kliknij **Start copying**.
4. Na koniec kliknij **Check the copy**, żeby porównać telefon z folderem.
