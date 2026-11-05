---
name: add-ui-strings
description: Add, change or translate user-facing app strings (Mac, iPhone, shared AINotepadUI) - Turkish source in code, English plus the 10 TARGET_LANGUAGES in App/Localizable.xcstrings via scripts/l10n.py, placeholder and terminology rules, and the localization tests. Use whenever a change adds or edits any Text, Button, label, alert, menu or String(localized:) text, or when the localization tests fail.
---

# Add UI strings

The workflow summary is in AGENTS.md ("Arayüz metinleri"); command usage and the translation file format are in the
docstring of `scripts/l10n.py`. This skill adds the steps and traps around them.

## 1. Write the source in Turkish

- The key is the Turkish text in code (`Text("Görevleri göster")`, `String(localized: "…")`). Interpolation becomes a
  placeholder in the key: `Int` → `%lld`, `String` → `%@`, `Double` → `%lf`.
- **Reuse before adding.** Search the catalog for an existing key with the same Turkish text and check what it means in
  English first: one key has one translation everywhere. Example: `Açık` is already "Light" (the theme); for "On" or
  "Open" use a different Turkish wording so it gets its own key.
- Keep one term per concept. Look up how the term is already translated in every language and reuse it:

```bash
python3 -I - "Görev" <<'EOF'
import json, sys
term = sys.argv[1]
strings = json.load(open("App/Localizable.xcstrings", encoding="utf-8"))["strings"]
for key in sorted((k for k in strings if term.lower() in k.lower()), key=len)[:15]:   # shortest matches first
    loc = strings[key].get("localizations", {})
    print(key, "|", " | ".join(f"{lang}={loc[lang]['stringUnit']['value']}" for lang in sorted(loc) if "stringUnit" in loc[lang]))
EOF
```

## 2. Add the key and its English to the catalog

Catalog: `App/Localizable.xcstrings` (source language `tr`; Info.plist and App Shortcuts strings live in the other
catalogs listed in `scripts/l10n.py` `CATALOGS`). Write with `l10n.py`'s own loader/saver so the formatting stays
identical. Mark keys used only from `Packages/AINotepadCore` (AINotepadUI) as `manual`: Xcode scans only the app
targets and would otherwise treat them as stale and delete them on cleanup.

```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "scripts")
import l10n
path = "App/Localizable.xcstrings"
catalog = l10n.load_catalog(path)
new = {"Görevleri göster": "Show tasks"}          # Turkish key -> English
package_only = True                               # used only from Packages/AINotepadCore?
for key, english in new.items():
    assert key not in catalog["strings"], f"already in catalog: {key!r}"
    entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": english}}}}
    if package_only:
        entry = {"extractionState": "manual", **entry}
    catalog["strings"][key] = entry
l10n.save_catalog(path, catalog)
EOF
```

For a plural, give `en` a `variations.plural` with `one` and `other` instead of `stringUnit` (copy the shape of an
existing plural entry such as `"Ne kaçırdım?" son %lld dakikayı özetler`).

**Placeholders must match the source exactly**, in the same order and the same spelling. Positional forms like
`%1$lld` fail `LocalizationCatalogTests` when the source has `%lld`, and `l10n.py` rejects translations whose order
differs from English. If a language needs a different order, rephrase the sentence instead.

## 3. Translate into the 10 target languages

`TARGET_LANGUAGES` in `scripts/l10n.py`: `de fr es it pt-BR nl ja ko zh-Hans fi` (kept in sync with
`LocalizationCompletenessTests`).

```bash
dir=$(mktemp -d)
for lang in de fr es it pt-BR nl ja ko zh-Hans fi; do scripts/l10n.py export --lang $lang --out "$dir/$lang.todo.json"; done
# translate each todo (from English, Turkish as context) into "$dir/<lang>.json": [{"catalog", "key", "value"}, …]
for lang in de fr es it pt-BR nl ja ko zh-Hans fi; do scripts/l10n.py validate --lang $lang --in "$dir/$lang.json"; done
for lang in de fr es it pt-BR nl ja ko zh-Hans fi; do scripts/l10n.py import --lang $lang --in "$dir/$lang.json"; done
scripts/l10n.py check            # must print: all 10 languages complete
```

Use the terminology found in step 1 for each language, the app's tone (short, plain, second person) and the
platform's own names for system concepts. `ja`, `ko`, `zh-Hans` take only `other` for plurals.

## 4. Verify

```bash
swift test --package-path Packages/AINotepadCore --filter 'LocalizationCatalogTests|LocalizationCompletenessTests'
git diff --stat -- '*.xcstrings'
```

Then run the full test commands and builds before committing (see the `pr-ci-merge` skill). Every new literal in the
diff must exist as a key; a key missing from the catalog fails no test but shows Turkish to every user.
