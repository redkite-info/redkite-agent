# Red Kite — the agent

The part of [Red Kite](https://redkite.info) that runs on a machine you own. It says *"I am still
here"* to a hub outside the building every few minutes, and **the alarm is the absence of that
message, not the presence of one** — so a server that loses power, loses its line, or is simply
switched off is noticed either way.

It is here so you can read it before you run it. That is the whole reason this repository exists.

## The agent never accepts instructions

This is the line that matters most, and it is worth stating before anything else.

The agent sends. It does not receive instructions. There is no remote command execution, no "run
this script", and no self-update that fetches code. Its entire network surface is one outbound
request:

```
POST /api/v1/check-in     Authorization: Bearer rk_live_…
```

The response may carry two things and no others: a suggested interval, which is a bounded integer,
and a replacement token, which is validated against an expected prefix and character set before it
is written anywhere. Nothing in a reply can cause the agent to execute code, read a file it does
not already read, or contact a host other than the one in its own configuration.

The reasoning is arithmetic rather than caution. An agent that can be told what to run turns one
compromised hub into administrative access to every machine running it. That is not a monitoring
system; it is a botnet with a support contract.

If you want remote access — and it is a genuinely useful thing to want — it belongs in a separate
tool with its own authentication, its own audit trail and its own explicit consent. Not bolted onto
the one piece of software that runs unattended on other people's servers.

## What it sends

Figures, never content. No file names, no user names, no process command lines, no log message
text, no drive serial numbers. The test applied to anything new is: *if this database leaked, what
would the customer mind?*

The hub timestamps every check-in on arrival. The agent's own clock travels as a fact, so that a
machine forty minutes out is visible as exactly that, but it is never the basis of any decision.

[What we watch](https://redkite.info/what-we-watch.html) is the complete inventory of every figure
gathered, and what is deliberately not.

## Reading it

It is a shell script. There is no compiled binary and nothing is obfuscated.

| Path | What |
|---|---|
| `unraid/redkite-unraid.sh` | The Unraid agent, in full |
| `unraid/Dockerfile` | Alpine, bash, curl and smartmontools. Nothing else |

Two things in the Dockerfile are worth knowing, because both look like mistakes and are not:

- **It runs as root inside the container.** SMART reads go through an ioctl that wants
  `CAP_SYS_RAWIO`, and a capability is only useful to a process that can claim it. Everything the
  container can reach is mounted read-only, and it holds no capability it was not explicitly given.
- **There is no `HEALTHCHECK`, on purpose.** The hub is the healthcheck. If the container stops,
  check-ins stop, the hub raises an incident and tells somebody — which is the entire product. A
  healthcheck here would let Docker quietly restart a container that is failing to report, hiding
  the one thing that is meant to be noticed.

The container is given the host's `/proc`, `/sys` and `/` read-only. It reads them and posts
figures outwards. It writes nothing to the host at all, and the device rules it is granted permit
reading block devices and nothing else — no write, no `mknod`, and never `--privileged`.

## Installing it

On Unraid, through Community Applications, or by the template in
[redkite-unraid-templates](https://github.com/redkite-info/redkite-unraid-templates).

Everywhere else, start at [redkite.info](https://redkite.info). You will need a hub — Red Kite is
self-hosted, there is no account with us, and we do not monitor anything for anybody.

## The licence, and why it is this one

**[PolyForm Shield 1.0.0](LICENSE.md).** Read it, run it, change it, and distribute it. The single
exception is that you may not use it to provide a product that competes with Red Kite.

This is a deliberate middle position and it is worth being plain about the reasoning.

Anybody about to run unattended software on their own servers — or worse, on eighty customers'
servers — is entitled to read it first, and refusing that would lose exactly the trust the agent
was written to earn. Obscurity was never available here anyway: it is bash, and every customer who
installs it can already read every line.

What the licence protects is narrower. It stops the work being lifted wholesale into a competing
product, which a permissive licence would allow and which had already happened once by a less
formal route. A competitor may now read this, and gains a legal problem rather than a free
artifact.

**It is not an open source licence** and is not presented as one. It is not OSI-approved, and
software under it does not belong on lists that require a free-software licence. Saying so plainly
here is cheaper than being corrected about it later.

The Unraid template repository is separate and is MIT, so that the packaging can be used, forked
and corrected by anybody without touching this question at all.

## Honest status

Red Kite is in open beta. It is useful and it is not finished, and those two facts belong together
in any description of it. It is provided as-is, with no warranty.

**Please do not make this the only thing watching your machines yet.** Run it alongside whatever
you already have and tell us where the two disagree — that is what the beta is for, and reports of
things Red Kite got wrong are more welcome than praise.

## Reporting something

`contact@redkite.info` reaches an engineer rather than a ticket queue.

If it is a security issue, say so in the subject line and please do not open a public issue first.
