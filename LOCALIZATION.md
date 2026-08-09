# Localizing Kero

Kero follows the macOS language selected by the user, including the per-app
language in System Settings. Users can also choose a language from
**Kero → Settings → Appearance → Language**; Kero asks to relaunch so native
menus, dialogs, and SwiftUI views all change together. English is the
development language. The currently maintained localizations are:

| Language | Identifier |
| --- | --- |
| English | `en` |
| Chinese (Simplified) | `zh-Hans` |
| Japanese | `ja` |

## Translate existing text

Open `kero.xcodeproj` in Xcode, select `Localizable.xcstrings`, choose a
language, and edit its translation. Xcode keeps placeholders, plural variants,
and translation state visible. The other catalogs cover macOS-owned UI:

- `InfoPlist.xcstrings` — privacy permission text.
- `ServicesMenu.xcstrings` — Kero’s Finder Services menu item.

Keep placeholders such as `%@` and `%lld` intact. Preserve product and
technology names such as Kero, Git, Finder, and VS Code, as well as keyboard
shortcut symbols. Translation-only pull requests are welcome.

For work outside Xcode, use **Product → Export Localizations…** to produce
XLIFF, then **Product → Import Localizations…** when the translation is ready.
XLIFF is the easiest way to send a language to a translator without exposing
the source code.

## Add a language

1. In the project editor, add the language under **Info → Localizations**.
2. Add that language to all three String Catalogs.
3. Translate every entry, including plural variants and the privacy prompt.
4. Run the app in that language and check menus, settings, the sidebars,
   dialogs, and `kero +themes`.
5. Add the language and identifier to the table above.

## Add localizable text in Swift

SwiftUI string literals are extracted automatically:

```swift
Button("Create New Branch…") {
    createBranch()
}
```

When an API requires a runtime `String`, use `String(localized:comment:)`.
Describe placeholders in the comment when their meaning is not obvious:

```swift
let message = String(
    localized: "Choose the directory for “\(project.name)”.",
    comment: "The placeholder is the project name."
)
```

Use complete sentences instead of assembling translated fragments. Put
count-dependent grammar in a plural variant in `Localizable.xcstrings`. Mark
user content, file names, terminal output, and other non-language data as
verbatim so it is not treated as a lookup key:

```swift
Text(verbatim: file.path)
```

The build has string extraction enabled. After adding source text, build once,
then translate the new entry in `Localizable.xcstrings`.

## Test a localization

In Xcode, choose **Product → Scheme → Edit Scheme… → Run → Options**, then set
**App Language** and **App Region**. Test English, Simplified Chinese, and
Japanese independently. Also use the in-app picker to switch between all four
options and confirm that **System Default** follows the user’s macOS preference
after relaunch.
