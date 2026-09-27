# Localization

byot is written in English and ships a Simplified Chinese (`zh-Hans`)
translation (#97). Strings live in String Catalogs under `Sources/Resources`:

| Catalog | Holds | Targets |
| --- | --- | --- |
| `Localizable.xcstrings` | App, widget and share-extension copy | BYOT, BYOTWidgets, BYOTShare |
| `InfoPlist.xcstrings` | Camera, microphone, speech and local network prompts | BYOT |
| `AppShortcuts.xcstrings` | Siri and Shortcuts phrases | BYOT |

`project.yml` turns on `SWIFT_EMIT_LOC_STRINGS` and
`LOCALIZATION_PREFERS_STRING_CATALOGS`, so every build extracts strings from
source. Building in Xcode adds new strings to the catalogs; XcodeGen picks the
languages up from the catalogs.

## Writing new copy

- SwiftUI literals (`Text("…")`, `Button("…")`, `Label("…", systemImage:)`,
  `.accessibilityLabel("…")`, `.navigationTitle("…")`) are already localized.
- Copy that travels as a `String` (error descriptions, status titles, values
  passed into helpers, `UIAccessibility` labels, announcements) must be built
  with `String(localized: "…")`. `Text(someString)` shows a `String` as is.
- Write whole sentences. Pick between full sentences for singular and plural
  (`count == 1 ? "1 file" : "\(count) files"`) instead of adding an "s", and
  don't join sentence fragments with `+`; word order differs between languages.
- Interpolate identifiers such as ports, status codes and line numbers as
  `\(String(value))`. A bare integer is formatted for the reader's locale, so
  4096 would read "4,096".
- Server data (session titles, file paths, model names, errors from OpenCode)
  is shown as sent.

## Updating the catalogs without Xcode

Build with the test helper, then sync the extracted `.stringsdata` files from
the app and both extensions:

```bash
B=<DerivedData>/Build/Intermediates.noindex/BYOT.build/Debug-iphonesimulator
xcrun xcstringstool sync Sources/Resources/Localizable.xcstrings Sources/Resources/AppShortcuts.xcstrings \
  --stringsdata $B/{BYOT,BYOTWidgets,BYOTShare}.build/Objects-normal/arm64/*.stringsdata
```

Sync marks strings no longer in source as stale; delete them once their
replacements are translated. `BYOTLocalizationTests` checks that every Chinese
string keeps its English placeholders.

## Chinese terminology

| English | 简体中文 |
| --- | --- |
| session | 会话 |
| turn | 轮次（“本轮”） |
| prompt | 提示词 |
| agent / subagent | 智能体 / 子智能体 |
| worktree / checkout | 工作树 / 检出 |
| compact | 压缩 |
| companion | 配套程序 |
| token | token |
| Copy / Save | 拷贝 / 存储 (Apple's terms) |

Use 你, full-width punctuation, and a space between Chinese and Latin text or
numbers.

## Left in English on purpose

- The Markdown transcript export uses the same headings as the OpenCode TUI's
  export, so files read the same wherever they were made.
- New terminals are titled "Terminal N" on the server, matching the web app.
- Push notification text comes from the relay worker in `push/`, which sends
  English today.
