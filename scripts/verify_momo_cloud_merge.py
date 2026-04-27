#!/usr/bin/env python3
"""Verify MoMo cloud word-list merge semantics without network access."""

def norm_word(word: str) -> str:
    return word.strip().lower()


def normalized_content(content: str) -> str:
    lines = [line.strip() for line in content.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    lines = [line for line in lines if line]
    return "" if not lines else "\n".join(lines) + "\n"


def merge(existing_content: str, new_words: list[str]) -> tuple[str, list[str], int]:
    existing_lines = [line.strip() for line in existing_content.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    existing_lines = [line for line in existing_lines if line]
    seen = {norm_word(line) for line in existing_lines}
    merged = list(existing_lines)
    appended: list[str] = []
    skipped_remote = 0

    for raw in new_words:
        word = raw.strip()
        if not word:
            continue
        key = norm_word(word)
        if key in seen:
            skipped_remote += 1
            continue
        seen.add(key)
        merged.append(word)
        appended.append(word)

    return normalized_content("\n".join(merged)), appended, skipped_remote


def main() -> None:
    content, appended, skipped = merge("Apple\nbanana\n", [" apple ", "Cherry", "banana", "date", ""])
    assert content == "Apple\nbanana\nCherry\ndate\n", content
    assert appended == ["Cherry", "date"], appended
    assert skipped == 2, skipped

    empty_content, empty_appended, empty_skipped = merge("\n", ["  ", "Alpha"])
    assert empty_content == "Alpha\n", empty_content
    assert empty_appended == ["Alpha"], empty_appended
    assert empty_skipped == 0, empty_skipped

    no_change_content, no_change_appended, no_change_skipped = merge("Alpha\n", ["alpha"])
    assert no_change_content == "Alpha\n", no_change_content
    assert no_change_appended == [], no_change_appended
    assert no_change_skipped == 1, no_change_skipped

    print("momo cloud merge verification passed")


if __name__ == "__main__":
    main()
