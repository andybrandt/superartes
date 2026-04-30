# Project Notes

- `skills/writing-skills/render-graphs.js` currently fails under the root `"type": "module"` package setting because it uses CommonJS `require`. Graphviz `dot` is also not installed in this environment, so DOT diagram verification may need a script fix or a different local setup.
- For Git-installed Codex marketplaces where the plugin lives at the repository root, use a marketplace plugin source of `"source": "url"` with the repository URL and ref. A repo-cloned marketplace entry using `"source": "local", "path": "./"` can be registered by `codex plugin marketplace add` but then skipped in `/plugins`.
