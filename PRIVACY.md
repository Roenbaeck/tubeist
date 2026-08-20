# Privacy Policy for Tubeist

**Effective Date:** 2026-08-19

Thank you for using Tubeist. This policy explains what the app processes, where
that data goes, and what the developer of Tubeist collects.

**No Personal Data Collection**

The developer of Tubeist does not operate an analytics, advertising, streaming,
or account server and does not receive personal data from the app. In particular,
the developer does not collect your:

* Name
* Email address
* Phone number
* Location data
* Device identifiers (e.g., UDID, IMEI)
* Usage or diagnostic data tied to you

**How the App Functions**

Tubeist processes camera video, microphone audio, effects, and overlays on your
device. When you start streaming, it sends the resulting media directly to the
YouTube ingestion endpoint identified by the HLS stream key you entered. When
recording is enabled, Tubeist also writes a media file to the app's local
Documents storage. The developer does not receive either stream or recording.

Your YouTube stream key and OAuth access/refresh tokens are stored in the iOS
Keychain. Non-secret app configuration is stored in local preferences. Tubeist
does not upload those values to the developer.

**Third-Party Services**

Tubeist can interact with services you choose:

* **YouTube and Google:** Streaming sends video/audio and technical request data
  directly to YouTube. Optional Google sign-in allows Tubeist to read and update
  YouTube broadcast settings using the permissions shown during authorization.
  Google's privacy policy governs that processing.
* **Web Overlay Services:** If you add a web overlay URL, Tubeist loads that page
  so it can be composited into the video. The overlay provider can receive normal
  web-request information and may use its own cookies or storage. Its policy
  governs that processing.
* **Apple:** App Store distribution, in-app purchases, TestFlight, and operating
  system services are governed by Apple's policies.

**We have no control over the data collection practices of these third-party services.**  It is your responsibility to review their privacy policies.

**Retention and Deletion**

Tubeist does not add developer-operated tracking or advertising identifiers.
User-selected web overlays and Google's authorization page may use their own web
storage or cookies.

Local recordings remain on your device until you export or delete them. You can
remove the stream key in Settings and sign out of YouTube to delete Tubeist's
stored credentials. You can revoke Tubeist's Google access from your Google
account. Deleting the app removes its local files and preferences; iOS manages
Keychain-item deletion according to platform behavior.

**Children's Privacy**

Tubeist is not directed to children under 13, and the developer does not knowingly
collect personal information from children.

**Changes to This Privacy Policy**

This policy may change as Tubeist changes. The effective date above identifies
the current version.
