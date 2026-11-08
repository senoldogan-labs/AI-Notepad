#!/usr/bin/env python3
"""Export, import and check app string-catalog translations.

The catalogs' source language is Turkish and every string has an English translation. Other UI languages are
translated from English (Turkish as context) outside the catalog and imported back:

    scripts/l10n.py export --lang de --out /tmp/l10n/de.todo.json      # strings still missing in German
    scripts/l10n.py validate --lang de --in /tmp/l10n/de.json          # checks a translation file, writes nothing
    scripts/l10n.py import --lang de --in /tmp/l10n/de.json            # validates placeholders, writes catalogs
    scripts/l10n.py check                                              # every UI language complete? (exit 1 if not)

Translation file (`import`): a JSON list of {"catalog", "key", "value"} where `value` is a string, or for plural
strings an object {"one": "...", "other": "..."} (languages without a singular form give only "other").
A missing translation falls back to the Turkish source on device, so `check` (and LocalizationCompletenessTests)
require every language for every translatable string.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT: Path = Path(__file__).resolve().parent.parent
CATALOGS: tuple[str, ...] = (
    "App/Localizable.xcstrings",
    "App/InfoPlist.xcstrings",
    "App/Hosted/InfoPlist.xcstrings",
    "iOS/InfoPlist.xcstrings",
    "App/AppShortcuts.xcstrings",
)
# App UI languages besides the Turkish source and English. Keep in sync with LocalizationCompletenessTests.
TARGET_LANGUAGES: tuple[str, ...] = ("de", "fr", "es", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans", "fi")
# Product names stay as they are in every language.
UNTRANSLATED_KEYS: frozenset[str] = frozenset({"CFBundleName", "CFBundleDisplayName"})
# Plural categories written per language (Apple string catalogs accept "one" + "other" for these).
SINGULAR_LESS: frozenset[str] = frozenset({"ja", "ko", "zh-Hans"})
PLACEHOLDER: re.Pattern[str] = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|s|%)|\$\{[A-Za-z]+\}")

# Runs on the system Python (3.9): the aliases stay plain assignments.
JSONValue = object  # parsed JSON (str, number, bool, None, list, dict); narrowed with isinstance before use
Catalog = dict
Plural = dict


@dataclass(frozen=True)
class SourceString:
    """A translatable entry: its English (and Turkish) text, plain or plural."""

    catalog: str
    key: str
    english: str | Plural
    turkish: str | Plural
    comment: str


class TranslationError(Exception):
    """A translation that cannot be imported (unknown key, wrong placeholders, wrong shape)."""


def load_catalog(relative: str) -> Catalog:
    with (ROOT / relative).open(encoding="utf-8") as handle:
        loaded: Catalog = json.load(handle)
    return loaded


def save_catalog(relative: str, catalog: Catalog) -> None:
    """Writes in the catalogs' existing layout (2-space JSON); keeps whether the file ended with a newline."""
    path: Path = ROOT / relative
    ending: str = "\n" if path.read_text(encoding="utf-8").endswith("\n") else ""
    text: str = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", ": "))
    path.write_text(text + ending, encoding="utf-8")


def localization_text(localization: dict[str, JSONValue]) -> str | Plural | None:
    """The value of one language's localization: a string, a plural dict, or None when absent. Pure function."""
    unit = localization.get("stringUnit")
    if isinstance(unit, dict):
        value = unit.get("value")
        return value if isinstance(value, str) else None
    variations = localization.get("variations")
    if isinstance(variations, dict):
        plural = variations.get("plural")
        if isinstance(plural, dict):
            forms: Plural = {}
            for category, form in plural.items():
                if isinstance(form, dict):
                    form_unit = form.get("stringUnit")
                    if isinstance(form_unit, dict) and isinstance(form_unit.get("value"), str):
                        forms[category] = str(form_unit["value"])
            return forms
    return None


