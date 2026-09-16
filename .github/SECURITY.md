# Security policy

Heed is a small macOS agent maintained by one person. Please report anything that looks like a
vulnerability, even if you are not sure; a report that turns out to be a plain bug costs nothing.

## Supported versions

Only the latest release gets fixes. Older versions are not patched, so a fix always means upgrading:

```sh
brew upgrade --cask rbstp/tap/heed
```

The installed version is in the menu bar item, or from `Heed --version`.

## Reporting a vulnerability

Report privately through GitHub, which keeps the report invisible until a fix ships:

**https://github.com/rbstp/heed/security/advisories/new**

Please do not open a public issue, a pull request, or a discussion for a vulnerability -- those are
world-readable from the moment they are filed.

A report is most useful with the Heed version and the macOS version, what an attacker gains from it,
and the shortest way to reproduce it. A crash report or a sample is welcome; please strip anything
private from it, since window titles and file paths are often in there.

What to expect:

- an acknowledgement within 7 days,
- an assessment within 14 days, saying whether it is accepted and how severe it looks,
- a fix in a release, and a published advisory crediting you unless you would rather stay anonymous,
  within 90 days of the report.

Those are targets for a spare-time project, not a contract. If a deadline slips you will hear why
rather than nothing. You are welcome to disclose publicly 90 days after reporting, sooner if a fix
has already shipped.

## Scope

In scope, roughly in the order of how much they would worry me:

- anything that lets another process make Heed act on its behalf, including the `heed://` URL
  scheme, the command line interface and the shortcuts Heed takes away from other apps -- Heed holds
  an Accessibility grant, so acting on its behalf means driving other applications' windows,
- anything that reads or changes what Heed sees of other applications beyond focusing their windows,
- the `io.github.rbstp.heed` defaults domain and the LaunchAgent plist as privilege escalation: a
  value or a path that turns into code Heed runs,
- the release path -- the signed and notarized archive, its checksum, the Homebrew cask, and the
  workflow that produces them.

Out of scope:

- anything that needs the Accessibility grant to already be given to the attacker's own process,
  since macOS treats that grant as full control of the session,
- anything that needs administrator rights or physical access to a logged-in Mac,
- window titles or window geometry being visible to Heed itself; that is the entire point of it,
- reports from a scanner with no working path to abuse behind them,
- the vulnerabilities of other window managers, or of macOS itself -- report those to Apple.
