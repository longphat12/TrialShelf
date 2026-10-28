# TrialShelf

TrialShelf is a standalone macOS app for organizing files into shareable ZIP packages and scheduling `.sh` scripts.

## Use

1. Open `build/TrialShelf.app` and create a top-level folder.
2. Use the folder's **⋯** menu to create subfolders, upload files, or import a folder. The full folder tree and its files stay visible on one page. Only `.sh` files prompt for a number of days and are scheduled to run.
3. Use a folder's **⋯** menu to export that folder and its descendants as a ZIP, ready to share.

The app stores its catalog at `~/Library/Application Support/TrialShelf/catalog.json` and package files in its private `Files` folder. The interface and exported ZIP omit source paths. Removing an entry deletes the stored copy; the original file remains untouched. Select a supported script and choose **Run** to execute the stored copy; output and exit status appear in the app. Scripts run with the current user's permissions and their package folder as the working directory. Expired files run automatically once when due, and TrialShelf registers to launch at login so it can check after macOS starts. If an automatic run fails, use **Run** to retry. Folder imports skip hidden files and application package contents.

## Build

Run `./build.sh` on an Apple Silicon Mac with Xcode Command Line Tools. The app bundle is created in `build/TrialShelf.app` and a ZIP in `dist/TrialShelf-arm64.zip`.
