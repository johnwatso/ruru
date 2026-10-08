# Set up Ruru

Ruru runs on a Mac that every participating server can reach, separate from
those servers. It requires macOS 15.0 or later. Release builds contain Intel and
Apple silicon executables.

## Add your first service

1. Copy the universal Release `Ruru.app` to `/Applications` on the authority Mac, launch it,
   and confirm the service reports **Running**. A fresh Ruru has no services.
2. Open **Internet Access** and click **Set Up Cloudflare**, enter an unused subdomain such as
   `ruru.example.com` and a Cloudflare API token, then click **Connect**.
   The app checks access, creates its own remotely managed tunnel, configures
   `http://127.0.0.1:38990` as the origin, creates a proxied CNAME, and runs the
   bundled connector. Wait for **Connected**. No reverse proxy, certificate files,
   A record, Homebrew installation, or router port forwarding is required.
   HTTPS is supplied by Cloudflare. See [Cloudflare's setup flow](https://developers.cloudflare.com/tunnel/get-started/).
3. Open **Guarding → Add Service**. Choose the **SwiftBot** template or **Other
   app**, a name, a unique cluster ID and a lease length (30 seconds suits most
   apps). Ruru creates a bearer token for that service in this Mac's Keychain.
4. Open the service's **Connection Details** and give every participating server
   the endpoint, cluster ID and token, or use **Pair a Server** to create a
   single-use code and approve the server's request (for servers whose software
   supports pairing codes). For SwiftBot, create a code and enter it with
   Ruru's address in the preferred Primary's **SwiftMesh → Recovery and Pairing
   → Set Up Ruru**, then approve the request in Ruru; a fresh Failover Join
   Code carries the settings to the Failover. Other apps use [RuruClient or the
   protocol](INTEGRATIONS.md).
5. In **Settings → General**, enable **Launch at login** and **Start the service automatically**,
   then save the changes. macOS may require approval under System Settings
   → General → Login Items. The login option is off until you choose it.
6. Keep the Mac and its internet connection running. Configure the Mac's power
   settings to prevent automatic system sleep while plugged in; the display may
   sleep. Verify the remote HTTPS endpoint from every server location before a drill.
7. In **Settings → Alerts**, choose what to be told about and set up macOS
   notifications and/or a Discord webhook. Use **Send Test** to check delivery.
8. Test Primary loss, recovery/return, witness loss, and a witness restart.
   The earlier SQLite version was launched and connected on the target Mac.
   Ruru's DuckDB revision and a complete failover/return/partition drill still
   need validation there.

Closing the window leaves the menu bar service running. Quitting the app,
logging out, system sleep, or loss of the Mac's network makes it unavailable;
servers must stop exclusive work when their local permission expires. Launch at login
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

Choose **Add Service** in Guarding or Coordination for each further app or
group, with its own name, cluster ID and lease length, and open its
**Connection Details**. Each service gets a separate bearer token;
all its participants use the same endpoint, cluster ID and service token.
Adding a service keeps existing services and their leases running.

Open a service and choose **Remove… → Remove Service** to stop guarding it.
This works for every service and during startup failures. New grants and
renewals are rejected; existing permission expires within that service's lease
length. **Edit** changes a service's name or lease length without interrupting
its owner; a new length applies from the next renewal. Terms/history are
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
