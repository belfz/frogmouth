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

## Keeping the guide current

Treat the guide as part of the implementation documentation. Update it in the
same pull request whenever a change affects:

- subsystem or file responsibilities;
- persisted project state or editing commands;
- preview, stabilization, export, or temporary-file flows;
- framework and external-tool integration;
- testing strategy, configuration, or development commands.

Prefer stable architectural facts over measurements such as source-file line
counts, which become stale without improving the mental model. A change that
does not affect the areas above does not require a guide update.
