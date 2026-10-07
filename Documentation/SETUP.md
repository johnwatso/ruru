# Set up Ruru

Ruru runs on a third Mac that both SwiftBot nodes can reach. It requires macOS 15.0 or later. Release builds contain Intel and Apple silicon executables.

## Pair the bots

1. Copy the universal Release `Ruru.app` to `/Applications` on the authority Mac, launch it,
   and confirm the service reports **Running**. First launch generates its own
   bearer token in that user's Keychain. It does not use SwiftBot's Keychain.
2. Open **Internet Access** and click **Set Up Cloudflare**, enter an unused subdomain such as
   `witness.example.com` and a Cloudflare API token, then click **Connect**.
   The app checks access, creates its own remotely managed tunnel, configures
   `http://127.0.0.1:38990` as the origin, creates a proxied CNAME, and runs the
   bundled connector. Wait for **Connected**. No reverse proxy, certificate files,
   A record, Homebrew installation, or router port forwarding is required.
   HTTPS is supplied by Cloudflare. See [Cloudflare's setup flow](https://developers.cloudflare.com/tunnel/get-started/).
3. Open **Connection Details**. Enter its endpoint, cluster ID, and bearer token
   in the preferred SwiftBot Primary's **SwiftMesh → Recovery and Pairing**.
   Both bots must use the same authority and cluster ID. A fresh SwiftBot Failover
   Join Code can carry the saved witness configuration to the Failover.
4. In **Settings → General**, enable **Launch at login** and **Start the service automatically**,
   then save the changes. macOS may require approval under System Settings
   → General → Login Items. The login option is off until you choose it.
5. Keep the Mac and its internet connection running. Configure the Mac's power
   settings to prevent automatic system sleep while plugged in; the display may
   sleep. Verify the remote HTTPS endpoint from both bot locations before a drill.
6. Test Primary loss, recovery/return, witness loss, and a witness restart.
   The earlier SQLite version was launched and connected on the target Mac.
   Ruru's DuckDB revision and a complete failover/return/partition drill still
   need validation there.

Closing the window leaves the menu bar service running. Quitting the app,
logging out, system sleep, or loss of the witness's network makes it unavailable;
the bots must stop output when their local permission expires. Launch at login
requires a logged-in user session; this initial app is **not a pre-login daemon**
and does not install a crash-restarting LaunchDaemon. See [Apple's login-item API](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).

Open the separate preferences window from the menu bar or **Ruru → Settings…**
(⌘,). Overview’s More menu also opens Settings.
Changes
apply as soon as you make them. **About Ruru** is in the app menu and the menu bar menu.

To show the app icon in the Dock as well, set **Settings → General →
Show Ruru in** to **Dock + Menu Bar**. Clicking that icon reopens the window. The menu bar
service remains available in both modes.

## Replace old SQLite storage

If Ruru reports **Existing SQLite authority storage was found**, choose
**Set Up DuckDB**. Stop and unpair every participating client and stop the old
witness before confirming the two acknowledgements. Use a new SwiftBot cluster
ID; additional services receive fresh IDs automatically. **Archive and Set Up**
preserves SQLite files under `~/Library/Application Support/Ruru/Legacy Archives/`,
creates DuckDB storage and rotates pairing tokens. Existing DuckDB storage is
never overwritten. Ruru stays stopped, with automatic service startup disabled.

Start the service and re-pair each remaining service’s servers using its new
**Guarding → Connection Details**. Do not run the old witness or restore archived
files into active storage. No leases/history are migrated. Removing service
entries alone does not replace SQLite storage.

## Software updates

Open **Settings → Updates** to choose Stable or Beta, enable background
update prompts, or opt in to automatic downloads, then save. **Check for Updates**
is also available in the Ruru application menu and menu bar menu. Downloaded
updates normally install when Ruru quits; a requested install/relaunch briefly
interrupts the authority and keeps its restart quarantine.

ShipHook handles publishing. Update controls remain unavailable until its public
signing key is included in the build and feeds are published. Current development
previews do not claim a working public update channel.

See the [isolated Software Updates preview](Images/software-updates.png).

## Cloudflare Internet Access

Create an API token with **Zone → Zone → Read**, **Zone → DNS → Edit**, and
**Account → Cloudflare Tunnel → Edit** permissions, scoped to the relevant zone
and account. The same API token used in SwiftBot can be entered here if its scope
covers this domain and account. The witness saves its own copy in Keychain;
it does not read SwiftBot's Keychain or replicate Cloudflare credentials to bots.

Each installation uses a private, persistent naming identity for its own tunnel.
It never adopts a SwiftBot tunnel or replaces another service's DNS record.
The hostname stays fixed after setup; choose a dedicated address for the witness.
API and connector tokens are kept in Keychain. Settings contain only non-secret
hostname, account/tunnel IDs, and enabled state. Connection Details exports only
the witness endpoint, cluster ID, and witness bearer token.

Ordinary startup uses the saved connector token and does not call the Cloudflare
management API. The app supervises the helper, reconnects after network changes,
and retries unexpected exits with a bounded backoff. A cache-bypassing `/health`
probe detects stalled routes. Pause stops the connector but retains the Cloudflare
resources; Resume restarts it. Stop Service and Quit also stop the connector.
Reconnection never restarts the ownership database or resets its terms.

Closing the window keeps the service and connector running. Launch at login
starts them again if both service auto-start and Internet Access are enabled.
First setup and management happen in the app on the witness host. The owner has
confirmed the earlier version's service and tunnel running on the target Mac,
and its public health endpoint returned ready. The DuckDB revision and redesigned
console still need validation on that Mac.

For an existing externally managed HTTPS route, keep Internet Access unconfigured
and enter its URL in **Internet Access → Connection Settings…**. If the endpoint has Cloudflare Access, its policy
must permit authenticated machine requests rather than require an interactive
browser sign-in.

The app bundles official `cloudflared` **2026.9.3** for Intel and Apple silicon,
with a Sequoia-compatible minimum OS. `Scripts/vendor_cloudflared.py` downloads
both pinned upstream archives, verifies their GitHub release SHA-256 digests,
and assembles/signs the universal helper. The build does not download the
connector; Xcode fetches the pinned DuckDB Swift package when it is not cached.
Licenses and source references are included in `Resources/ThirdPartyNotices.md`
and `Resources/cloudflared-LICENSE.txt`.

## Guard additional services

Open **Guarding** to see SwiftBot and its ownership. Choose **Add Service** for
another SwiftBot group or another app, give it a name and a unique cluster ID,
and open its **Connection Details**. Each service gets a separate bearer token;
all its participants use the same endpoint, cluster ID and service token.
Adding a service keeps existing services and their leases running.

Open a service and choose **Remove… → Remove Service** to stop guarding it.
This works for SwiftBot and during startup failures. New grants and renewals
are rejected; existing permission expires within 30 seconds. Terms/history are
retained and other services keep running. You can remove every service and add
a new one later.

Open a service to see its current owner, retained activity and **Known Servers**.
There is no two-server limit. Known servers are successful past participants,
not a live uptime roster; standby servers may not appear until they acquire
ownership. Other applications must [implement the lease protocol](INTEGRATIONS.md).

## Choose a Preferred Primary

Open a service in **Guarding → Preferred Primary → Choose Primary**. Choose an
observed server or enter the intended standby's stable node ID, then Save
Preference. Clear Preference removes the preference. Current Owner continues
to show the actual lease holder.

Updated clients can use this selection for coordinated return while keeping
failover available. Saving it alone does not transfer ownership, and older
SwiftBots keep their current behavior. See [Preferred Primary](PRIMARY_PREFERENCE.md)
for the client update contract.

## Readable server names

Current Owner uses the SwiftMesh node name reported by updated SwiftBots. For existing bots, open the service in **Guarding**, select a known server and save a display name such as **Primary Mac** or **Failover Mac**. Names appear in Activity and persist across relaunches. Server Details contains the full node ID; changing a name does not interrupt its lease.

See [storage and ownership](STORAGE.md) before replacing an existing authority.
