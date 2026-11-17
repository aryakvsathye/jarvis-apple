# Changelog

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
