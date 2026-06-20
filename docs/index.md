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
      link: https://github.com/ismyhc/heimdall

features:
  - title: Bring your own frontend
    details: Your UI is a folder of static files. No bundler, framework, or node_modules shipped for you.
  - title: One file to ship
    details: The frontend is baked into the executable at compile time. A release is a single binary.
  - title: A two-way bridge
    details: JS calls Odin and awaits a result (invoke); Odin pushes events to JS (emit / on). Plain JSON.
  - title: Fast inner loop
    details: heimdall dev rebuilds and relaunches in a blink — the main reason this is written in Odin.
  - title: Native when you want it
    details: Runs on the tiny webview/webview library by default, or a hand-written native macOS WKWebView shell.
  - title: Package & sign
    details: heimdall bundle makes a macOS .app; sign and notarize for distribution, with a ready-made CI action.
---
