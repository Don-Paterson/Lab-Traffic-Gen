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

| Load | Tool | What it exercises |
|---|---|---|
| TCP throughput | iperf3, multi-stream | SND cores, acceleration path, throughput graphs |
| UDP packet rate | iperf3, 256-byte datagrams | packets/sec rather than bits/sec, which is what actually loads the SNDs |
| Connection rate | PsPing, repeated TCP connects | firewall workers, rulebase matching, connections table |

### Load profiles

| Profile | TCP rate | Streams | UDP rate | Connects/sec |
|---|---|---|---|---|
| Light | 50 Mb/s | 2 | 20 Mb/s | 5 |
| Medium (default) | 300 Mb/s | 4 | 100 Mb/s | 20 |
| Heavy | 800 Mb/s | 8 | 300 Mb/s | 40 |

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
| A-GUI | A-Host (and A-DMZ if used) | TCP 5201-5202, UDP 5201-5202, TCP 3389 | Accept | None |

Notes:

- **Set Track to None.** At 20 connects/sec the connection-rate load will
  otherwise fill your logs with thousands of identical entries.
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
| `-Target` | Client | `192.168.11.201` | IP of the server host. |
| `-Duration` | both | `3600` | Seconds. iperf3 and the PsPing loop stop on their own. |
| `-NoUdp` | Client | off | Skip the UDP packet-rate load. |
| `-NoConnectionRate` | Client | off | Skip the PsPing loop. Use this first if the lab host is struggling. |
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

- **iperf3** from the [ar51an Windows builds](https://github.com/ar51an/iperf3-win-builds/releases)
- **PsPing** from [Sysinternals](https://learn.microsoft.com/sysinternals/downloads/psping)

If the lab has no internet access, or the iperf3 release asset name changes,
the download fails with a message naming the folder. Drop `iperf3.exe` (with
its DLLs) and `psping.exe` into `C:\LabTraffic\bin` by hand, or put them
beside `LabTraffic.ps1`, and the script will pick them up. Both are
third-party tools under their own licences and are not redistributed here.

---

## What this is not

The traffic is a handful of long-lived flows plus repeated identical
connections. It is uniform, predictable and mostly accelerated, so it is good
for putting numbers on a dashboard and giving debug output something to chew
on, but it does not resemble the flow-count and application mix of a
production gateway. Do not use the throughput figures as a benchmark of the
gateway itself: on Skillable the Hyper-V host and the Windows VMs usually
limit throughput first.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Cannot reach <target> on TCP 5201` | Server role started? Windows firewall rules added (needs Administrator once)? Check Point rule installed? |
| Client starts then exits immediately | Another iperf3 client is already using that port on the server; one server handles one client per port. |
| Nothing in `fwaccel stats -s` | Traffic may be going to the wrong gateway member — check `cphaprob state`. |
| Load still running after `Stop` | `Get-Process iperf3, psping64 \| Stop-Process`, then delete `C:\LabTraffic\state.json`. |
| Lab host becomes sluggish | Drop to `-Load Light` and add `-NoConnectionRate`. |

## Related

- [SkillableMods](https://github.com/Don-Paterson/SkillableMods) — lab patching
- [LabLauncher](https://github.com/Don-Paterson/LabLauncher) — lab startup
- [chkp-monitor](https://github.com/Don-Paterson/chkp-monitor) — health dashboard