def source_strings(relative: str, catalog: Catalog) -> list[SourceString]:
    """Translatable entries of a catalog (English required). Pure function."""
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise TranslationError(f"{relative}: no strings object")
    result: list[SourceString] = []
    for key, entry in strings.items():
        if not isinstance(entry, dict) or entry.get("shouldTranslate") is False or key in UNTRANSLATED_KEYS:
            continue
        localizations = entry.get("localizations")
        localizations = localizations if isinstance(localizations, dict) else {}
        english_loc = localizations.get("en")
        english = localization_text(english_loc) if isinstance(english_loc, dict) else None
        if english is None:
            continue
        turkish_loc = localizations.get("tr")
        turkish = localization_text(turkish_loc) if isinstance(turkish_loc, dict) else None
        comment = entry.get("comment")
        result.append(SourceString(relative, key, english, turkish if turkish is not None else key, comment if isinstance(comment, str) else ""))
    return result


def has_language(catalog: Catalog, key: str, language: str) -> bool:
    strings = catalog.get("strings")
    entry = strings.get(key) if isinstance(strings, dict) else None
    localizations = entry.get("localizations") if isinstance(entry, dict) else None
    localization = localizations.get(language) if isinstance(localizations, dict) else None
    return isinstance(localization, dict) and localization_text(localization) is not None


def placeholders(text: str) -> list[str]:
    """Placeholders in order, positional indexes stripped for comparison. Pure function."""
    return sorted(re.sub(r"%\d+\$", "%", match) for match in PLACEHOLDER.findall(text))


def argument_types(text: str) -> list[str]:
    """Format arguments in the order they are consumed: plain specifiers in text order, positional ones (`%2$@`) by
    their index. `%%` and `${name}` take no argument. Mixing plain and positional specifiers is an error. Pure function."""
    found: list[str] = [match for match in PLACEHOLDER.findall(text) if match != "%%" and not match.startswith("${")]
    positional: list[tuple[int, str]] = []
    plain: list[str] = []
    for match in found:
        indexed = re.match(r"%(\d+)\$(.+)", match)
        if indexed:
            positional.append((int(indexed.group(1)), "%" + indexed.group(2)))
        else:
            plain.append(match)
    if positional and plain:
        raise TranslationError(f"mixes positional and plain specifiers: {found}")
    if positional:
        ordered = sorted(positional)
        if [index for index, _ in ordered] != list(range(1, len(ordered) + 1)):
            raise TranslationError(f"positional specifiers must be %1$ … %{len(ordered)}$: {found}")
        return [kind for _, kind in ordered]
    return plain


def require_same_arguments(key: str, translation: str, english: str) -> None:
    """The translation must consume the same argument types in the same order as English (else a runtime crash or a
    swapped value) and keep every placeholder. Pure check."""
    if placeholders(translation) != placeholders(english):
        raise TranslationError(f"{key!r}: placeholders {placeholders(translation)} != English {placeholders(english)}")
    if argument_types(translation) != argument_types(english):
        raise TranslationError(f"{key!r}: argument order {argument_types(translation)} != English {argument_types(english)}")


def required_categories(language: str) -> tuple[str, ...]:
    return ("other",) if language in SINGULAR_LESS else ("one", "other")


def validated_localization(source: SourceString, language: str, value: JSONValue) -> dict[str, JSONValue]:
    """The catalog localization for a translation after checking its shape and placeholders. Pure function."""
    if isinstance(source.english, str):
        if not isinstance(value, str) or not value.strip():
            raise TranslationError(f"{source.key!r}: expected a non-empty string")
        require_same_arguments(source.key, value, source.english)
        return {"stringUnit": {"state": "translated", "value": value}}
    if not isinstance(value, dict):
        raise TranslationError(f"{source.key!r}: expected a plural object")
    english_other: str = source.english.get("other", "")
    forms: dict[str, JSONValue] = {}
    for category in required_categories(language):
        form = value.get(category)
        if not isinstance(form, str) or not form.strip():
            raise TranslationError(f"{source.key!r}: plural form {category!r} missing")
        require_same_arguments(f"{source.key}/{category}", form, english_other)
        forms[category] = {"stringUnit": {"state": "translated", "value": form}}
    return {"variations": {"plural": forms}}


