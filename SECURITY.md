# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub: go to the repository's **Security** tab and choose **Report a vulnerability**. Don't open a public issue for anything exploitable.

You'll get an acknowledgment within a week. Fixes go out in a new release, and the advisory credits you unless you'd rather it didn't.

## What's in scope

Followspot's design promise is that audio, transcripts, and scripts never leave your machine. Anything that breaks that promise is in scope, for example:

- The page sending data anywhere other than the local whisper server.
- The launcher binding to an address other than `127.0.0.1` without being asked to.
- The `?script=` parameter or file loading reading files outside `public/`.

Vulnerabilities in whisper.cpp itself should go to [the whisper.cpp project](https://github.com/ggml-org/whisper.cpp/security).

## Supported versions

Only the latest release gets security fixes.
