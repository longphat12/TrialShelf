# TrialShelf

TrialShelf is a macOS app for collecting copies of files in a folder hierarchy and exporting a folder as a ZIP archive. It can also run saved scripts on a schedule.

[Tiếng Việt](README.md)

## Requirements

- macOS 13 or later.
- Apple Silicon (arm64) for the current build.
- Xcode Command Line Tools to build from source.

## Install

1. Download `TrialShelf-arm64.zip` from Releases, or build it from source.
2. Extract the ZIP and move `TrialShelf.app` to Applications.
3. Open the app. Scheduled scripts and launch at login are off by default. Enable **Run scripts automatically when due** in the settings menu if you want that behavior.

The current package is ad-hoc signed and not notarized. Gatekeeper may block the first launch.

## Organize files

Create a top-level folder with **Create top-level folder**, then add nested folders with the folder's add-subfolder control. Add individual files or import a folder. TrialShelf skips hidden files, symbolic links, and the contents of app bundles.

TrialShelf stores its own copies in `~/Library/Application Support/TrialShelf/`. Editing or removing a managed copy does not change the source file. Adding the same source file to the same folder again does not create a duplicate.

Select a file to inspect it. **Show in Finder** reveals the managed copy; **Remove from catalog** deletes that copy and its entry while keeping the original source. Use the refresh control to update modification dates and availability.

## Export a ZIP

Choose the archive action next to a folder. The ZIP contains that folder and its nested contents. Choose the destination and archive name in the macOS save dialog. The folder must contain at least one file.

## Run scripts

Select a file and choose **Run** to run it manually. Supported extensions are `.sh`, `.command`, `.py`, `.swift`, `.rb`, and `.pl`. TrialShelf uses a valid shebang interpreter when present, otherwise it chooses the interpreter associated with the extension. Each run stops after 120 seconds, and displayed output is capped at 64 KiB.

When importing `.sh` files, TrialShelf asks how many days remain until the run date. Enter `0` to make it due immediately. Scripts run with the current user's permissions. Automatic script execution is disabled by default; enabling it also asks macOS to launch TrialShelf at login so due scripts can run while the app is closed. Only add and run scripts you trust.

## Data and privacy

No files are uploaded to an external service. Catalogs are stored in `catalog.json` and `packages.json`; managed copies are stored in `Files/` under the application support directory. Removing a folder in TrialShelf deletes the managed copies in that folder and its descendants. Original source files are kept.

## Build from source

On an Apple Silicon Mac with macOS 13 or later and Xcode Command Line Tools, run:

```sh
./build.sh
```

The script creates `build/TrialShelf.app` and `dist/TrialShelf-arm64.zip`.

## License

MIT. See [LICENSE](LICENSE).
