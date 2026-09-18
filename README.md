# Lab-Traffic-Gen

Background traffic generator for Check Point training labs. One PowerShell
script runs in two roles: a **Server** on the receiving host and a **Client**
on the sending host, so traffic crosses the lab gateway and gives students
something realistic to look at in `cpview`, `fwaccel stats`, SmartView and
debug output.

Built for the Skillable CCTE R82 Alpha-site topology, but the target is a
parameter, so it works anywhere a client and a server sit on opposite sides of
a gateway.

---

## What it generates

Three loads, each optional, all rate-limited:

| Load | Tool | What it exercises | Default |
|---|---|---|---|
| TCP throughput | iperf3, multi-stream | SND cores, acceleration path, throughput graphs | on |
| UDP packet rate | iperf3, 256-byte datagrams | packets/sec rather than bits/sec, which is what actually loads the SNDs | on |
| HTTP requests | OpenWebLoad | short-lived connections **with payload**, so App Control and URL Filtering classify the traffic and the logs look like browsing | on |
| Connection rate | PsPing, connect-only | handshakes with no data; also the best of the four for measuring latency | `-WithPsping` |

The HTTP load is the one that produces realistic logs. iperf3 and PsPing
generate connections the gateway never classifies, because no payload is sent.

### Load profiles

| Profile | TCP rate | Streams | UDP rate | HTTP clients | PsPing connects/sec |
|---|---|---|---|---|---|
| Light | 50 Mb/s | 2 | 20 Mb/s | 2 | 5 |
| Medium (default) | 300 Mb/s | 4 | 100 Mb/s | 5 | 20 |
| Heavy | 800 Mb/s | 8 | 300 Mb/s | 15 | 40 |

Five HTTP clients against the CCTE lab's A-DMZ web server gives roughly 78
transactions/sec.

Start with Medium. Heavy is worth trying only when you have the lab to
yourself, since Skillable hosts are shared and the Windows VMs usually run out
of CPU before the gateway does.

---

## Quick start

### 1. Server, on A-Host (192.168.11.201)

Elevated PowerShell, once per lab instance:

```powershell
irm https://raw.githubusercontent.com/Don-Paterson/Lab-Traffic-Gen/main/LabTraffic.ps1 -OutFile C:\LabTraffic.ps1
C:\LabTraffic.ps1 -Role Server -Action Start
```

This fetches the tools, adds the Windows firewall rules and starts two iperf3
listeners (5201 and 5202). Leave it running.

### 2. Client, on A-GUI (10.1.1.201)

```powershell
irm https://raw.githubusercontent.com/Don-Paterson/Lab-Traffic-Gen/main/LabTraffic.ps1 -OutFile C:\LabTraffic.ps1
C:\LabTraffic.ps1 -Role Client -Action Start -Load Medium -Target 192.168.11.201
```

### 3. Check and stop

```powershell
C:\LabTraffic.ps1 -Action Status
C:\LabTraffic.ps1 -Action Stop
```

`Status` and `Stop` need no other parameters: the script reads the role, the
profile and the PIDs it started from `C:\LabTraffic\state.json`.

---

## Check Point policy

The script cannot install a rule for you. Add one above any cleanup rule:

| Source | Destination | Service | Action | Track |
|---|---|---|---|---|
| A-GUI | A-Host | TCP 5201-5202, UDP 5201-5202 | Accept | None |
| A-GUI | A-DMZ | http (TCP 80) | Accept | None |
| A-GUI | A-Host | TCP 3389 | Accept | None |

The third rule is only needed with `-WithPsping`.

Notes:

- **Set Track to None on all of them.** At Medium the HTTP load alone is about
  78 logs/sec, which is 280,000 an hour. A soak test with tracking left on will
  fill the log server.
- Keep the rule free of Threat Prevention and HTTPS Inspection if you want a
  clean accelerated path. To push some of the load to F2F on purpose, add a
  second rule with an inspection blade in scope and send a separate run
  through it.
- Only `fw ctl zdebug`-level visibility needs the traffic to be non-templated;
  for most demos the accelerated path is what you want.

---

## Targets

`-Target` picks which gateway interface pair the traffic crosses:

| Target | Host | Path |
|---|---|---|
| `192.168.11.201` | A-Host | eth0 → eth2 (internal) |
| `192.168.12.101` | A-DMZ | eth0 → eth3 (DMZ) |
| `192.168.21.201` | B-Host | across the site-to-site VPN — **untested** |

Run the client twice with different targets to load two interface pairs at
once. The state file tracks one session per machine, so for now use a second
machine or run one target at a time.

