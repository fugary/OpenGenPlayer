# GenPlayer Localization Workflow

## Scope

The main localization files live under:

- `GenPlayer/Source/Resources/en.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/zh-Hans.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/zh-Hant.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/ja.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/ko.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/fr.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/de.lproj/Localizable.strings`
- `GenPlayer/Source/Resources/es.lproj/Localizable.strings`

## Project Policy

- New or changed user-visible text must use `NSLocalizedString`.
- At minimum, English and Simplified Chinese must be updated together.
- If other locale files ship in the app, update them with readable translations in the same change.
- Do not rely on English fallback for shipped locales, except for canonical names and technical abbreviations that intentionally stay unchanged across languages.

## Recommended Workflow

1. Confirm meaning from the calling view.
2. Update English wording if needed.
3. Update Simplified Chinese.
4. Update Traditional Chinese.
5. Translate the remaining shipped locales.
6. Run the consistency checker.

## Review Checklist

- Is the copy appropriate for the specific control type?
- Is destructive wording explicit enough?
- Does the string preserve distinctions such as `download` vs `cache` and `View Details` vs `Show in Folder`?
- Are English and Simplified Chinese semantically aligned rather than mechanically mirrored?
- Are `ja` / `ko` / `fr` / `de` / `es` actually translated instead of silently inheriting English?
