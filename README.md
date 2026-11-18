# JARVIS for iPhone

The iPhone app for JARVIS, the private assistant on the Mac. It talks only to JARVIS's own address on the tailnet.
(The Apple Watch app and the Live Activity come next.)

## What it does

- **Pairing, once.** On JARVIS's page: ⋯ → Pair the iPhone App, confirm with your passkey, and type the address and code it shows into the app. The app makes a key in the phone's Secure Enclave and signs every request with it; the key never leaves the phone. (Passkeys aren't used inside the app: they need Apple's servers to reach JARVIS's address, which is only on your tailnet.)
- **The orb.** Tap to talk. It listens until a 10-second pause, answers aloud (through AirPods when they're in), and listens again; tap to end. Typing works too.
- **Stand by for "JARVIS".** ⋯ → Stand By for "JARVIS": the app listens for his name, recognised on the phone itself (nothing goes anywhere until you've said it), and starts a conversation when it hears it; when the conversation ends, it stands by again. It stays on across launches and works with the app in the background (iOS shows the orange microphone dot while it listens). It uses more battery: switch it off from the same menu. Needs on-phone speech recognition (iOS asks the first time).
- **Your voice, on this phone.** JARVIS keeps a voiceprint per device. The first time you talk in the app, it asks to be taught: eight short phrases.
- **Talk to JARVIS from anywhere.** "Hey Siri, JARVIS" (or "Talk to JARVIS"), and the same shortcut for Back Tap: Settings → Accessibility → Touch → Back Tap → Double Tap → Talk to JARVIS. Control Centre and Lock Screen buttons can use it from the Shortcuts app; built-in ones come with the next version.
- **The Duo.** Folded, the orb sits above the conversation; unfolded, side by side.
- **The car.** JARVIS is the only app that talks to the car's OBD-II adapter (a Vgate iCar Pro 2S). Set it up once with the car on: ⋯ → Car → Set Up the Adapter, and choose it (it's called something like "IOS-Vlink"). First stop Pelican connecting to it, and don't pair it in iOS's Bluetooth settings. From then on iOS connects to it by itself whenever the car is on, even with the app closed, and JARVIS reads the speed, fuel level, engine temperature, battery voltage and any trouble codes. When you switch off, the trip goes to JARVIS on the Mac (one that can't be sent yet waits for the next). No position is sent. Ask "how's my car?" or "how far did I drive?"

## Building

The Xcode project is made from `project.yml` by XcodeGen, on the Mac and in Xcode Cloud (`ci_scripts/ci_post_clone.sh`), so it isn't kept in git.

One-time setup on the Mac:

**The quick way:** `~/jarvis-apple/scripts/rebuild.sh`. It pulls the latest from GitHub, makes the project, builds, signs, installs on the phone (unlocked, by cable or on the same Wi-Fi) and opens JARVIS. Run it again whenever you merge an app PR, and every 7 days while on free signing. `--open` opens Xcode instead; `--team` chooses the signing team again.

**By hand:**
1. `brew install xcodegen`, then in this repo: `xcodegen` and `open JARVIS.xcodeproj`.
2. In Xcode, select the JARVIS target → Signing & Capabilities → Team: your team. (`DEVELOPMENT_TEAM` in `project.yml` holds the team ID, so Xcode Cloud signs with it too.)
3. Product → Xcode Cloud → Create Workflow. Start condition: changes to `main`. Action: Archive, iOS. Post-action: TestFlight Internal Testing, to a group with you in it. Xcode creates the app in App Store Connect if it isn't there.
4. On the phone, install TestFlight, accept the invitation, and turn on **Automatic Updates** for JARVIS. From then on, every merge to `main` is built and installed on your phone without you doing anything.

## Versions

`VERSION` and `MARKETING_VERSION` in `project.yml` move together; Xcode Cloud numbers each build itself.
