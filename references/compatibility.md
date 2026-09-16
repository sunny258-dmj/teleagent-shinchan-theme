# Compatibility

## Verified target

- TeleAgent product version: `2.5.2` / file version `2.5.2.0`
- Application type: Electron
- Renderer archive: `resources/app.asar`
- Renderer entry: `dist/index.html`
- Theme stylesheet pattern: `dist/assets/index-*.css`
- Built-in appearance modes: light, dark, and system

The packaged application exposes no custom-theme import entry in version 2.5.2. This skill therefore appends a bounded CSS block to the current renderer stylesheet, repacks the current archive, and retains the exact original archive for recovery.

## Safety invariants

- Patch the current installation; never distribute or restore another TeleAgent version's full `app.asar`.
- Require a matching supported version unless the user explicitly authorizes an unsupported-version test.
- Build in a temporary directory before stopping TeleAgent.
- Back up the source archive and record SHA-256 hashes before replacing it.
- Stop only processes whose executable path exactly matches the selected TeleAgent executable.
- If an update replaces the themed archive, treat it as a new source and validate again.
- Do not touch user data under `.local/share/TeleAgent`, login state, conversations, or the desktop-pet project.

## Visual coverage

The theme overrides TeleAgent's semantic CSS variables for backgrounds, foregrounds, cards, popovers, borders, sidebar states, primary actions, warnings, and charts. It also adds restrained blue-sky gradients, yellow and red Shin-chan accents, rounded cards, softened shadows, and a low-opacity corner mascot. Both light and dark modes remain supported.