The B-Host case would need the server role installed there plus a matching
rule. It is listed because the CPVS troubleshooting module works through Alpha
to Bravo traffic and background load would make `vpn debug` and `fw monitor`
output more realistic, but nothing here has been tested over a VPN.

---

## Parameters

| Parameter | Roles | Default | Notes |
|---|---|---|---|
| `-Role` | both | — | `Server` or `Client`. Required for `-Action Start`. |
| `-Action` | both | `Status` | `Start`, `Stop`, `Status`, `Install`. |
| `-Load` | Client | `Medium` | `Light`, `Medium`, `Heavy`. |
| `-Target` | Client | `192.168.11.201` | Host running the server role (iperf3 loads). |
| `-HttpTarget` | Client | `192.168.12.101` | Web server for the HTTP load. A-DMZ by default, so HTTP crosses eth3 while iperf3 crosses eth2. |
| `-Duration` | both | `3600` | Seconds. iperf3 and the PsPing loop stop on their own. |
| `-NoUdp` | Client | off | Skip the UDP packet-rate load. |
| `-NoHttp` | Client | off | Skip the OpenWebLoad HTTP load. |
| `-WithPsping` | Client | off | Also run the PsPing connect-only loop. |
| `-InstallPath` | both | `C:\LabTraffic` | Holds `bin\`, `state.json` and `connrate.ps1`. |

`-Load` rather than `-Profile`: `$Profile` is a PowerShell automatic variable
and shadowing it inside a script causes odd behaviour and analyzer warnings.

---

## Unattended start

```powershell
C:\LabTraffic.ps1 -Role Client -Action Start -Load Light -Target 192.168.11.201 -Action Install
Unregister-ScheduledTask -TaskName LabTraffic-Client   # to remove
```

`-Action Install` registers a scheduled task that starts the same load at
logon. Optional, and the first thing likely to break after a Skillable image
refresh, so treat it as a convenience rather than part of the build.

---

## Tools

The script fetches what it needs into `C:\LabTraffic\bin`:

- **iperf3** from the [ar51an Windows builds](https://github.com/ar51an/iperf3-win-builds/releases).
  Asset names carry the version (`iperf-<ver>-win64.zip`), so the script asks
  the GitHub API for the current release and falls back to a pinned version.
- **PsPing** from [Sysinternals](https://learn.microsoft.com/sysinternals/downloads/psping),
  fetched only when `-WithPsping` is used.
- **OpenWebLoad** (`openload.exe`) from [openwebload.sourceforge.net](https://openwebload.sourceforge.net/).
  Version 0.1.2, released 2001, and SourceForge has no direct download URL, so
  the binary is vendored in `bin/` in this repo and pulled from there.

If the lab has no internet access, drop the exes into `C:\LabTraffic\bin` by
hand, or put them beside `LabTraffic.ps1`, and the script will use them. If
`openload.exe` is missing the HTTP load is skipped with a warning rather than
failing the run. iperf3 and PsPing are third-party tools under their own
licences and are not redistributed here.

---

## What this is not

The traffic is a handful of long-lived flows plus repeated requests for the
same URL. The HTTP load gets classified and logged like real browsing, but it
is still one URL from one source, so it does not resemble the flow-count,
destination spread or application mix of a production gateway. Do not use the throughput figures as a benchmark of the
gateway itself: on Skillable the Hyper-V host and the Windows VMs usually
limit throughput first.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Cannot reach <target> on TCP 5201` | Server role started? Windows firewall rules added (needs Administrator once)? Check Point rule installed? |
| Client starts then exits immediately | Another iperf3 client is already using that port on the server; one server handles one client per port. |
| Nothing in `fwaccel stats -s` | Traffic may be going to the wrong gateway member — check `cphaprob state`. |
| Load still running after `Stop` | `Get-Process iperf3, psping64 \| Stop-Process`, then delete `C:\LabTraffic\state.json`. |
| `No web server on <ip>:80` | Check the web server on A-DMZ is running, and that the http rule is installed. |
| HTTP load skipped, openload unavailable | Copy `openload.exe` into `C:\LabTraffic\bin`. |
| Lab host becomes sluggish | Drop to `-Load Light` and add `-NoHttp`. |

## Related

- [SkillableMods](https://github.com/Don-Paterson/SkillableMods) — lab patching
- [LabLauncher](https://github.com/Don-Paterson/LabLauncher) — lab startup
- [chkp-monitor](https://github.com/Don-Paterson/chkp-monitor) — health dashboard
