# Reading for iPad

A native iPad app version of the reader, with an on-device AI (Gemma 4 E2B via llama.cpp) that explains pages offline.

## One-time setup (not in git — too big)
- `Vendor/build-apple/llama.xcframework`: from the llama.cpp release `b12211` asset `llama-b12211-xcframework.zip`.
- `Models/gemma-4-E2B-it-Q4_0.gguf` (2.8 GB): https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF
- `brew install xcodegen`, then `xcodegen generate` to make `Reading.xcodeproj`.

## Install on the iPad
1. Plug the iPad in, tap Trust, turn on Settings → Privacy & Security → Developer Mode.
2. Build & install: `xcodebuild -project Reading.xcodeproj -scheme Reading -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build`
   then `xcrun devicectl device install app --device <UDID> build/.../Reading.app` (or press Run in Xcode).
3. Copy the model into the app once (it survives app updates):
   `xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier com.aleksanderstevens.reading --source Models/gemma-4-E2B-it-Q4_0.gguf --destination Documents/Models/gemma-4-E2B-it-Q4_0.gguf`
   (Or Finder → iPad → Files → Reading, drag the .gguf in.)

## Notes
- The iPad Pro 2020 (A12Z) GPU is too old for llama.cpp's GPU path, so the model runs on the CPU (`GGML_METAL_DEVICES=0`).
- The llama.cpp framework has no simulator build: in the simulator the app works but the Explain panel says the AI isn't available.
- Debug launch options: `-importPath <pdf>`, `-openFirst YES`, `-startPage N`, `-showExplain YES`, `-showUI YES`.
