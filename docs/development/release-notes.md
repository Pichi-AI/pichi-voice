# GitHub release notes

This guide owns the public release-description convention for Pichi Voice. The product owner confirmed English and Russian descriptions with clearly separated language sections on November 13, 2026. Keep the same format between releases; changing the app's interface language does not change the audience of its public release notes.

## One release, two languages

- Publish one release and one asset set for each version. Put both translations in that release's Markdown body. Do not create separate language tags, releases or installers.
- Use the title `Pichi Voice VERSION`, with the public version only. Follow the existing [version and distribution policy](macos-distribution.md#public-versions-and-compatibility).
- Start the body with links labelled `English` and `Русский`. Follow with visible `## English` and `## Русский` sections, in that order. Use version-scoped custom anchors so navigation also works on the page showing several releases.
- Keep both language sections expanded for the normal short release. Do not hide Russian in an unlabelled second paragraph or interleave translations sentence by sentence. For unusually long notes, labelled `<details>` sections are an option, but do not change the default format without a concrete reason.
- Use matching `What's new` / `Что нового` and `Install` / `Установка` subsections. Cover the same changes, requirements, limitations and installation facts in both languages. Translate meaning naturally; do not add unsupported claims to one translation.
- Lead with user-visible outcomes in short bullets. Include relevant limitations and migration steps. Keep internal build numbers, CI logs and implementation history out of the main narrative. Link to PRs or put necessary technical details after both language sections.
- Keep product/provider names, file names, tags, URLs and source identifiers exact. Use the same download files in both translations. Country flags are unnecessary for identifying a language.

GitHub's documented release model has one `body` string, not separate author-provided bodies selected by the visitor's locale. These navigation links select sections of the same description; they are not an automatic language switch. Browser translation is separate from the project's translations.

## Template

Replace `VERSION` in prose with the public version, such as `0.2.3`. Replace `VERSION-ANCHOR` with its hyphenated form, such as `0-2-3`. For historical tags sharing a public version, include the build or tag suffix in the anchor to keep it unique. Remove all placeholders before publication.

```markdown
[English](#release-VERSION-ANCHOR-en) · [Русский](#release-VERSION-ANCHOR-ru)

<a name="release-VERSION-ANCHOR-en"></a>

## English

### What's new

- Describe a verified user-visible change.

### Install

State the supported platform and installation or update steps.

---

<a name="release-VERSION-ANCHOR-ru"></a>

## Русский

### Что нового

- Опишите то же подтверждённое изменение для пользователя.

### Установка

Укажите ту же поддерживаемую платформу и порядок установки или обновления.

---

**Changes / Изменения:** links to the relevant pull requests.
```

## Publication and corrections

The release helper's generic draft description is a placeholder. Prepare the bilingual body in a private operator file outside the four public release assets, then apply it to the owned draft before publication, for example with `gh release edit TAG --repo Pichi-AI/pichi-voice --notes-file /absolute/path/notes.md`. Continue publishing through the existing helper and its publication lock. This convention adds no parallel release mechanism.

Before publication, check both translations, anchors, rendered headings and links. Separate implemented, tested, published, installed and user-confirmed states. Only claim data preservation or native acceptance to the extent actually verified.

A description or translation correction alone does not require rebuilding the application, replacing assets or creating a version. When authorized to correct an existing release, back up its current metadata and body, update only `body`, read it back, and verify that release ID, tag/source, title, publication date, stable/prerelease state, Latest selection and asset IDs/sizes/digests remain unchanged. Published binary assets and tags stay immutable. Do not rewrite unrelated historical notes.

## References and examples

- [GitHub release API](https://docs.github.com/en/rest/releases/releases): one description body and separate release identity/asset fields.
- [GitHub Markdown section links and custom anchors](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#custom-anchors).
- [GitHub collapsed sections](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/organizing-information-with-collapsed-sections).
- [FACEIT Absolute 2.6.0](https://github.com/growlee/FACEIT-Absolute/releases/tag/v2.6.0): Russian and English sections with navigation links in one release.
- [OverTranslate 2.11.0](https://github.com/Hon-Lu/OverTranslate/releases/tag/2.11.0): named collapsible sections for several languages.

These are examples of presentation choices, not a universal requirement or an endorsement of those products. The standard Markdown headings and short outcome-oriented copy also preserve the style of [upstream FluidVoice](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.13), with the smallest necessary addition for the two Pichi Voice languages.
