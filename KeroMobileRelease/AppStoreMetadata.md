# Kero for iOS — App Store Metadata

## Identity

- **App name:** Kero – SSH Terminal
- **Subtitle:** Secure SSH terminal
- **Primary category:** Developer Tools
- **Secondary category:** Utilities
- **Bundle ID:** `sh.kero.mobile`
- **Version:** 0.0.1
- **Copyright:** Set this to the legal name of the App Store account holder.

## URLs

- **Support URL:** https://kero.sh/support
- **Marketing URL:** https://kero.sh
- **Privacy policy URL:** https://kero.sh/privacy

The support URL must provide a working contact path to `hi@egoist.dev`, and the
privacy-policy URL must serve the policy in `PrivacyPolicy.md`, before the
version is submitted.

## Promotional Text

Your servers, your terminal. Kero is a focused native SSH client with secure
device-only credential storage and careful host-key verification.

## Description

Kero is a native SSH terminal for iPhone and iPad, designed for developers and
server operators who want a focused, trustworthy remote shell.

Connect with a password or a device-generated Ed25519 key. Kero keeps passwords
and private keys in the device-only Keychain, verifies server host keys on first
use, and warns before accepting a changed identity.

Highlights:

- Native terminal with Unicode, links, selection, and hardware-keyboard input
- Password and Ed25519 public-key authentication
- Optional Face ID or passcode protection for saved credentials
- SHA-256 host-key fingerprints and changed-key warnings
- Touch keys for Escape, Tab, Control-C, arrows, Home, and End
- Optional tmux resume command for resilient remote work
- iPhone and iPad support, including portrait and landscape layouts
- No account, analytics, advertising, tracking, or Kero traffic proxy

Kero connects directly to SSH servers you specify. You need access to an SSH
server that accepts password authentication or the generated public key.
Sessions disconnect when iOS moves Kero into the background; enable the tmux
option on hosts where you want remote work to survive reconnects.

## Keywords

`ssh,terminal,shell,server,linux,developer,remote,command line,tmux,sysadmin`

## App Privacy

Select **Data Not Collected** only while the shipped build remains consistent
with the in-app policy: no developer analytics, telemetry, advertising,
tracking, account service, or traffic relay. Credentials and connection
metadata stay on the device; terminal traffic goes directly to the server the
user selected.

## Review Notes Template

Kero is a standalone SSH terminal and does not require a Kero account.

Please use the review SSH server below:

- Host: `[PUBLICLY REACHABLE REVIEW HOST]`
- Port: `[PORT]`
- Username: `[USERNAME]`
- Password: `[PASSWORD]`
- Expected SHA-256 host-key fingerprint: `[SHA256:FINGERPRINT]`

Review flow:

1. Tap Add Host.
2. Enter the values above and save.
3. Open the host.
4. Compare the displayed host-key fingerprint with the value above, then tap
   Trust and Connect.
5. Run `uname -a` or the harmless command documented for the review account.
6. The Keys tab can generate an Ed25519 key and expose only its public half.

The review account must be non-privileged, time-limited, isolated from
production, and remain available throughout review. Do not place these
credentials in screenshots or public release notes.

## Screenshots

Capture the current required iPhone and iPad display classes listed by App
Store Connect. Use a dedicated demo server with synthetic data.

Suggested sequence:

1. Hosts list with two or three clearly named demo servers
2. Connected terminal showing a harmless system-status command
3. Host-key verification sheet with a synthetic fingerprint
4. SSH key detail and public-key sharing
5. Privacy settings or trusted-host management

Do not submit screenshots containing real credentials, IP addresses, customer
hostnames, production terminal output, or a failed/connecting placeholder.
