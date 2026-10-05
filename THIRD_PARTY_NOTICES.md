# Built-in recipes

`assets/builtin_recipes.json` holds film simulation settings published by their
individual creators. Each entry keeps the creator's name and a link to the
original publication, both shown in the app. The list was compiled from the
[Fujifilm Film Simulation Recipes Database](https://hpchavaz-photography.blogspot.com/p/fujifims.html)
maintained by Henri-Pierre Chavaz (export of 2026-10-05), restricted to X-Trans IV
and X-Trans V entries whose settings could be converted unambiguously by
`tool/build_builtin_recipes.py`. The database and the original publications carry
no explicit licence; the recipes remain the work of their creators. Please visit
and support the original pages. Creators who want an entry removed can open an
issue.

# Protocol references

Fuji San contains an independently written Dart PTP implementation. Property IDs,
wire encodings, dependencies and name restrictions were informed by:

- [FilmKit](https://github.com/eggricesoy/filmkit), MIT, commit
  `9e3bbcf858b1f9dc522e90adf7e385554f5969e2` — X100VI observations, PTP framing,
  white-balance write ordering and non-linear noise reduction encodings.
- [Fuji PTP Recipes](https://github.com/ILFforever/fujifilm-ptp-recipes),
  commit `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`.
  Documentation licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/);
  examples licensed MIT. We adapted property mappings into Dart and restricted
  writes to understood recipe fields. In particular D1A5 and unknown image-quality
  properties are never written. This is not an endorsement by those projects.

Flutter and dependencies retain their respective licenses, available in the
dependency packages. FUJIFILM and film-simulation names belong to their owners.
This project is not affiliated with FUJIFILM.
