# Changelog

## 0.4.0 (17 Nov 2026)
JARVIS reads your car: every trip, straight from the OBD-II adapter
- ⋯ → Car: choose the adapter once, with the car on. iOS then connects to it by itself whenever the car is on, even with the app closed
- While you drive, JARVIS reads the speed, fuel level, engine temperature, battery voltage, the check-engine light and any trouble codes; when you switch off, the trip goes to your Mac (needs JARVIS 0.11.0)
- A trip that can't be sent (no signal) waits and goes with the next one. No position is sent

## 0.3.2 (17 Nov 2026)
One command to get the latest app onto the iPhone
- scripts/rebuild.sh pulls from GitHub, makes the Xcode project, builds, signs, installs on the phone and opens JARVIS, without opening Xcode
- The signing team is found from the Mac's certificate (or asked once) and kept on the Mac, not in git; --open opens Xcode instead, --team picks the team again

## 0.3.1 (17 Nov 2026)
JARVIS gets ready as soon as you open the app
- Opening the app, or starting a conversation, asks JARVIS to load its brain and read the conversation while you're still talking, so the first answer after a quiet spell comes much sooner (needs JARVIS 0.9.1)

## 0.3.0 (17 Nov 2026)
Talk to JARVIS like a conversation: it knows when you've finished, and you can cut in
- Tap once and it listens; it ends your turn from your pause and whether what you said sounds finished (quick after a complete sentence, patient after "and" or "um"), answers, and listens again until you tap End
- Talk over JARVIS to interrupt: it stops, drops the rest of the answer and listens to you. Echo cancellation (iOS's voice processing, as in FaceTime) keeps its own voice out of the microphone
- Your words appear as you say them, recognised on the phone itself (never sent to Apple)
- Teach JARVIS your voice again once on this phone: the conversation microphone sounds different with echo cancellation

## 0.2.2 (17 Nov 2026)
JARVIS finishes his answer before you're asked to talk again
- A pause between two of his sentences no longer counts as the end of the answer, so the app stays "Speaking…" instead of flicking to "Tap to talk" (or listening) mid-answer

## 0.2.1 (17 Nov 2026)
Starting to listen no longer risks a frozen screen
- The audio session is set up and switched on off the main thread, as Xcode advised

## 0.2.0 (17 Nov 2026)
JARVIS always knows where you are, in the app
- Every question carries the phone's rough location (about a kilometre); the Mac turns it into a town and keeps only that
- Location permission is "Always": iOS's low-power significant-change tracking keeps a recent position ready, so questions don't wait for a fix ("where am I?" and the weather here still get a fresh one)

## 0.1.1 (16 Nov 2026)
The app builds without warnings
- Bluetooth headsets use the option's current name, and the request counter locks safely inside async code (Swift 6 ready)

## 0.1.0 (16 Nov 2026)
The first JARVIS app for iPhone
- Pair once with a code from JARVIS's page; every request is signed by a key in the phone's Secure Enclave
- Tap the orb to talk: it listens until a 10-second pause, answers aloud, and listens again
- Teach JARVIS your voice on this phone, in the app
- "Hey Siri, JARVIS" and Back Tap open it listening
- Laid out for the Duo, folded and unfolded
