---
layout: home

hero:
  name: Heimdall
  text: Native desktop apps in Odin + web
  tagline: The watchman that bridges your Odin backend and your web frontend — shipped as one native binary.
  image:
    src: /logo.svg
    alt: Heimdall
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: Introduction
      link: /guide/introduction
    - theme: alt
      text: GitHub
      link: https://github.com/galaxoid-labs/heimdall

features:
  - title: Bring your own frontend
    details: Your UI is a folder of static files. No bundler, framework, or node_modules shipped for you.
  - title: One file to ship
    details: The frontend is baked into the executable at compile time. A release is a single binary.
  - title: A typed bridge
    details: Call Odin commands and subscribe to events from JS through a generated, fully-typed client — args, results, and event payloads all checked from your Odin types.
  - title: Fast inner loop
    details: heimdall dev rebuilds and relaunches in a blink — the main reason this is written in Odin.
  - title: Native shell
    details: A hand-written native shell per platform — WKWebView on macOS, GTK4 + libadwaita on Linux, WebView2 on Windows.
  - title: Package & sign
    details: heimdall bundle makes a macOS .app (sign + notarize) or Linux .deb + .rpm, with a ready-made CI action.
---
