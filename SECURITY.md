# Security policy

## Reporting a vulnerability

Please do not report a security problem in a public issue.

Report it privately instead, in one of two ways:

1. **On GitHub:** open the **Security** tab of this repository and choose
   **Report a vulnerability**. Only we can see the report.
2. **By email:** write to `node@lyt.no`.

Please include:

- what you found, and what someone could do with it
- the steps to reproduce it
- which part it concerns: this client package, the website, the service
  at `nodes.lyt.no`, or a rented node
- the date and time, with your time zone, if it involved a real order

Never include a working key or token in the report. Describe it instead, for
example "my `lyt_live_` API key", and we will ask for more if we need it.

We will confirm that we received your report, keep you informed while we work
on it, and tell you when it is fixed. Please give us a reasonable time to fix
it before you tell anyone else.

## What is covered

- The files in this repository.
- The client parts that `setup.sh` fetches with your API key.
- The website at https://node.lyt.no/account and the service at
  `nodes.lyt.no`, including its API.
- The nodes it rents out, from ordering to release.

## Supported versions

Only the latest version is supported. `setup.sh` always fetches the current
client, so running it again brings you up to date.

## More

How your keys, nodes and work are protected is described in
[docs/security.md](docs/security.md).
