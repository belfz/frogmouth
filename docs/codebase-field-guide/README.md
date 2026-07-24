# Frogmouth Codebase Field Guide

This is a dependency-free, interactive developer orientation for the Frogmouth
1.0 codebase. It combines a guided ten-chapter presentation with an
architecture explorer, runtime feature traces, test filtering, search, and a
"where should this change go?" decision helper. The operation microscope traces
split, trim, fade, stabilization, and export across UI events, domain state,
preview/rendering, temporary files, managed cache artifacts, project JSON, and
untouched source media.

Open `index.html` directly in a browser, or serve the repository root:

```sh
python3 -m http.server 8000
```

Then visit:

```text
http://localhost:8000/docs/codebase-field-guide/
```

Keyboard controls:

- Right/left arrow: next/previous chapter
- Home/End: first/last chapter
- `/`: search
- `?`: keyboard guide

The guide intentionally has no package manager, generated output, external
assets, analytics, or network requests. Its source references are relative to
the repository, so it should remain in `docs/codebase-field-guide/`.
