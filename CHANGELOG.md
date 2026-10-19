# Changelog

## 2026-10-19

- Added a red `Duplicated` tag to queued files that share a normalized leading
  release code. The check ignores site prefixes before `@`, letter case,
  common code separators, and trailing title or quality text. The tag warns
  about a possible duplicate; it does not remove or disable either file.
- Made the input and queue panels grow with the window height, including the
  drop area and the queue's scrollable space.
