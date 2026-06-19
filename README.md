# dashy

Browse [Dash.app](https://kapeli.com/dash) docsets from Emacs, rendering
documentation in `eww`.

`dashy` talks to Dash's local HTTP API to list docsets and search
documentation. You pick a result with `completing-read` and it opens in
`eww` — no leaving Emacs.

## Demo

<video src="assets/demo.mp4" controls></video>

## Requirements

- Emacs 31.1+
- Dash.app, running with its local API server enabled
  (Dash → Preferences → Integration → "HTTP API Server")

## Installation

Put `dashy.el` on your `load-path` and:

```elisp
(require 'dashy)
```

Or with `use-package`:

```elisp
(use-package dashy
  :ensure t
  :vc (:url "https://github.com/lukaszkorecki/dashy"))
```

## Usage

- `M-x dashy` — transient menu (search, search at point, select/clear/refresh docsets).
- `M-x dashy-search` — prompt for a query.
- `M-x dashy-at-point` — search for the symbol under point.
- `M-x dashy-select-docsets` — restrict searches to one or more docsets.
- `M-x dashy-clear-docsets` — clear the docset filter.
- `M-x dashy-refresh-docsets` — re-fetch the docset list from Dash.

At least one docset must be selected before searching — Dash's API errors
on empty filters, so the search commands prompt for docsets if none are set.

## Customization

- `dashy-status-file` — path to Dash's API status file
  (default: `~/Library/Application Support/Dash/.dash_api_server/status.json`).
- `dashy-request-timeout` — seconds to wait for a Dash API response (default: 10).
