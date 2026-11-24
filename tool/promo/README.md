# Filming the app for the promo animation

The promo (in the server repo, `promo/`) plays screenshots of the real app.
They are taken from a browser build of the app, driven by a script.

    flutter build web -t tool/promo/main.dart --no-web-resources-cdn --no-wasm-dry-run
    # put the bank file to film with at build/web/promo_bank.json
    # (same format as assets/question_banks/*.json)
    python3 -m http.server 8091 --directory build/web &
    node tool/promo/film.js          # needs Node + Playwright

`film.js` saves the screenshots and `steps.json` (where each tap was) in
`tool/promo/shots/`. The paths at the top of `film_lib.js` point at where the
bank file and the build are; change them if yours differ. The film never
talks to the real servers (the script blocks them).
