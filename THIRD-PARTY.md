# Third-party code

- **2010 Rust Rewrite Mashup** (chasmlol), a fork of **IW4L** (vladtrc). Apache License 2.0.
  - `host/` depends on its `skate-host` crate (pinned to commit `f608f85e407ff1b7689d54a9aafdd16e95711ac4`).
  - `host/src/rails.rs` is adapted from its rail finder.
  - The license and notice are in `licenses/mashup-LICENSE.txt` and `licenses/mashup-NOTICE.txt`.
- **sm64coopdx** is not included. The mod uses its public Lua API, and the bridge reads the `coop.map` that ships with it.
- **Game data** is not included: no Super Mario 64 ROM, Skate 3 assets or Skate 3 audio. Users convert their own copies with the tools in `tools/`.
