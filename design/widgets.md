# Rich response widgets

Claude emits widgets as fenced code blocks with a custom language tag. The app parses
the stream; while a widget's fence is still open it shows a shimmer placeholder
("Drawing chart…"), and renders the widget when the closing fence arrives. A block
that fails to parse falls back to a plain code block.

No tools or MCP are involved, so the minimal `claude -p` setup stays unchanged.

| Tag        | Renderer                                              | Card actions            |
|------------|-------------------------------------------------------|-------------------------|
| (markdown) | native SwiftUI markdown (headings, lists, tables, code) | —                     |
| `chart`    | Swift Charts, from the JSON schema below              | Copy as image           |
| `html`     | sandboxed `WKWebView`, created lazily per card        | Copy source, Open large |
| `document` | file card; body is markdown                           | Copy, Save…             |

Chosen for performance: no web view unless an `html` card is on screen, and charts
are native (no Vega-Lite / JS chart libraries).

## `chart` schema

```json
{
  "type": "bar" | "line" | "area" | "pie" | "scatter",
  "title": "string",
  "x_label": "string (optional)",
  "y_label": "string (optional)",
  "data": [ { "x": "string | number", "y": number, "series": "string (optional)", "highlight": true } ]
}
```

- `series` groups points into multiple lines / grouped bars; max 5 series.
- Max 50 points. `pie` uses `x` as the label and `y` as the value.

## `html` sandbox

- JavaScript on; network blocked (`WKContentRuleList` blocking all `http(s)` loads);
  navigation blocked; non-persistent `WKWebsiteDataStore`; no file access.
- Card height = document height, capped at 320pt; "Open large" shows it in a window.
- Transparent background; the page should use `color-scheme: light dark`.

## `document` header

The first line after the fence is `title: <name>`; the rest is markdown.
"Save…" writes `<name>.md` through an `NSSavePanel`.

## System prompt (draft, ~350 tokens)

```
You are a concise, friendly assistant in a small floating chat window on macOS.
Answer in markdown. Keep answers short unless asked for detail.

You can also include these widgets as fenced code blocks when they clearly help.
Use at most two per answer, and never for trivial answers.

```chart
{"type":"bar","title":"…","data":[{"x":"A","y":3},{"x":"B","y":5}]}
```
type: bar | line | area | pie | scatter. Optional: x_label, y_label, and per
point "series" (≤5 series) and "highlight": true. ≤50 points. Valid JSON only.
Use for numeric comparisons and trends. Label approximate data as approximate.

```html
<!doctype html>…
```
One self-contained page for small interactive things (quizzes, calculators,
visual demos). Inline all CSS/JS; no external URLs, network, or storage. Keep it
under ~150 lines, transparent background, `color-scheme: light dark`, and a
width of about 500px.

```document
title: Name
…markdown…
```
For content the user will want to keep or save (notes, checklists, cheat sheets).

Write a short sentence of context before each widget.
```
