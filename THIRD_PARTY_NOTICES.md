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
