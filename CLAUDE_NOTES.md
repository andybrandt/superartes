# Project Notes

- `skills/writing-skills/render-graphs.js` currently fails under the root `"type": "module"` package setting because it uses CommonJS `require`. Graphviz `dot` is also not installed in this environment, so DOT diagram verification may need a script fix or a different local setup.