def export_missing(language: str, out: Path) -> None:
    items: list[dict[str, JSONValue]] = []
    for relative in CATALOGS:
        catalog: Catalog = load_catalog(relative)
        for source in source_strings(relative, catalog):
            if not has_language(catalog, source.key, language):
                items.append({"catalog": source.catalog, "key": source.key, "en": source.english, "tr": source.turkish, "comment": source.comment})
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{language}: {len(items)} strings to translate -> {out}")


def applied_translations(language: str, source_file: Path) -> tuple[dict[str, Catalog], int]:
    """Catalogs with the file's translations applied (in memory). Raises SystemExit listing every rejected entry."""
    with source_file.open(encoding="utf-8") as handle:
        translations: list[dict[str, JSONValue]] = json.load(handle)
    catalogs: dict[str, Catalog] = {relative: load_catalog(relative) for relative in CATALOGS}
    sources: dict[tuple[str, str], SourceString] = {
        (source.catalog, source.key): source for relative, catalog in catalogs.items() for source in source_strings(relative, catalog)
    }
    errors: list[str] = []
    applied: int = 0
    for item in translations:
        catalog_name, key = item.get("catalog"), item.get("key")
        if not isinstance(catalog_name, str) or not isinstance(key, str) or (catalog_name, key) not in sources:
            errors.append(f"unknown entry {catalog_name}:{key!r}")
            continue
        try:
            localization = validated_localization(sources[(catalog_name, key)], language, item.get("value"))
        except TranslationError as error:
            errors.append(str(error))
            continue
        strings = catalogs[catalog_name]["strings"]
        assert isinstance(strings, dict)
        entry = strings[key]
        assert isinstance(entry, dict)
        localizations = entry.setdefault("localizations", {})
        assert isinstance(localizations, dict)
        localizations[language] = localization
        # Xcode keeps each entry's languages in alphabetical order; write them the same way to avoid diff churn.
        entry["localizations"] = {name: localizations[name] for name in sorted(localizations)}
        applied += 1
    if errors:
        print(f"{language}: {len(errors)} rejected in {source_file}:", file=sys.stderr)
        for error in errors[:80]:
            print(f"  {error}", file=sys.stderr)
        raise SystemExit(1)
    return catalogs, applied


def validate_translations(language: str, source_file: Path) -> None:
    """Checks a translation file without touching the catalogs."""
    _, applied = applied_translations(language, source_file)
    print(f"{language}: {applied} translations valid in {source_file}")


def import_translations(language: str, source_file: Path) -> None:
    catalogs, applied = applied_translations(language, source_file)
    for relative, catalog in catalogs.items():
        save_catalog(relative, catalog)
    print(f"{language}: {applied} translations imported")


def check(languages: tuple[str, ...]) -> None:
    missing: dict[str, int] = {}
    for relative in CATALOGS:
        catalog: Catalog = load_catalog(relative)
        for source in source_strings(relative, catalog):
            for language in languages:
                if not has_language(catalog, source.key, language):
                    missing[language] = missing.get(language, 0) + 1
    if missing:
        print("missing translations: " + ", ".join(f"{language} {count}" for language, count in sorted(missing.items())), file=sys.stderr)
        raise SystemExit(1)
    print(f"all {len(languages)} languages complete")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    export_parser = commands.add_parser("export")
    export_parser.add_argument("--lang", required=True, choices=TARGET_LANGUAGES)
    export_parser.add_argument("--out", required=True, type=Path)
    import_parser = commands.add_parser("import")
    import_parser.add_argument("--lang", required=True, choices=TARGET_LANGUAGES)
    import_parser.add_argument("--in", dest="source", required=True, type=Path)
    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("--lang", required=True, choices=TARGET_LANGUAGES)
    validate_parser.add_argument("--in", dest="source", required=True, type=Path)
    commands.add_parser("check")
    arguments = parser.parse_args()
    if arguments.command == "export":
        export_missing(arguments.lang, arguments.out)
    elif arguments.command == "import":
        import_translations(arguments.lang, arguments.source)
    elif arguments.command == "validate":
        validate_translations(arguments.lang, arguments.source)
    else:
        check(TARGET_LANGUAGES)


if __name__ == "__main__":
    main()
