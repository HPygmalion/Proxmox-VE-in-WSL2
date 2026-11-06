# Validation record

Date: 2026-11-05. This is an experimental WSL lab, not a production certification.

## Environment

- Windows 11 x86_64, Windows PowerShell 5.1, Debian 13.
- Original WSL 2.7.12 was upgraded to 3.0.3 by an earlier test version that automatically updated WSL. The final installer no longer does this unless `-UpdateWsl` is requested.
- WSL kernel changed from 6.18.33.2 to 6.18.54.1 during that update. This host change was not a PVE guest reinstall.
- PVE no-subscription repository installed pve-manager 9.2.25 in test systems. Exact package patches are not pinned.

## Isolated regression checks

- `tests/Test-Helpers.ps1`: INI section/key preservation, duplicate prevention, safe distro-name rejection, PowerShell parsing, password command-line regression.
- `tests/bootstrap-pve.test.sh`: platform/override checks, numeric private subnets, route overlap, bounded apt options, atomic keyring, authoritative hosts, each-service verification, async interfaces initialization, NAT rerun safety, CT failure cleanup and hard smoke failures.
- `tests/Test-WslHelpers.ps1` is opt-in and changes only the explicitly named disposable test distro; covers native exit-code handling, quote/Unicode input and password stdin.

## Real integration evidence collected

Earlier integration runs on isolated PVE-test-src/PVE-test:

- PVE services and API started; root page HTTP 200, unauthenticated version API HTTP 401.
- Actual QEMU/KVM initialization passed.
- Unprivileged Alpine CT creation, startup, gateway/internet access and destruction passed.
- vmbr0 DHCP/NAT/DNS worked.
- Actual PVE VM booted Alpine 3.22 from ISO; serial console drove DHCP. Guest obtained a lease and successfully pinged gateway/internet and resolved DNS.
- WSL export/import to a new distro succeeded; services recovered on imported-system startup.
- Linux health check recovered pveproxy after deliberate stop.

Final-generation supervisor integration:

- Direct `wsl.exe` anchor action registered as the current Windows user at limited privilege.
- Login trigger plus one-minute repetition, IgnoreNew and unlimited execution time.
- Deliberate `wsl --terminate` followed by the next minute trigger restarted the test distro and returned task state to Running.
- No VBS dependency. Earlier VBS/PowerShell loop experiments were rejected because they did not reliably survive termination in this environment.

## Final acceptance run

Acceptance installation/resume in `PVE-acceptance-src` completed with exit code **0**, imported target `PVE-acceptance`, verified API and every required service, registered/started the Windows supervisor, and removed its owned source/transfer archive. Log explicitly reported `Installation complete: PVE-acceptance`.

On the imported target:

- Secure stdin tests passed for quotes, spaces and Unicode, with a separate integer native exit status.
- All core services were active, no failed units, and no leftover CT/VM.
- Deliberately stopped pveproxy and deleted MASQUERADE: health check restored both.
- Deliberately terminated WSL: the supervisor's minute retry restarted the imported target; task returned Running and API returned HTTP 401.

Final review subsequently changed three small compatibility paths: BOM-free stdin regardless of caller encoding, reading `/proc/1/comm` instead of depending on `ps`, and accepting dotted existing distro names. BOM/BOM-free live stdin regressions passed against the original distro using read-only scripts. Added a sandboxed API-503 persistence test; it correctly fails health-check recovery instead of reporting success. These post-acceptance compatibility changes were regression-tested, but another complete from-scratch install was not run after them.

The acceptance run resumed after earlier diagnosed failures; it is evidence of the complete final orchestration and successful recovery, not a claim that every prior fresh run completed without errors.

## Limits

- No Windows reboot/logout or laptop sleep test was performed. Login-trigger configuration can be inspected, but post-reboot operation is not claimed as physically tested.
- No BIOS/virtualization enablement, clean Windows WSL-first-install or alternate-administrator-user scenario was tested.
- No backup restore drill was performed. The original PVE export was successfully enumerated and checked for config.db, network configuration and the VM disk, but archive traversal is not bitwise disk verification.
- IPv6 guest routing, passthrough, physical bridging, Ceph, HA and production reliability are out of scope.
- The pre-existing lab was backed up before testing and restored afterward. Its supervisor, original VM and web interface were verified operational; no original distro was unregistered.
- The acceptance target was stopped and its supervisor disabled after testing. Superseded disposable test distros were removed.
- Never start a test PVE instance alongside another PVE distro: shared ports and network resources can collide.

## Backup validation scope

The pre-test export and full archive listing returned exit code 0. The PVE database and original VM disk were present. Runtime Unix sockets were skipped, as expected. This was an archive-readability check, not a full restore drill.
