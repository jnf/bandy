# Security

bandy is a one-person hobby project that downloads music you've bought on Bandcamp. It holds one secret, your Bandcamp `identity` cookie, and it writes files to your disk. Those two things are where a security bug would hurt.

## Supported versions

There are no releases. `canon` is the only supported version, so fixes land there.

## Reporting a vulnerability

Please report it privately through GitHub: on this repo, go to **Security → Report a vulnerability**. Don't open a public issue.

Include what you found, how to reproduce it, and what you think an attacker gets out of it. I'll acknowledge it as soon as I can (but again, solo maintainer, fun side project). I'll keep you posted while I work on it, and I'm happy to credit you when it lands.

## Out of scope

- **Bandcamp itself.** bandy uses unofficial Bandcamp APIs. If the bug is in Bandcamp, report it to Bandcamp.
- **A leaked `.env`.** If someone can read your `.env`, they have your cookie. Keep it out of version control (it's gitignored here) and log out of Bandcamp to rotate it.
