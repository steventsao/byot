# Composer voice dictation

The microphone button in the composer turns speech into message text with
Apple's Speech framework. It works the same on v1 and v2 servers because
nothing reaches the server until the message is sent. OpenCode's TUI and web
app have no dictation of their own (the web app only probes for the browser's
`SpeechRecognition`), so this follows iOS conventions rather than upstream.

## Using it

- The microphone sits beside Send, in both the one-row and the expanded
  composer. Shell mode hides it, since commands are typed exactly.
- The first tap asks for Microphone, then Speech Recognition. If either was
  refused earlier, an alert explains which and offers Settings (or says it is
  restricted, when Screen Time or a profile blocks it) and nothing is recorded.
- While listening, a header above the message shows a live level, whether the
  audio "Stays on this device" or is "Transcribed by Apple", and Done.
- Words stream into the draft after anything already typed, with one space.
  Mid-sentence, the recognizer's sentence capital is lowered ("Please fix…");
  "I", acronyms and names like "OpenCode" keep their case.
- Dictation ends, keeping every word so far, on Done or a second tap of the
  microphone, after 15 seconds without new words, when the person types or
  edits, on Send, on entering shell mode, when the app goes to the background,
  and on an audio interruption (a call, Siri, headphones connected or removed).
  After Done the recognizer's final wording, usually with punctuation, replaces
  the live text; if it does not arrive within two seconds the live text stands.

## Privacy

Recognition requires on-device processing whenever `SFSpeechRecognizer`
supports it for the device language; only otherwise does Apple's speech
service transcribe, and the header says so. Audio runs only between the tap
and the end of dictation, is never stored, and is never sent to the OpenCode
server; the transcript is ordinary draft text until Send. Project, agent and
model names are passed as contextual strings to improve recognition.

## Accessibility

- VoiceOver: "Dictate" / "Stop dictation" with hints; with VoiceOver running,
  listening starts after a short "Listening" announcement so the screen
  reader's speech isn't transcribed into the message.
- Accessibility text sizes wrap the header and give Done its own row; all
  controls keep 44 pt targets.
- Reduce Motion stops the microphone pulse and holds the level bars still.
- Start and stop play the system start/stop haptics.

## Testing

`OpenCodeDictationTests` drives the controller against a fake engine
(permissions, streaming, edits, Done, timeouts, failures, the level meter).
`OpenCodeDictationUITests` launches with `--dictation-fixture`, a DEBUG-only
scripted engine, to check the composer in light, dark and AX XXXL. Real speech
needs a device: dictate a sentence, pause, tap Done, and check the final text,
then repeat after denying Microphone in Settings.
