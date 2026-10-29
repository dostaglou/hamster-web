# Application conventions

- Keep one action per endpoint directory; HTML responses can use a sibling view.html.erb.
- Declare routes in app/routes/mappings.rb.
- App Ruby files load through config/manifest.rb; do not add local requires.
- Run bin/hamster manifest after editing application Ruby files or templates.
- Run bin/hamster manifest:check before building.
- Keep build-time code out of the Spinel runtime require chain.
