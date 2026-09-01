# The user manual

This directory is the **source of the user manual** published at
<https://owenb321.github.io/MiSTer_DVD/>. It is not build output — `site/` is tracked in
git. The build writes to `.site-build/`, which is gitignored.

`site/content/` is the manual. `mkdocs.yml` at the repo root configures it, and
`.github/workflows/docs.yml` builds and deploys it on every push to `main` that touches
either.

## Preview it locally

```bash
python3 -m venv .venv
source .venv/bin/activate          # fish: source .venv/bin/activate.fish
pip install -r site/requirements.txt

mkdocs serve                       # http://127.0.0.1:8000, live reload
mkdocs build --strict              # exactly what CI runs
python3 tools/docs_check.py        # CONF_STR <-> manual parity
```

Run both checks before committing anything under `site/content/`.

## What belongs here, and what does not

| | |
|---|---|
| `README.md` | The landing page. What the core is, honest status, quick start, licensing. Deliberately short — **not** the manual. |
| `site/content/` | **The user manual.** Every user-visible detail: controls, settings, messages, output modes, formats, troubleshooting. |
| `docs/` | Engineering design notes — *why* the RTL is the way it is. **Not published, not user documentation.** |

If a `docs/` note contains genuinely user-facing material, **harvest those sentences into
the manual**. Do not link a reader into `docs/` as though it were a manual page; the note
keeps its own copy for engineering context.

Conversely, do not put engineering rationale here. "The detector ignores pictures carrying
no evidence" belongs in the manual; "measured on Apollo 13 at 384 B against a 17,704 B
median" belongs in `docs/film_24p_plan.md`.

## Authoring rules

**Keep `.md` extensions on cross-links.** Write `[Settings](../playback/settings.md)`, not
an extensionless or directory-style link. MkDocs rewrites `.md` to the built URL, *and*
GitHub resolves the same link natively — so `site/content/` stays fully readable as plain
markdown in the repo, for offline readers and anyone browsing on GitHub.

**Links to repo files must be absolute.** `strict: true` fails the build on any link that
escapes `docs_dir`, so a relative `../../LICENSE` will not work. Use the full
`https://github.com/owenb321/MiSTer_DVD/blob/main/…` URL for `LICENSE`, `NOTICE`,
`main/README.md`, and anything in `docs/`.

**Mark unreleased features.** The site is built from `main`, so it describes the
development build. Anything not in the newest release gets:

```markdown
!!! info "Unreleased"
    Available in development builds; not in v0.3.0.
```

The announcement bar carries the released version from `extra.released_version` in
`mkdocs.yml`. The release process bumps it and sweeps out the stale admonitions.

**`assets/img/default-logo.png` is generated, not drawn.** It is a copy of
`tools/idle_logo_preview.png`, which `tools/idle_logo.py` regenerates from the built-in art
alongside `dvd/idle_logo.mem`. If the default logo ever changes, re-run the tool and copy
the preview across, or the manual will show art the core no longer draws.

**Prose must never depend on an image.** No "as shown below", no "the highlighted row".
There are no screenshots in the repo yet; every page has to read correctly with none, so
that adding one later is an insertion rather than a rewrite. Placeholders are marked with
`<!-- SCREENSHOT ... -->` comments carrying the caption and capture recipe. When you add
one, use the figure form (`attr_list` and `md_in_html` are enabled for exactly this):

```html
<figure markdown="span">
  ![The Main settings page](../assets/img/osd-main.png){ width="640" }
  <figcaption>The Main settings page, showing default values.</figcaption>
</figure>
```

## Why MkDocs

It is the MiSTer ecosystem's own convention — mister-devel's documentation is MkDocs on
`github.io` (see `docs/references.md`) — and the content here is plain markdown with no
need for a JavaScript framework.
