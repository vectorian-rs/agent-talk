defmodule AgentTalk.Web.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <meta name="description" content="Agent messages, routing, and inbox collection status." />
        <title>AgentTalk · Message monitor</title>
        <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml" />
        <link rel="preload" href="/assets/fonts/ibm-plex-sans-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin />
        <link rel="preload" href="/assets/fonts/source-serif-4-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin />
        <link rel="stylesheet" href="/assets/opexopt/fonts.css" />
        <link rel="stylesheet" href="/assets/opexopt/tokens.css" />
        <link rel="stylesheet" href="/assets/opexopt/base.css" />
        <link rel="stylesheet" href="/assets/opexopt/layout.css" />
        <link rel="stylesheet" href="/assets/operator.css" />
        <script src="/assets/theme.js"></script>
        <script type="module" src="/assets/operator.js"></script>
      </head>
      <body>
        <a href="#main" class="skip-link">Skip to messages</a>
        {@inner_content}
      </body>
    </html>
    """
  end
end
