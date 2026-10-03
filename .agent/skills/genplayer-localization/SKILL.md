---
name: genplayer-localization
description: Translate, review, and maintain GenPlayer localization files with consistent product terminology, fallback behavior, and language coverage rules. Use when Codex needs to add or revise user-facing copy in `Localizable.strings`, audit locale coverage, or keep GenPlayer UI wording aligned across Simplified Chinese and English before propagating to other locales.
---

# GenPlayer Localization

Use this project-local skill to keep GenPlayer UI copy accurate, consistent, and reviewable across languages.

This copy is the repository-owned source of truth for localization workflow. The global skill in `~/.codex/skills` may exist for auto-discovery convenience, but localization work for this repo should follow this project copy first.

## Quick Start

1. Read `AGENTS.md` and `.agent/workflows/development-guide.md`.
2. Read:
   - `references/genplayer-localization-workflow.md`
   - `references/genplayer-terminology.md`
3. Inspect the target entries in:
   - `GenPlayer/Source/Resources/en.lproj/Localizable.strings`
   - `GenPlayer/Source/Resources/zh-Hans.lproj/Localizable.strings`
4. Read the calling Swift file if wording depends on UI context.
5. For multi-key work, run:

```powershell
python .agent/skills/genplayer-localization/scripts/check_localizable_consistency.py --project-root .
```

## Core Rules

- Treat `en.lproj` as the canonical key set unless the user explicitly says otherwise.
- Treat English and Simplified Chinese as the primary authoring pair.
- Never add a user-visible key to only one locale.
- All shipped locales in this repo are expected to carry readable translations; do not leave non-primary locales on English fallback unless the user explicitly approves a temporary exception.
- Keep `download`, `offline`, and `cache` as distinct concepts.
- Keep file-navigation and library-navigation wording distinct.
- Keep brand and protocol names canonical: `GenPlayer`, `Jellyfin`, `Emby`, `Plex`, `WebDAV`, `SMB`.
- Allow unchanged source terms only for canonical brand/protocol names and widely accepted technical abbreviations such as `PIN`, `4K`, and codec names.

## Default Update Order

1. `en.lproj`
2. `zh-Hans.lproj`
3. `zh-Hant.lproj`
4. `ja`, `ko`, `fr`, `de`, `es`（逐项完成可读翻译，不用英文占位）

## Reporting

When finishing localization work:

- summarize wording decisions
- call out any locales still containing English carry-over that need follow-up
- mention whether the consistency checker was run
- mention when no app build was needed because only resources or docs changed
